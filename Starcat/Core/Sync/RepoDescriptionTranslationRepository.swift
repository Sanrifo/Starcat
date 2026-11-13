//
//  RepoDescriptionTranslationRepository.swift
//  Starcat
//
//  仓库短描述译文的读写。星标搜索索引由数据库触发器维护，这里不直接写 FTS。
//  探索译文只服务列表和详情展示，不进入星标全文索引。
//

import Foundation
import GRDB

struct RepoDescriptionTranslationRepository: Sendable {
    let database: any DatabaseManaging

    func loadAll() async throws -> [RepoDescriptionTranslationRecord] {
        try await database.writer.read { db in
            try RepoDescriptionTranslationRecord.fetchAll(db)
        }
    }

    func loadExplore() async throws -> [RepoDescriptionTranslationRecord] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT repo_id, source_hash, target_language, translated_text, updated_at
                FROM explore_description_translations
                """)
            return rows.compactMap(Self.record(from:))
        }
    }

    func upsert(_ record: RepoDescriptionTranslationRecord) async throws {
        try await database.writer.write { db in
            var record = record
            try record.save(db)
        }
    }

    func upsertExplore(_ record: RepoDescriptionTranslationRecord) async throws {
        try await database.writer.write { db in
            try Self.writeExplore(record, db: db)
        }
    }

    /// 只有用户库里的原文和这次翻译的原文一致时才写入星标表。
    /// 描述不同就留给星标任务，避免用探索快照的哈希盖掉用户库里的另一段描述。
    func upsertStarredIfDescriptionMatches(
        _ record: RepoDescriptionTranslationRecord,
        sourceDescription: String
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo_description_translations (
                        repo_id, source_hash, target_language, translated_text, updated_at
                    )
                    SELECT ?, ?, ?, ?, ?
                    WHERE EXISTS (
                        SELECT 1 FROM repos WHERE id = ? AND description = ?
                    )
                    ON CONFLICT(repo_id) DO UPDATE SET
                        source_hash = excluded.source_hash,
                        target_language = excluded.target_language,
                        translated_text = excluded.translated_text,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    record.repoId,
                    record.sourceHash,
                    record.targetLanguage,
                    record.translatedText,
                    record.updatedAt,
                    record.repoId,
                    sourceDescription
                ]
            )
        }
    }

    /// 目标语言变了之后，旧语言译文不能继续留在 trigram 索引或探索展示里。
    func deleteWhereTargetDiffers(from language: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM repo_description_translations
                    WHERE target_language <> ?
                    """,
                arguments: [language]
            )
            try db.execute(
                sql: """
                    DELETE FROM explore_description_translations
                    WHERE target_language <> ?
                    """,
                arguments: [language]
            )
        }
    }

    func fetchStarredDescriptions() async throws -> [RepoDescriptionTranslationCandidate] {
        try await fetchCandidates(
            sql: """
                SELECT id AS repo_id, description
                FROM repos
                WHERE is_starred = 1
                  AND description IS NOT NULL
                  AND length(trim(description)) > 0
                ORDER BY id
                """
        )
    }

    /// 只读本地快照。Linux.do 的目录在内存里，由调用方传入。
    func fetchExploreCandidates(
        scope: ExploreDescriptionTranslationScope,
        hiddenWeeklySources: Set<String>
    ) async throws -> [RepoDescriptionTranslationCandidate] {
        switch scope {
        case .linuxDo:
            return []
        case .discover, .popular, .newReleases:
            guard let category = Self.discoveryCategory(for: scope) else { return [] }
            return try await fetchCandidates(
                sql: """
                    SELECT r.repo_id AS repo_id, r.description AS description
                    FROM discovery_bulk_repos r
                    JOIN discovery_bulk_category_memberships m ON m.repo_id = r.repo_id
                    WHERE m.category = ?
                      AND r.description IS NOT NULL
                      AND length(trim(r.description)) > 0
                    ORDER BY r.repo_id
                    """,
                arguments: [category]
            )
        case .trending:
            // cached_at 新的在前，同一仓库只留最新一条描述。没有数字 id 的行保持原文。
            return try await fetchCandidates(
                sql: """
                    SELECT gh_repo_id AS repo_id, description
                    FROM trending_repos
                    WHERE gh_repo_id IS NOT NULL
                      AND description IS NOT NULL
                      AND length(trim(description)) > 0
                    ORDER BY cached_at DESC, gh_repo_id
                    """
            )
        case .weekly:
            let sourceScope = Self.weeklySourceScope(excluding: hiddenWeeklySources)
            return try await fetchCandidates(
                sql: """
                    SELECT gh_repo_id AS repo_id, description
                    FROM weekly_bulk_repos
                    WHERE description IS NOT NULL
                      AND length(trim(description)) > 0
                      AND \(sourceScope.sql)
                    ORDER BY gh_repo_id
                    """,
                arguments: sourceScope.arguments
            )
        case .awesomeSource(let sourceID):
            return try await fetchCandidates(
                sql: """
                    SELECT gh_repo_id AS repo_id, description
                    FROM awesome_entries
                    WHERE source_id = ?
                      AND description IS NOT NULL
                      AND length(trim(description)) > 0
                    ORDER BY gh_repo_id
                    """,
                arguments: [sourceID]
            )
        }
    }

    private func fetchCandidates(
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) async throws -> [RepoDescriptionTranslationCandidate] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            var seen: Set<Int64> = []
            var result: [RepoDescriptionTranslationCandidate] = []
            for row in rows {
                guard let repoId: Int64 = row["repo_id"],
                      let description: String = row["description"],
                      seen.insert(repoId).inserted
                else { continue }
                result.append(RepoDescriptionTranslationCandidate(repoId: repoId, description: description))
            }
            return result
        }
    }

    private static func record(from row: Row) -> RepoDescriptionTranslationRecord? {
        guard let repoId: Int64 = row["repo_id"],
              let sourceHash: String = row["source_hash"],
              let targetLanguage: String = row["target_language"],
              let translatedText: String = row["translated_text"],
              let updatedAt: String = row["updated_at"]
        else { return nil }
        return RepoDescriptionTranslationRecord(
            repoId: repoId,
            sourceHash: sourceHash,
            targetLanguage: targetLanguage,
            translatedText: translatedText,
            updatedAt: updatedAt
        )
    }

    private static func writeExplore(_ record: RepoDescriptionTranslationRecord, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO explore_description_translations (
                    repo_id, source_hash, target_language, translated_text, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    source_hash = excluded.source_hash,
                    target_language = excluded.target_language,
                    translated_text = excluded.translated_text,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                record.repoId,
                record.sourceHash,
                record.targetLanguage,
                record.translatedText,
                record.updatedAt
            ]
        )
    }

    private static func discoveryCategory(for scope: ExploreDescriptionTranslationScope) -> String? {
        switch scope {
        case .discover: return "discover"
        case .popular: return "popular"
        case .newReleases: return "new_releases"
        default: return nil
        }
    }

    /// 与周刊列表同一条启用来源规则：隐藏来源里的仓库不译，多来源仓库只要还属于某个可见来源就保留。
    private static func weeklySourceScope(
        excluding hiddenSources: Set<String>
    ) -> (sql: String, arguments: StatementArguments) {
        guard !hiddenSources.isEmpty else { return ("1", StatementArguments()) }
        let placeholders = Array(repeating: "?", count: hiddenSources.count).joined(separator: ", ")
        return (
            """
            EXISTS (
                SELECT 1 FROM json_each(COALESCE(source_types_json, '[]'))
                WHERE value NOT IN (\(placeholders))
            )
            """,
            StatementArguments(hiddenSources.sorted())
        )
    }
}
