//
//  RepoDescriptionTranslationTests.swift
//  StarcatTests
//
//  描述译文的语言判断、描述变更后索引作废，以及原文/译文同时可搜。
//

import Foundation
import GRDB
import os.lock
import Testing
@testable import Starcat

@Suite("Repo description translation")
struct RepoDescriptionTranslationTests {

    @Test("汉字达到一半则不翻译，短英文和符号按规则跳过或送翻")
    func languageGate() {
        #expect(RepoDescriptionLanguageGate.needsTranslation("这是一个数据库工具") == false)
        #expect(RepoDescriptionLanguageGate.needsTranslation("A fast database toolkit") == true)
        #expect(RepoDescriptionLanguageGate.needsTranslation("Hello 世界") == true)
        #expect(RepoDescriptionLanguageGate.needsTranslation("中文中文中文En") == false)
        #expect(RepoDescriptionLanguageGate.needsTranslation("中A") == false)
        #expect(RepoDescriptionLanguageGate.needsTranslation("中AB") == true)
        #expect(RepoDescriptionLanguageGate.needsTranslation("!!!") == false)
        #expect(RepoDescriptionLanguageGate.needsTranslation("   ") == false)
    }

    @Test("未设置时，仓库描述翻译默认走系统翻译")
    @MainActor
    func descriptionEngineDefaultsToSystem() {
        let suite = "starcat.tests.description-engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.repoDescriptionTranslationEngine == .system)
    }

    @Test("拉丁短句归入英文，日文单独成组，中文不发送")
    func sourceGroupingSeparatesLanguages() {
        #expect(
            RepoDescriptionSourceGrouping.resolvedSource(
                recognized: nil,
                text: "xyz-parser",
                target: .simplifiedChinese
            ) == .english
        )
        #expect(
            RepoDescriptionSourceGrouping.resolvedSource(
                recognized: .english,
                text: "A fast database toolkit",
                target: .english
            ) == nil
        )
        let latin = RepoDescriptionTranslationCandidate(
            repoId: 1,
            description: "A fast database toolkit for querying records"
        )
        let japanese = RepoDescriptionTranslationCandidate(
            repoId: 2,
            description: "これは高速なデータベースツールです"
        )
        let chinese = RepoDescriptionTranslationCandidate(repoId: 3, description: "这是一个数据库工具")
        let partition = RepoDescriptionSourceGrouping.groups(
            from: [latin, japanese, chinese],
            target: .simplifiedChinese
        )
        #expect(partition.sending.map(\.sourceLanguage).contains(.english))
        #expect(partition.sending.first { $0.sourceLanguage == .english }?.candidates.map(\.repoId) == [1])
        #expect(partition.sending.first { $0.sourceLanguage == .japanese }?.candidates.map(\.repoId) == [2])
        #expect(partition.skipped.map(\.repoId) == [3])
    }

    @Test("系统翻译按批写入，语言包缺失后只补剩余条目")
    @MainActor
    func systemTranslationPersistsEachBatchAndResumesAfterMissingLanguagePack() async throws {
        let database = try InMemoryDatabaseManager()
        let descriptions = (1...11).map { index in
            "Database toolkit number \(String(format: "%02d", index))"
        }
        for (offset, description) in descriptions.enumerated() {
            try await insertDiscovery(
                database,
                repoID: Int64(offset + 1),
                fullName: "tester/item\(offset)",
                description: description,
                category: "discover"
            )
        }
        let systemTranslator = ScriptedSystemDescriptionTranslator(failAtBatch: 1)
        let store = makeStore(database: database, systemTranslator: systemTranslator, engine: .system)

        await store.runExploreTranslation(.discover)
        #expect(store.exploreProgress[.discover]?.phase == .paused)
        #expect(store.exploreProgress[.discover]?.completed == 10)
        #expect(store.exploreProgress[.discover]?.total == 11)
        #expect(store.translatedText(repoId: 1, original: descriptions[0]) == "译:" + descriptions[0])
        #expect(store.translatedText(repoId: 11, original: descriptions[10]) == nil)

        systemTranslator.failAtBatch = nil
        await store.runExploreTranslation(.discover)
        #expect(store.exploreProgress[.discover] == nil)
        #expect(store.translatedText(repoId: 11, original: descriptions[10]) == "译:" + descriptions[10])
        #expect(systemTranslator.descriptions.last == [descriptions[10]])
    }

    @Test("描述变更后删掉旧译文，搜索同时命中英文原文和中文译文")
    func searchHitsOriginalAndTranslationUntilDescriptionChanges() async throws {
        let database = try InMemoryDatabaseManager()
        let repos = GRDBRepoRepository(database: database)
        let translations = RepoDescriptionTranslationRepository(database: database)
        let original = "A fast database toolkit"
        try await repos.upsertStarred(
            [makeStarred(id: 42, name: "dbkit", description: original)],
            userID: 7,
            syncedAt: Date()
        )
        try await translations.upsert(
            RepoDescriptionTranslationRecord(
                repoId: 42,
                sourceHash: RepoDescriptionTranslationHash.sha256(original),
                targetLanguage: "zh-Hans",
                translatedText: "一个数据库工具",
                updatedAt: "2026-11-13T00:00:00Z"
            )
        )

        let english = try await repos.searchFTS(query: "database")
        #expect(english.map(\.id) == [42])
        let chinese = try await repos.searchFTS(query: "数据库工具")
        #expect(chinese.map(\.id) == [42])

        try await repos.upsertStarred(
            [makeStarred(id: 42, name: "dbkit", description: "Something else entirely")],
            userID: 7,
            syncedAt: Date()
        )
        let stale = try await repos.searchFTS(query: "数据库工具")
        #expect(stale.isEmpty)
        let remaining = try await translations.loadAll()
        #expect(remaining.isEmpty)
    }

    @Test("同仓 Markdown 栈可压入、替换栈顶、返回并在换仓时清空")
    func documentStackPushPopAndClear() {
        var stack = RepositoryMarkdownDocumentStack()
        let first = frame(path: "README_CN.md", html: "cn")
        let replacement = frame(path: "README_CN.md", html: "cn-2")
        let second = frame(path: "docs/guide.md", html: "guide")

        stack.push(first)
        stack.push(replacement)
        #expect(stack.frames.count == 1)
        #expect(stack.top?.html == "cn-2")
        #expect(stack.currentPath == "README_CN.md")

        stack.push(second)
        #expect(stack.frames.map(\.target.path) == ["README_CN.md", "docs/guide.md"])
        stack.pop()
        #expect(stack.top?.target.path == "README_CN.md")
        stack.clear()
        #expect(stack.isEmpty)
    }

    @Test("探索译文不进入星标搜索；原文一致时同时写入星标表")
    @MainActor
    func exploreTranslationStaysOutOfStarSearchUnlessTheLibraryDescriptionMatches() async throws {
        let database = try InMemoryDatabaseManager()
        let repos = GRDBRepoRepository(database: database)
        let translations = RepoDescriptionTranslationRepository(database: database)
        let original = "Alpha toolkit"
        try await repos.upsertStarred(
            [makeStarred(id: 11, name: "alpha", description: original)],
            userID: 7,
            syncedAt: Date()
        )
        try await insertDiscovery(database, repoID: 11, fullName: "tester/alpha", description: original, category: "discover")
        try await insertDiscovery(database, repoID: 13, fullName: "tester/cn", description: "这是一个数据库工具", category: "discover")
        try await translations.upsertExplore(
            RepoDescriptionTranslationRecord(
                repoId: 77,
                sourceHash: RepoDescriptionTranslationHash.sha256("Explore only"),
                targetLanguage: "zh-Hans",
                translatedText: "纯探索仓库描述",
                updatedAt: "2026-11-13T00:00:00Z"
            )
        )

        let exploreOnly = try await repos.searchFTS(query: "纯探索仓库")
        #expect(exploreOnly.isEmpty)
        let stored = try await translations.loadExplore()
        #expect(stored.map(\.repoId) == [77])

        let translator = ScriptedDescriptionTranslator(route: .cloud, results: [
            .success(["一个开源工具箱"])
        ])
        let systemTranslator = ScriptedSystemDescriptionTranslator()
        let store = makeStore(
            database: database,
            translator: translator,
            systemTranslator: systemTranslator,
            engine: .google
        )
        await store.runExploreTranslation(.discover)

        #expect(translator.calls == [[original]])
        #expect(systemTranslator.descriptions.isEmpty)
        #expect(store.translatedText(repoId: 11, original: original) == "一个开源工具箱")
        #expect(store.translatedText(repoId: 11, original: "A different toolkit") == nil)
        #expect(store.translatedText(repoId: 13, original: "这是一个数据库工具") == nil)
        let starredHit = try await repos.searchFTS(query: "开源工具")
        #expect(starredHit.map(\.id) == [11])
        let exploreRows = try await translations.loadExplore().filter { $0.repoId == 11 || $0.repoId == 13 }
        #expect(exploreRows.map(\.repoId) == [11])

        await store.runExploreTranslation(.discover)
        #expect(translator.callCount == 1)
    }

    @Test("限流留下已完成条数，继续时从缺口翻译")
    @MainActor
    func rateLimitKeepsCompletedCountAndResumeContinues() async throws {
        let database = try InMemoryDatabaseManager()
        try await insertDiscovery(database, repoID: 21, fullName: "tester/one", description: "First toolkit", category: "discover")
        try await insertDiscovery(database, repoID: 22, fullName: "tester/two", description: "Second toolkit", category: "discover")
        let translator = ScriptedDescriptionTranslator(route: .publicWeb, results: [
            .success(["第一条译文"]),
            .failure(GoogleTranslationError.rateLimited),
            .success(["第二条译文"])
        ])
        let store = makeStore(database: database, translator: translator)

        await store.runExploreTranslation(.discover)
        #expect(store.exploreProgress[.discover] == ExploreDescriptionTranslationProgress(
            completed: 1, total: 2, phase: .paused
        ))
        #expect(store.translatedText(repoId: 21, original: "First toolkit") == "第一条译文")
        #expect(store.translatedText(repoId: 22, original: "Second toolkit") == nil)

        await store.runExploreTranslation(.discover)
        #expect(store.exploreProgress[.discover] == nil)
        #expect(translator.callCount == 3)
        #expect(store.translatedText(repoId: 22, original: "Second toolkit") == "第二条译文")
        #expect(translator.calls.map(\.first) == ["First toolkit", "Second toolkit", "Second toolkit"])
    }

    @Test("探索候选按子菜单去重，并避开隐藏来源和清单简介")
    func exploreCandidatesFollowTheLocalSnapshot() async throws {
        let database = try InMemoryDatabaseManager()
        let translations = RepoDescriptionTranslationRepository(database: database)
        try await insertDiscovery(database, repoID: 11, fullName: "tester/alpha", description: "Alpha toolkit", category: "discover")
        try await insertDiscovery(database, repoID: 12, fullName: "tester/beta", description: "Beta toolkit", category: "popular")
        try await insertDiscovery(database, repoID: 13, fullName: "tester/cn", description: "这是一个数据库工具", category: "discover")

        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO trending_repos (
                    period, language_filter, rank, gh_repo_id, full_name, owner, name, description, cached_at
                ) VALUES
                    ('daily', '', 0, 9, 'tester/one', 'tester', 'one', 'Older description', '2026-01-01T00:00:00Z'),
                    ('weekly', '', 0, 9, 'tester/one', 'tester', 'one', 'Newer description', '2026-01-03T00:00:00Z'),
                    ('daily', '', 1, NULL, 'tester/noid', 'tester', 'noid', 'Missing id', '2026-01-03T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO weekly_bulk_repos (
                    gh_repo_id, full_name, owner, repo, name, description, source_types_json,
                    first_event_at, latest_event_at, cached_at
                ) VALUES
                    (1, 'tester/weekly', 'tester', 'weekly', 'weekly', 'Weekly only', '["weekly"]',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                    (2, 'tester/zread', 'tester', 'zread', 'zread', 'Zread only', '["zread"]',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                    (3, 'tester/both', 'tester', 'both', 'both', 'Both sources', '["weekly","zread"]',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO awesome_sources (
                    source_id, kind, display_name, repo_full_name, repo_url, added_at, updated_at
                ) VALUES (
                    'src', 'managed', 'Src', 'tester/awesome', 'https://github.com/tester/awesome',
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
                )
                """)
            try db.execute(sql: """
                INSERT INTO awesome_entries (
                    source_id, gh_repo_id, owner, name, full_name, description,
                    entry_title, entry_description, entry_order, cached_at
                ) VALUES
                    ('src', 4, 'tester', 'git', 'tester/git', 'GitHub blurb', 'Title', '清单简介', 0, '2026-01-01T00:00:00Z'),
                    ('src', 5, 'tester', 'list', 'tester/list', NULL, 'Only list', '只有清单', 1, '2026-01-01T00:00:00Z')
                """)
        }

        let discover = try await translations.fetchExploreCandidates(scope: .discover, hiddenWeeklySources: [])
        #expect(discover.map(\.repoId) == [11, 13])
        let popular = try await translations.fetchExploreCandidates(scope: .popular, hiddenWeeklySources: [])
        #expect(popular.map(\.description) == ["Beta toolkit"])
        let trending = try await translations.fetchExploreCandidates(scope: .trending, hiddenWeeklySources: [])
        #expect(trending == [RepoDescriptionTranslationCandidate(repoId: 9, description: "Newer description")])
        let weekly = try await translations.fetchExploreCandidates(scope: .weekly, hiddenWeeklySources: ["weekly"])
        #expect(weekly.map(\.repoId) == [2, 3])
        let awesome = try await translations.fetchExploreCandidates(scope: .awesomeSource("src"), hiddenWeeklySources: [])
        #expect(awesome == [RepoDescriptionTranslationCandidate(repoId: 4, description: "GitHub blurb")])
    }

    private func frame(path: String, html: String) -> RepositoryMarkdownFrame {
        RepositoryMarkdownFrame(
            target: RepositoryMarkdownLinkTarget(
                owner: "alice",
                repo: "foo",
                ref: "HEAD",
                path: path
            ),
            html: html
        )
    }

    private func makeStarred(id: Int64, name: String, description: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(
            id: 1, login: "tester", name: nil, avatarUrl: nil,
            publicRepos: nil, followers: nil, following: nil,
            bio: nil, company: nil, location: nil, email: nil,
            blog: nil, twitterUsername: nil, htmlUrl: nil
        )
        let repo = GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "tester/\(name)",
            owner: user,
            description: description,
            language: "Swift",
            stargazersCount: 3,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tester/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: "2026-11-13T00:00:00Z", repo: repo)
    }

    private func insertDiscovery(
        _ database: any DatabaseManaging,
        repoID: Int64,
        fullName: String,
        description: String,
        category: String
    ) async throws {
        let owner = "tester"
        let name = fullName.split(separator: "/").last.map(String.init) ?? fullName
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO discovery_bulk_repos (
                        repo_id, full_name, owner, name, description, cached_at
                    ) VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00Z')
                    """,
                arguments: [repoID, fullName, owner, name, description]
            )
            try db.execute(
                sql: """
                    INSERT INTO discovery_bulk_category_memberships (
                        repo_id, category, cached_at
                    ) VALUES (?, ?, '2026-01-01T00:00:00Z')
                    """,
                arguments: [repoID, category]
            )
        }
    }

    @MainActor
    private func makeStore(
        database: any DatabaseManaging,
        translator: (any RepoDescriptionTranslating)? = nil,
        systemTranslator: (any RepoDescriptionSystemTranslating)? = nil,
        engine: RepoDescriptionTranslationEngine = .google
    ) -> RepoDescriptionTranslationStore {
        let suite = "starcat.tests.repo-description.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.readmeTranslationLanguage = .simplifiedChinese
        settings.repoDescriptionDisplayMode = .translated
        settings.repoDescriptionTranslationEngine = engine
        return RepoDescriptionTranslationStore(
            database: database,
            settings: settings,
            translator: translator,
            systemTranslator: systemTranslator
        )
    }
}

private final class ScriptedDescriptionTranslator: RepoDescriptionTranslating, @unchecked Sendable {
    struct State {
        var results: [Result<[String], Error>]
        var recorded: [[String]] = []
    }

    let route: GoogleTranslationClient.Route
    private let state: OSAllocatedUnfairLock<State>

    init(route: GoogleTranslationClient.Route, results: [Result<[String], Error>]) {
        self.route = route
        self.state = OSAllocatedUnfairLock(initialState: State(results: results))
    }

    var calls: [[String]] {
        state.withLock { $0.recorded }
    }

    var callCount: Int { calls.count }

    func translateDescriptions(
        texts: [String],
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String] {
        let result = state.withLock { state -> Result<[String], Error> in
            state.recorded.append(texts)
            return state.results.isEmpty ? .success(texts) : state.results.removeFirst()
        }
        _ = targetLanguage
        return try result.get()
    }
}

private final class ScriptedSystemDescriptionTranslator: RepoDescriptionSystemTranslating, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State {
        var descriptions: [[String]] = []
        var failAtBatch: Int?
    }

    init(failAtBatch: Int? = nil) {
        state.withLock { $0.failAtBatch = failAtBatch }
    }

    var descriptions: [[String]] {
        state.withLock { $0.descriptions }
    }

    var failAtBatch: Int? {
        get { state.withLock { $0.failAtBatch } }
        set { state.withLock { $0.failAtBatch = newValue } }
    }

    @MainActor
    func translate(
        batches: [[RepoDescriptionTranslationCandidate]],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage,
        onBatch: @escaping @MainActor ([RepoDescriptionTranslationCandidate], [String]) async throws -> Void
    ) async throws {
        for batch in batches {
            let texts = batch.map(\.description)
            let shouldFail = state.withLock { state -> Bool in
                let index = state.descriptions.count
                state.descriptions.append(texts)
                return state.failAtBatch == index
            }
            if shouldFail {
                throw SystemTranslationError.languagePackMissing
            }
            try await onBatch(batch, texts.map { "译:\($0)" })
        }
        _ = sourceLanguage
        _ = targetLanguage
    }
}
