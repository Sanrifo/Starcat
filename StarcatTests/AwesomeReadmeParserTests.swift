//
//  AwesomeReadmeParserTests.swift
//  StarcatTests
//
//  自定义 Awesome 输入归一化、AST 结构提取和公开仓库核验测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Awesome README Parser")
struct AwesomeReadmeParserTests {

    @Test("来源输入只接受 owner/repo 与 HTTPS GitHub 仓库根地址")
    func sourceInputNormalization() {
        #expect(AwesomeSourceInput.parse("owner/repo")?.fullName == "owner/repo")
        #expect(AwesomeSourceInput.parse("https://github.com/owner/repo.git")?.fullName == "owner/repo")
        #expect(AwesomeSourceInput.parse("http://github.com/owner/repo") == nil)
        #expect(AwesomeSourceInput.parse("https://gitlab.com/owner/repo") == nil)
        #expect(AwesomeSourceInput.parse("https://github.com/owner/repo/issues") == nil)
    }

    @Test("AST 解析保留章节、描述、嵌套顺序并统计外部链接")
    func parsesStructuredEntries() throws {
        let markdown = """
        # Awesome Example
        ## Tools
        - [First](https://github.com/acme/first) - First description
          - [Nested](https://github.com/acme/nested) — Nested description
        - [Website](https://example.com/product) - external
        ## Libraries
        - [Second](https://github.com/acme/second) - Second description
        """

        let result = try AwesomeReadmeParser.parse(
            markdown: markdown,
            source: AwesomeRepositoryAddress(owner: "example", repo: "awesome"),
            defaultBranch: "main"
        )

        #expect(result.githubLinks.map(\.address.fullName) == ["acme/first", "acme/nested", "acme/second"])
        #expect(result.githubLinks[0].sectionPath == ["Awesome Example", "Tools"])
        #expect(result.githubLinks[0].description == "First description")
        #expect(result.githubLinks[1].description == "Nested description")
        #expect(result.githubLinks[2].sectionPath == ["Awesome Example", "Libraries"])
        #expect(result.githubLinks.map(\.order) == [0, 1, 2])
        #expect(result.externalLinkCount == 1)
        #expect(result.githubLinks[0].sourceAnchorURL.absoluteString.hasSuffix("#tools"))
    }

    @Test("details 里的引用块、summary 分类和表格行都能解析成仓库")
    func parsesBlockquotesInsideDetailsAndTableRows() throws {
        // Sanrifo/awesome-java 的真实结构：分类在 <summary>，项目在引用块，子类用 ####。
        let markdown = """
        # Awesome Java [![Awesome](https://awesome.re/badge.svg)](https://awesome.re)

        ## Projects

        <details id="api-compatibility">
        <summary><strong>API Compatibility</strong> <kbd>3 projects</kbd></summary>

        > **[japicmp](https://github.com/siom79/japicmp)** <kbd>★ 779</kbd> <kbd>Apache-2.0</kbd> 🟢<br>Compares two library JARs.

        </details>

        <details id="cli">
        <summary><strong>CLI</strong> <kbd>2 projects</kbd></summary>

        #### Argument Parsing <kbd>1 projects</kbd>

        > **[picocli](https://github.com/remkop/picocli)**<br>Annotation-based CLI.

        > **[Sentry](https://github.com/getsentry/sentry-java)**<br>Integration with [Sentry](https://github.com/getsentry/sentry) platform.

        > **[JADE](https://jade.tilab.com)**<br>Agent framework.

        </details>

        | Project | Description |
        | --- | --- |
        | [DesignMD](https://github.com/acme/design) | Design resource |

        > **[Hippo](https://github.com/opengoofy/hippo4j/blob/develop/README-EN.md)**<br>Dynamic pool.
        """

        let result = try AwesomeReadmeParser.parse(
            markdown: markdown,
            source: AwesomeRepositoryAddress(owner: "Sanrifo", repo: "awesome-java"),
            defaultBranch: "master"
        )

        #expect(result.githubLinks.map(\.address.fullName) == [
            "siom79/japicmp",
            "remkop/picocli",
            "getsentry/sentry-java",
            "acme/design",
            "opengoofy/hippo4j",
        ])
        #expect(result.githubLinks[0].sectionPath == ["Awesome Java", "Projects", "API Compatibility"])
        #expect(result.githubLinks[0].description == "Compares two library JARs.")
        #expect(result.githubLinks[0].sourceAnchorURL.absoluteString.hasSuffix("#api-compatibility"))
        #expect(result.githubLinks[1].sectionPath == ["Awesome Java", "Projects", "CLI", "Argument Parsing"])
        #expect(result.githubLinks[1].description == "Annotation-based CLI.")
        #expect(result.githubLinks[1].sourceAnchorURL.absoluteString.hasSuffix("#argument-parsing"))
        #expect(result.githubLinks[2].description == "Integration with Sentry platform.")
        #expect(result.githubLinks[3].sectionPath == ["Awesome Java", "Projects"])
        #expect(result.githubLinks[3].description == "Design resource")
        #expect(result.githubLinks[4].description == "Dynamic pool.")
        #expect(result.externalLinkCount == 1)
    }

    @Test("自定义来源拒绝私有来源仓库")
    func customSourceRejectsPrivateRepository() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/private-list", isPrivate: true))
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        await #expect(throws: AwesomeCustomSourceError.sourceMustBePublic) {
            try await service.create(input: "owner/private-list")
        }
        #expect(await repository.savedSource() == nil)
    }

    @Test("自定义来源添加只核验来源仓库并立即落卡")
    func customSourceCreateDoesNotWaitForReadme() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setReadme("owner/awesome-list", markdown: "- [Repo](https://github.com/acme/repo)")
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(
            github: github,
            repository: repository,
            now: { Date(timeIntervalSince1970: 123) }
        )

        let creation = try await service.create(input: "owner/awesome-list")

        #expect(creation.source.id == "custom:owner/awesome-list")
        #expect(creation.source.githubRepoCount == 0)
        #expect(await github.readmeRequestCount() == 0)
        #expect(await repository.savedSource()?.entries.isEmpty == true)
        #expect(await repository.customSourceParseStates().first?.phase == .queued)
    }

    @Test("自定义来源后台解析按阶段持久化并产出条目")
    func customSourceParsesInBackgroundWithProgress() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setRepo(Self.repo(id: 2, fullName: "acme/valid"))
        await github.setReadme(
            "owner/awesome-list",
            markdown: "- [Valid](https://github.com/acme/valid) - Works"
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)
        let recorder = AwesomeParseStateRecorder()
        let creation = try await service.create(input: "owner/awesome-list")

        try await service.parse(
            source: creation.source,
            defaultBranch: creation.defaultBranch
        ) { state in
            await recorder.append(state)
        }

        #expect(await recorder.phases() == [
            .readingReadme,
            .enrichingRepositories,
            .enrichingRepositories,
            .completed,
        ])
        #expect(await repository.savedSource()?.entries.map(\.fullName) == ["acme/valid"])
        #expect(await repository.customSourceParseStates().first?.phase == .completed)
    }

    @Test("自定义来源后台解析跳过失效 Repo 并保留完整元数据")
    func customSourceSkipsMissingRepository() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setRepo(Self.repo(id: 2, fullName: "acme/valid"))
        await github.markMissing("acme/missing")
        await github.setReadme(
            "owner/awesome-list",
            markdown: """
            ## Tools
            - [Valid](https://github.com/acme/valid) - Works
            - [Missing](https://github.com/acme/missing) - Gone
            """
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        let creation = try await service.create(input: "https://github.com/owner/awesome-list")
        try await service.parse(
            source: creation.source,
            defaultBranch: creation.defaultBranch
        ) { _ in }

        let saved = await repository.savedSource()
        #expect(saved?.entries.map(\.fullName) == ["acme/valid"])
        #expect(saved?.entries.first?.forks == 1)
        #expect(saved?.entries.first?.watchers == 10)
        #expect(saved?.entries.first?.defaultBranch == "main")
        #expect(saved?.entries.first?.sectionPath == ["Tools"])
    }

    @Test("自定义来源拒绝与现有精选或自定义来源重复")
    func customSourceRejectsDuplicateCanonicalRepository() async throws {
        let github = FakeAwesomeGitHub()
        let repository = FakeAwesomeRepository(existingSources: [Self.existingSource()])
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        await #expect(throws: AwesomeCustomSourceError.duplicateSource) {
            try await service.create(input: "https://github.com/OWNER/AWESOME-LIST")
        }
    }

    @Test("自定义来源没有有效 GitHub Repo 时保留卡片并标记失败")
    func customSourceWithoutValidRepositoryRetainsFailedCard() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setReadme(
            "owner/awesome-list",
            markdown: "- [External](https://example.com/tool) - Not a GitHub repository"
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        let creation = try await service.create(input: "owner/awesome-list")
        await #expect(throws: AwesomeCustomSourceError.noValidRepositories) {
            try await service.parse(
                source: creation.source,
                defaultBranch: creation.defaultBranch
            ) { _ in }
        }
        #expect(await repository.savedSource()?.source.id == creation.source.id)
        #expect(await repository.customSourceParseStates().first?.phase == .failed)
    }

    @Test("自定义来源中途失败保留已解析批次和进度")
    func customSourceFailureRetainsCommittedBatch() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        for index in 1 ... 20 {
            await github.setRepo(Self.repo(id: Int64(index + 1), fullName: "acme/repo-\(index)"))
        }
        await github.markFailing("acme/repo-21")
        await github.setReadme(
            "owner/awesome-list",
            markdown: (1 ... 21)
                .map { "- [Repo \($0)](https://github.com/acme/repo-\($0))" }
                .joined(separator: "\n")
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)
        let creation = try await service.create(input: "owner/awesome-list")

        await #expect(throws: FakeAwesomeGitHubError.rateLimited) {
            try await service.parse(
                source: creation.source,
                defaultBranch: creation.defaultBranch
            ) { _ in }
        }

        #expect(await repository.savedSource()?.entries.count == 20)
        let failed = await repository.customSourceParseStates().first
        #expect(failed?.phase == .failed)
        #expect(failed?.processedCount == 20)
        #expect(failed?.totalCount == 21)
    }

    private static func repo(
        id: Int64,
        fullName: String,
        isPrivate: Bool = false
    ) -> GitHubRepoDTO {
        let parts = fullName.split(separator: "/").map(String.init)
        return GitHubRepoDTO(
            id: id,
            name: parts[1],
            fullName: fullName,
            owner: GitHubUserDTO(id: id, login: parts[0], name: nil, avatarUrl: nil),
            description: "Description",
            language: "Swift",
            stargazersCount: 10,
            forksCount: 1,
            watchersCount: 10,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(fullName)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: 0,
            defaultBranch: "main",
            disabled: false,
            isTemplate: false,
            score: nil
        )
    }

    private static func existingSource() -> AwesomeSource {
        AwesomeSource(
            id: "managed",
            kind: .managed,
            displayName: "Existing",
            repoFullName: "owner/awesome-list",
            repoURL: URL(string: "https://github.com/owner/awesome-list")!,
            repoDescription: "Existing GitHub description",
            imageURL: nil,
            summaryZH: nil,
            summaryEN: nil,
            featured: false,
            sortOrder: 1,
            sourceStars: 0,
            sourceForks: 0,
            sourceWatchers: 0,
            sourceSubscribers: 0,
            sourceOpenIssues: 0,
            sourceLanguage: nil,
            languageBytes: [:],
            githubRepoCount: 1,
            externalEntryCount: 0,
            resourceEntryCount: 0,
            isAvailable: true,
            isEnabled: false,
            addedAt: .distantPast,
            lastSyncedAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

private actor AwesomeParseStateRecorder {
    private var values: [AwesomeCustomSourceParseState] = []

    func append(_ state: AwesomeCustomSourceParseState) { values.append(state) }
    func phases() -> [AwesomeCustomSourceParsePhase] { values.map(\.phase) }
}

private actor FakeAwesomeGitHub: AwesomeGitHubClientProtocol {
    private var repos: [String: GitHubRepoDTO] = [:]
    private var readmes: [String: Data] = [:]
    private var missing: Set<String> = []
    private var failing: Set<String> = []
    private var readmeRequests = 0

    func setRepo(_ repo: GitHubRepoDTO) { repos[repo.fullName.lowercased()] = repo }
    func setReadme(_ fullName: String, markdown: String) { readmes[fullName.lowercased()] = Data(markdown.utf8) }
    func markMissing(_ fullName: String) { missing.insert(fullName.lowercased()) }
    func markFailing(_ fullName: String) { failing.insert(fullName.lowercased()) }
    func readmeRequestCount() -> Int { readmeRequests }

    func awesomeRepository(owner: String, repo: String) async throws -> GitHubRepoDTO {
        let key = "\(owner)/\(repo)".lowercased()
        if failing.contains(key) { throw FakeAwesomeGitHubError.rateLimited }
        if missing.contains(key) { throw NetworkError.notFound }
        guard let value = repos[key] else { throw NetworkError.notFound }
        return value
    }

    func awesomeReadme(owner: String, repo: String) async throws -> Data {
        readmeRequests += 1
        return readmes["\(owner)/\(repo)".lowercased()] ?? Data()
    }
}

private enum FakeAwesomeGitHubError: Error {
    case rateLimited
}

private actor FakeAwesomeRepository: AwesomeRepositoryProtocol {
    struct Saved: Sendable {
        let source: AwesomeSource
        let entries: [AwesomeEntryDTO]
    }

    private var saved: Saved?
    private var existingSources: [AwesomeSource]
    private var parseStates: [String: AwesomeCustomSourceParseState] = [:]

    init(existingSources: [AwesomeSource] = []) {
        self.existingSources = existingSources
    }

    func savedSource() -> Saved? { saved }
    func sources() async -> [AwesomeSource] {
        existingSources + (saved.map { [$0.source] } ?? [])
    }
    func enabledSources() async -> [AwesomeSource] { await sources().filter(\.isEnabled) }
    func repositories(sourceID: String?) async -> [AwesomeRepositoryItem] { [] }
    func hasCompletedSourceSetup() async -> Bool { false }
    func refreshCatalog(policy: AwesomeRefreshPolicy) async throws -> [AwesomeSource] { [] }
    func refreshEnabledEntries(policy: AwesomeRefreshPolicy) async -> [String: String] { [:] }
    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws {}
    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws {}
    func removeCustomSource(id: String) async throws {}
    func customSourceParseStates() async -> [AwesomeCustomSourceParseState] {
        Array(parseStates.values)
    }
    func updateCustomSourceParseState(_ state: AwesomeCustomSourceParseState) async throws {
        parseStates[state.sourceID] = state
    }
    func customSourceEntryFullNames(sourceID: String) async -> Set<String> {
        Set(saved?.entries.map { $0.fullName.lowercased() } ?? [])
    }
    func customSourceEntryCount(sourceID: String) async -> Int { saved?.entries.count ?? 0 }
    func saveCustomSourceEntries(
        _ entries: [AwesomeEntryDTO],
        sourceID: String,
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        guard let saved else { return }
        var byID = Dictionary(uniqueKeysWithValues: saved.entries.map { ($0.ghRepoID, $0) })
        entries.forEach { byID[$0.ghRepoID] = $0 }
        self.saved = Saved(source: saved.source, entries: Array(byID.values))
        parseStates[sourceID] = parseState
    }
    func completeCustomSourceParsing(
        sourceID: String,
        externalEntryCount: Int,
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        parseStates[sourceID] = parseState
    }

    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws {
        saved = Saved(source: source, entries: entries)
    }

    func saveCustomSource(
        _ source: AwesomeSource,
        entries: [AwesomeEntryDTO],
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        saved = Saved(source: source, entries: entries)
        parseStates[source.id] = parseState
    }
}
