//
//  RepoDescriptionTranslationStore.swift
//  Starcat
//
//  仓库短描述的翻译。默认走系统翻译；用户也可以改回 Google。
//
//  为什么 Google 仍保留：有 Cloud Key 时可以批量，没有 Key 时公开接口是兜底。
//  系统翻译复用 README 的 Session Broker，不和 Google 请求抢同一把串行锁。
//
//  为什么不在同步事务里翻：全库描述可能有上千条。列表先显示原文，译文到达后
//  再替换。429 停止本轮，已写入的行留下，下次进入主界面、同步完成或手动继续再补。
//
//  星标静默任务和探索手动任务各有自己的 Task，取消一边不会取消另一边。
//  真正打 Google 时进 `RepoDescriptionTranslationGate` 排队。这是 actor：
//  关键词见 docs/7-工具与脚本/Swift-学习索引.md 的「actor」。
//  请求放在 actor 方法里，不把 MainActor 闭包丢进去，避免两边互相等待。
//

import Foundation
import Observation
#if canImport(Translation)
@preconcurrency import Translation
#endif

struct RepoDescriptionTranslationEntry: Equatable, Sendable {
    var sourceHash: String
    var targetLanguage: String
    var translatedText: String
    var updatedAt: String

    init(_ record: RepoDescriptionTranslationRecord) {
        sourceHash = record.sourceHash
        targetLanguage = record.targetLanguage
        translatedText = record.translatedText
        updatedAt = record.updatedAt
    }
}

enum ExploreDescriptionTranslationPhase: Equatable, Sendable {
    case running
    case paused
    case failed
}

struct ExploreDescriptionTranslationProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var phase: ExploreDescriptionTranslationPhase
}

protocol RepoDescriptionTranslating: Sendable {
    var route: GoogleTranslationClient.Route { get }
    func translateDescriptions(
        texts: [String],
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String]
}

extension GoogleTranslationClient: RepoDescriptionTranslating {
    func translateDescriptions(
        texts: [String],
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String] {
        try await translate(texts: texts, targetLanguage: targetLanguage)
    }
}

/// 串行化描述翻译的 Google 请求。星标任务和探索任务可以同时存在，但不会同时打接口。
private actor RepoDescriptionTranslationGate {
    func translate(
        client: any RepoDescriptionTranslating,
        texts: [String],
        target: ReadmeTranslationLanguage,
        pacePublicWeb: Bool
    ) async throws -> [String] {
        try Task.checkCancellation()
        let translated = try await client.translateDescriptions(texts: texts, targetLanguage: target)
        if pacePublicWeb {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        return translated
    }
}

@MainActor
@Observable
final class RepoDescriptionTranslationStore {
    private let settings: AppSettings
    private let repository: RepoDescriptionTranslationRepository
    private let injectedTranslator: (any RepoDescriptionTranslating)?
    private let injectedSystemTranslator: (any RepoDescriptionSystemTranslating)?
    private let translationGate = RepoDescriptionTranslationGate()
    private var starredTask: Task<Void, Never>?
    private var exploreTasks: [ExploreDescriptionTranslationScope: Task<Void, Never>] = [:]
    private var exploreGeneration: [ExploreDescriptionTranslationScope: Int] = [:]
    private var entries: [Int64: RepoDescriptionTranslationEntry] = [:]
    private(set) var exploreProgress: [ExploreDescriptionTranslationScope: ExploreDescriptionTranslationProgress] = [:]

    init(
        database: any DatabaseManaging,
        settings: AppSettings,
        translator: (any RepoDescriptionTranslating)? = nil,
        systemTranslator: (any RepoDescriptionSystemTranslating)? = nil
    ) {
        self.settings = settings
        self.repository = RepoDescriptionTranslationRepository(database: database)
        self.injectedTranslator = translator
        self.injectedSystemTranslator = systemTranslator
    }

    /// 默认模式且哈希、目标语言都对得上时返回译文。否则调用方继续显示原文。
    func translatedText(repoId: Int64, original: String) -> String? {
        guard settings.repoDescriptionDisplayMode == .translated else { return nil }
        guard let entry = entries[repoId] else { return nil }
        guard entry.targetLanguage == settings.effectiveReadmeTranslationLanguage.rawValue else { return nil }
        guard entry.sourceHash == RepoDescriptionTranslationHash.sha256(original) else { return nil }
        let translated = entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return nil }
        return translated
    }

    /// 进入主界面、切换账号库、同步完成时调用。测试进程不发网络请求。
    func scheduleRefresh() {
        guard !TestEnvironment.isRunning else { return }
        starredTask?.cancel()
        starredTask = Task { [weak self] in
            await self?.refreshStarred()
        }
    }

    /// 进行中则停止当前子菜单。已暂停或失败则从缺口继续。空闲则开始。
    /// `suppliedCandidates` 只给 Linux.do：它的目录在内存里，不在 SQLite。
    func toggleExplore(
        _ scope: ExploreDescriptionTranslationScope,
        suppliedCandidates: [RepoDescriptionTranslationCandidate]? = nil
    ) {
        guard !TestEnvironment.isRunning || hasInjectedTranslator else { return }
        if exploreTasks[scope] != nil {
            exploreGeneration[scope, default: 0] += 1
            exploreTasks[scope]?.cancel()
            exploreTasks[scope] = nil
            setProgress(nil, for: scope)
            return
        }
        let generation = (exploreGeneration[scope] ?? 0) + 1
        exploreGeneration[scope] = generation
        let candidates = suppliedCandidates
        exploreTasks[scope] = Task { [weak self] in
            await self?.runExploreTranslation(
                scope,
                suppliedCandidates: candidates,
                generation: generation
            )
        }
    }

    func runExploreTranslation(
        _ scope: ExploreDescriptionTranslationScope,
        suppliedCandidates: [RepoDescriptionTranslationCandidate]? = nil,
        generation: Int? = nil
    ) async {
        guard !TestEnvironment.isRunning || hasInjectedTranslator else { return }
        defer {
            if generation == nil || exploreGeneration[scope] == generation {
                exploreTasks[scope] = nil
            }
        }
        let target = settings.effectiveReadmeTranslationLanguage
        do {
            try await repository.deleteWhereTargetDiffers(from: target.rawValue)
            guard isCurrent(scope, generation: generation) else { return }
            try await reloadEntries()
            let pending = try await pendingCandidates(
                scope: scope,
                suppliedCandidates: suppliedCandidates,
                target: target
            )
            guard isCurrent(scope, generation: generation) else { return }
            guard !pending.isEmpty else {
                setProgress(nil, for: scope)
                return
            }

            let baseCompleted = resumeCompleted(for: scope)
            var completed = baseCompleted
            let total = baseCompleted + pending.count
            setProgress(
                ExploreDescriptionTranslationProgress(completed: completed, total: total, phase: .running),
                for: scope
            )

            switch settings.repoDescriptionTranslationEngine {
            case .google:
                try await translateExploreWithGoogle(
                    pending: pending,
                    target: target,
                    scope: scope,
                    generation: generation,
                    completed: &completed,
                    total: total
                )
            case .system:
                try await translateExploreWithSystem(
                    pending: pending,
                    target: target,
                    scope: scope,
                    generation: generation,
                    baseCompleted: baseCompleted
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(scope, generation: generation) else { return }
            let current = exploreProgress[scope]
            publish(
                completed: current?.completed ?? 0,
                total: current?.total ?? 0,
                phase: .failed,
                scope: scope,
                generation: generation
            )
            AppLog.general.debug(
                "Explore description translation stopped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshStarred() async {
        let target = settings.effectiveReadmeTranslationLanguage
        do {
            try await repository.deleteWhereTargetDiffers(from: target.rawValue)
            try Task.checkCancellation()
            try await reloadEntries()

            let pending = try await repository.fetchStarredDescriptions().filter {
                needsTranslation($0, target: target)
            }
            guard !pending.isEmpty else { return }

            switch settings.repoDescriptionTranslationEngine {
            case .google:
                try await translateStarredWithGoogle(pending: pending, target: target)
            case .system:
                try await performSystemTranslation(pending: pending, target: target) { batch, texts in
                    try await self.persistStarredBatch(batch, translated: texts, target: target)
                    return batch.count
                }
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.general.debug(
                "Repo description translation stopped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private var hasInjectedTranslator: Bool {
        injectedTranslator != nil || injectedSystemTranslator != nil
    }

    private func translateExploreWithGoogle(
        pending: [RepoDescriptionTranslationCandidate],
        target: ReadmeTranslationLanguage,
        scope: ExploreDescriptionTranslationScope,
        generation: Int?,
        completed: inout Int,
        total: Int
    ) async throws {
        let client = makeTranslator()
        let pace = injectedTranslator == nil && client.route == .publicWeb
        let batchSize = client.route == .cloud ? 8 : 1
        var index = 0
        while index < pending.count {
            guard isCurrent(scope, generation: generation) else { return }
            let end = min(index + batchSize, pending.count)
            let slice = Array(pending[index..<end])
            let batch = slice.filter { needsTranslation($0, target: target) }
            completed += slice.count - batch.count
            if batch.isEmpty {
                publish(completed: completed, total: total, phase: .running, scope: scope, generation: generation)
                index = end
                continue
            }
            let translated: [String]
            do {
                translated = try await translationGate.translate(
                    client: client,
                    texts: batch.map(\.description),
                    target: target,
                    pacePublicWeb: pace
                )
            } catch is CancellationError {
                return
            } catch GoogleTranslationError.rateLimited {
                publish(completed: completed, total: total, phase: .paused, scope: scope, generation: generation)
                return
            } catch {
                publish(completed: completed, total: total, phase: .failed, scope: scope, generation: generation)
                AppLog.general.debug(
                    "Explore description translation stopped: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            guard isCurrent(scope, generation: generation) else { return }
            guard translated.count == batch.count else {
                publish(completed: completed, total: total, phase: .failed, scope: scope, generation: generation)
                return
            }
            completed += try await persistExploreBatch(batch, translated: translated, target: target)
            publish(completed: completed, total: total, phase: .running, scope: scope, generation: generation)
            index = end
        }
        guard isCurrent(scope, generation: generation) else { return }
        setProgress(nil, for: scope)
    }

    private func translateStarredWithGoogle(
        pending: [RepoDescriptionTranslationCandidate],
        target: ReadmeTranslationLanguage
    ) async throws {
        let client = makeTranslator()
        let pace = injectedTranslator == nil && client.route == .publicWeb
        let batchSize = client.route == .cloud ? 8 : 1
        var index = 0
        while index < pending.count {
            try Task.checkCancellation()
            let end = min(index + batchSize, pending.count)
            let batch = Array(pending[index..<end]).filter { needsTranslation($0, target: target) }
            if batch.isEmpty {
                index = end
                continue
            }
            let translated = try await translationGate.translate(
                client: client,
                texts: batch.map(\.description),
                target: target,
                pacePublicWeb: pace
            )
            guard translated.count == batch.count else { return }
            try await persistStarredBatch(batch, translated: translated, target: target)
            index = end
        }
    }

    private func translateExploreWithSystem(
        pending: [RepoDescriptionTranslationCandidate],
        target: ReadmeTranslationLanguage,
        scope: ExploreDescriptionTranslationScope,
        generation: Int?,
        baseCompleted: Int
    ) async throws {
        let sendingCount = RepoDescriptionSourceGrouping.groups(from: pending, target: target)
            .sending
            .reduce(0) { $0 + $1.candidates.count }
        guard sendingCount > 0 else {
            setProgress(nil, for: scope)
            return
        }
        let total = baseCompleted + sendingCount
        let completed = ProgressCounter(baseCompleted)
        setProgress(
            ExploreDescriptionTranslationProgress(completed: completed.value, total: total, phase: .running),
            for: scope
        )
        do {
            try await performSystemTranslation(pending: pending, target: target) { batch, texts in
                guard self.isCurrent(scope, generation: generation) else { return 0 }
                let written = try await self.persistExploreBatch(batch, translated: texts, target: target)
                completed.value += written
                self.publish(
                    completed: completed.value,
                    total: total,
                    phase: .running,
                    scope: scope,
                    generation: generation
                )
                return written
            }
            guard isCurrent(scope, generation: generation) else { return }
            setProgress(nil, for: scope)
        } catch is CancellationError {
            return
        } catch SystemTranslationError.cancelled {
            return
        } catch let error as SystemTranslationError where Self.pausesSystemTranslation(error) {
            publish(completed: completed.value, total: total, phase: .paused, scope: scope, generation: generation)
        } catch {
            publish(completed: completed.value, total: total, phase: .failed, scope: scope, generation: generation)
            AppLog.general.debug(
                "Explore description translation stopped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performSystemTranslation(
        pending: [RepoDescriptionTranslationCandidate],
        target: ReadmeTranslationLanguage,
        persist: @escaping ([RepoDescriptionTranslationCandidate], [String]) async throws -> Int
    ) async throws {
        if TestEnvironment.isRunning, injectedSystemTranslator == nil { return }
        let translator = injectedSystemTranslator ?? AppleRepoDescriptionSystemTranslator()
        let partition = RepoDescriptionSourceGrouping.groups(from: pending, target: target)
        for group in partition.sending {
            let batches = RepoDescriptionTranslationBatches.make(group.candidates)
            guard !batches.isEmpty else { continue }
            try await translator.translate(
                batches: batches,
                sourceLanguage: group.sourceLanguage,
                targetLanguage: target
            ) { batch, texts in
                guard texts.count == batch.count else {
                    throw SystemTranslationError.incompleteResult
                }
                _ = try await persist(batch, texts)
            }
        }
    }

    private static func pausesSystemTranslation(_ error: SystemTranslationError) -> Bool {
        switch error {
        case .languagePackMissing, .languageUnsupported, .timedOut:
            return true
        case .frameworkUnavailable, .sessionUnavailable, .sourceLanguageUndetected,
             .incompleteResult, .emptyBatch, .cancelled:
            return false
        }
    }

    private func pendingCandidates(
        scope: ExploreDescriptionTranslationScope,
        suppliedCandidates: [RepoDescriptionTranslationCandidate]?,
        target: ReadmeTranslationLanguage
    ) async throws -> [RepoDescriptionTranslationCandidate] {
        let raw: [RepoDescriptionTranslationCandidate]
        if scope == .linuxDo {
            raw = suppliedCandidates ?? []
        } else {
            raw = try await repository.fetchExploreCandidates(
                scope: scope,
                hiddenWeeklySources: settings.exploreCatalogPreferences.hiddenWeeklySources
            )
        }
        return Self.deduped(raw).filter { needsTranslation($0, target: target) }
    }

    private func persistExploreBatch(
        _ batch: [RepoDescriptionTranslationCandidate],
        translated: [String],
        target: ReadmeTranslationLanguage
    ) async throws -> Int {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        var updates: [Int64: RepoDescriptionTranslationEntry] = [:]
        for (candidate, text) in zip(batch, translated) {
            guard let record = Self.record(candidate: candidate, translated: text, target: target, now: now) else {
                continue
            }
            try await repository.upsertExplore(record)
            try await repository.upsertStarredIfDescriptionMatches(record, sourceDescription: candidate.description)
            updates[candidate.repoId] = RepoDescriptionTranslationEntry(record)
        }
        remember(updates)
        return updates.count
    }

    private func persistStarredBatch(
        _ batch: [RepoDescriptionTranslationCandidate],
        translated: [String],
        target: ReadmeTranslationLanguage
    ) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        var updates: [Int64: RepoDescriptionTranslationEntry] = [:]
        for (candidate, text) in zip(batch, translated) {
            guard let record = Self.record(candidate: candidate, translated: text, target: target, now: now) else {
                continue
            }
            try await repository.upsert(record)
            updates[candidate.repoId] = RepoDescriptionTranslationEntry(record)
        }
        remember(updates)
    }

    private func reloadEntries() async throws {
        let starred = try await repository.loadAll()
        let explore = try await repository.loadExplore()
        entries = Self.merge(
            starred: starred,
            explore: explore,
            targetLanguage: settings.effectiveReadmeTranslationLanguage.rawValue
        )
    }

    private func remember(_ updates: [Int64: RepoDescriptionTranslationEntry]) {
        guard !updates.isEmpty else { return }
        var updated = entries
        for (repoId, entry) in updates {
            updated[repoId] = entry
        }
        entries = updated
    }

    private func needsTranslation(
        _ candidate: RepoDescriptionTranslationCandidate,
        target: ReadmeTranslationLanguage
    ) -> Bool {
        guard RepoDescriptionLanguageGate.needsTranslation(candidate.description) else { return false }
        let hash = RepoDescriptionTranslationHash.sha256(candidate.description)
        guard let entry = entries[candidate.repoId] else { return true }
        return entry.sourceHash != hash || entry.targetLanguage != target.rawValue
    }

    private func resumeCompleted(for scope: ExploreDescriptionTranslationScope) -> Int {
        guard let progress = exploreProgress[scope], progress.phase != .running else { return 0 }
        return progress.completed
    }

    private func publish(
        completed: Int,
        total: Int,
        phase: ExploreDescriptionTranslationPhase,
        scope: ExploreDescriptionTranslationScope,
        generation: Int?
    ) {
        guard isCurrent(scope, generation: generation) else { return }
        setProgress(
            ExploreDescriptionTranslationProgress(completed: completed, total: total, phase: phase),
            for: scope
        )
    }

    private func setProgress(
        _ progress: ExploreDescriptionTranslationProgress?,
        for scope: ExploreDescriptionTranslationScope
    ) {
        var updated = exploreProgress
        updated[scope] = progress
        exploreProgress = updated
    }

    private func isCurrent(_ scope: ExploreDescriptionTranslationScope, generation: Int?) -> Bool {
        if Task.isCancelled { return false }
        guard let generation else { return true }
        return exploreGeneration[scope] == generation
    }

    private func makeTranslator() -> any RepoDescriptionTranslating {
        if let injectedTranslator { return injectedTranslator }
        let apiKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: GoogleTranslationClient.keychainServiceID
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GoogleTranslationClient(apiKey: apiKey)
    }

    private static func record(
        candidate: RepoDescriptionTranslationCandidate,
        translated: String,
        target: ReadmeTranslationLanguage,
        now: String
    ) -> RepoDescriptionTranslationRecord? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RepoDescriptionTranslationRecord(
            repoId: candidate.repoId,
            sourceHash: RepoDescriptionTranslationHash.sha256(candidate.description),
            targetLanguage: target.rawValue,
            translatedText: trimmed,
            updatedAt: now
        )
    }

    private static func deduped(
        _ candidates: [RepoDescriptionTranslationCandidate]
    ) -> [RepoDescriptionTranslationCandidate] {
        var seen: Set<Int64> = []
        return candidates.filter { seen.insert($0.repoId).inserted }
    }

    /// 同一 id 两表都有时，优先当前目标语言，再取更新时间更晚的一条。
    /// 展示时仍用原文哈希把对不上的译文退回原文。
    private static func merge(
        starred: [RepoDescriptionTranslationRecord],
        explore: [RepoDescriptionTranslationRecord],
        targetLanguage: String
    ) -> [Int64: RepoDescriptionTranslationEntry] {
        var map: [Int64: RepoDescriptionTranslationEntry] = [:]
        func consider(_ record: RepoDescriptionTranslationRecord) {
            let entry = RepoDescriptionTranslationEntry(record)
            if let existing = map[record.repoId] {
                map[record.repoId] = preferred(existing, entry, targetLanguage: targetLanguage)
            } else {
                map[record.repoId] = entry
            }
        }
        explore.forEach(consider)
        starred.forEach(consider)
        return map
    }

    private static func preferred(
        _ lhs: RepoDescriptionTranslationEntry,
        _ rhs: RepoDescriptionTranslationEntry,
        targetLanguage: String
    ) -> RepoDescriptionTranslationEntry {
        let lhsCurrent = lhs.targetLanguage == targetLanguage
        let rhsCurrent = rhs.targetLanguage == targetLanguage
        if lhsCurrent != rhsCurrent { return lhsCurrent ? lhs : rhs }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }
}

private final class ProgressCounter: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

protocol RepoDescriptionSystemTranslating: Sendable {
    @MainActor
    func translate(
        batches: [[RepoDescriptionTranslationCandidate]],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage,
        onBatch: @escaping @MainActor ([RepoDescriptionTranslationCandidate], [String]) async throws -> Void
    ) async throws
}

/// 把短描述批次交给已经挂在主窗口上的系统翻译会话。
struct AppleRepoDescriptionSystemTranslator: RepoDescriptionSystemTranslating {
    @MainActor
    func translate(
        batches: [[RepoDescriptionTranslationCandidate]],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage,
        onBatch: @escaping @MainActor ([RepoDescriptionTranslationCandidate], [String]) async throws -> Void
    ) async throws {
        #if canImport(Translation)
        let payload = batches.map { batch in
            batch.map { (sourceHash: String($0.repoId), text: $0.description) }
        }
        try await SystemTranslationSessionBroker.shared.translateBatches(
            batches: payload,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            onBatch: { responses, batchIndex in
                let batch = batches[batchIndex]
                try await onBatch(batch, Self.alignedTexts(responses: responses, batch: batch))
            }
        )
        #else
        throw SystemTranslationError.frameworkUnavailable
        #endif
    }

    #if canImport(Translation)
    private static func alignedTexts(
        responses: [TranslationSession.Response],
        batch: [RepoDescriptionTranslationCandidate]
    ) -> [String] {
        if responses.count == batch.count {
            return responses.map(\.targetText)
        }
        var byID: [String: String] = [:]
        for response in responses {
            if let identifier = response.clientIdentifier {
                byID[identifier] = response.targetText
            }
        }
        guard byID.count == batch.count else {
            return responses.map(\.targetText)
        }
        return batch.map { byID[String($0.repoId)] ?? "" }
    }
    #endif
}
