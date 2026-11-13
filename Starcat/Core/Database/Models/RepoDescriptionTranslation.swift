//
//  RepoDescriptionTranslation.swift
//  Starcat
//
//  仓库短描述的展示译文。原文始终留在 `repos.description`。
//
//  为什么单独成表：全文搜索、AI 上下文和 GitHub 同步都读原文。译文只服务列表展示
//  和中文关键词召回，描述一变就由数据库触发器整行作废。
//

import CryptoKit
import Foundation
import GRDB
import NaturalLanguage

/// 列表描述的展示模式。搜索不读这个值，两种模式下都同时命中原文和译文。
enum RepoDescriptionDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 有对应当前描述的译文时显示译文，否则显示原文。
    case translated
    /// 始终显示 GitHub 原文。
    case original

    var id: String { rawValue }
}

/// 一行仓库描述译文。`repo_id` 同时是主键和 FTS `content_rowid`。
struct RepoDescriptionTranslationRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    static let databaseTableName = "repo_description_translations"

    var repoId: Int64
    var sourceHash: String
    var targetLanguage: String
    var translatedText: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case sourceHash = "source_hash"
        case targetLanguage = "target_language"
        case translatedText = "translated_text"
        case updatedAt = "updated_at"
    }
}

/// 待翻译的仓库描述。`description` 是原文，哈希也按这串计算。
struct RepoDescriptionTranslationCandidate: Equatable, Sendable {
    var repoId: Int64
    var description: String
}

/// 仓库短描述的翻译方式。不包含 AI，避免和 README 的全局引擎混在一个菜单里。
enum RepoDescriptionTranslationEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case google

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .system: "readme.translate.engine.system"
        case .google: "readme.translate.engine.google"
        }
    }
}

/// 探索侧栏一次手动翻译的范围。三级语言和话题筛选只是同一份快照的视图，不单独成任务。
enum ExploreDescriptionTranslationScope: Hashable, Sendable {
    case discover
    case popular
    case newReleases
    case trending
    case weekly
    case linuxDo
    case awesomeSource(String)
}

/// 探索译文表。无外键、无 FTS：快照仓库不在用户库里，中文搜索也不走这张表。
enum ExploreDescriptionTranslationSchema {
    static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS explore_description_translations (
            repo_id INTEGER PRIMARY KEY,
            source_hash TEXT NOT NULL,
            target_language TEXT NOT NULL,
            translated_text TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
}

enum RepoDescriptionTranslationHash {
    /// 描述原文的稳定指纹。展示和缓存都用同一串，避免 trim 前后各算一次对不上。
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 短描述的中文判断。一行描述太短，不走 README 那种分段投票。
enum RepoDescriptionLanguageGate {
    /// 汉字占字母类字符达到一半，就当作已经是中文，不再请求翻译。
    static let chineseLetterRatio = 0.5

    static func needsTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var letters = 0
        var han = 0
        for character in trimmed {
            for scalar in character.unicodeScalars where CharacterSet.letters.contains(scalar) {
                letters += 1
                if isHan(scalar) {
                    han += 1
                }
            }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) < chineseLetterRatio
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

/// 短描述送系统翻译前的源语言分组。
///
/// 不能把一整份列表投成一种语言：发现和周刊里英文、日文会混在一起。
/// 识别不到、又以拉丁字母为主的短句归入英文；其余留原文，不猜语言包。
enum RepoDescriptionSourceGrouping {
    struct Group: Equatable, Sendable {
        var sourceLanguage: ReadmeTranslationLanguage
        var candidates: [RepoDescriptionTranslationCandidate]
    }

    static func groups(
        from candidates: [RepoDescriptionTranslationCandidate],
        target: ReadmeTranslationLanguage
    ) -> (sending: [Group], skipped: [RepoDescriptionTranslationCandidate]) {
        var buckets: [ReadmeTranslationLanguage: [RepoDescriptionTranslationCandidate]] = [:]
        var order: [ReadmeTranslationLanguage] = []
        var skipped: [RepoDescriptionTranslationCandidate] = []
        for candidate in candidates {
            guard let language = sourceLanguage(for: candidate.description, target: target) else {
                skipped.append(candidate)
                continue
            }
            if buckets[language] == nil {
                order.append(language)
            }
            buckets[language, default: []].append(candidate)
        }
        let sending = order.map { Group(sourceLanguage: $0, candidates: buckets[$0] ?? []) }
        return (sending, skipped)
    }

    /// 返回 nil 表示这条不送系统翻译：已是目标语言、中文门控跳过，或无法归类。
    static func sourceLanguage(
        for text: String,
        target: ReadmeTranslationLanguage
    ) -> ReadmeTranslationLanguage? {
        guard RepoDescriptionLanguageGate.needsTranslation(text) else { return nil }
        return resolvedSource(recognized: recognize(text), text: text, target: target)
    }

    /// 识别结果优先。识别不到时，拉丁字母为主的短句归入英文，避免整批猜成同一种语言。
    static func resolvedSource(
        recognized: ReadmeTranslationLanguage?,
        text: String,
        target: ReadmeTranslationLanguage
    ) -> ReadmeTranslationLanguage? {
        if let recognized {
            return recognized == target ? nil : recognized
        }
        if isMostlyLatin(text), target != .english {
            return .english
        }
        return nil
    }

    private static func recognize(_ text: String) -> ReadmeTranslationLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return TranslationSourceLanguageGate.mappedLanguage(from: dominant)
    }

    private static func isMostlyLatin(_ text: String) -> Bool {
        var letters = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            letters += 1
            if isLatin(scalar) { latin += 1 }
        }
        guard letters > 0 else { return false }
        return Double(latin) / Double(letters) >= 0.5
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
            return true
        default:
            return false
        }
    }
}

/// 系统翻译的短描述批次。和 README 后续批次同一上限：10 条或 3500 字。
enum RepoDescriptionTranslationBatches {
    static let maxCount = 10
    static let maxCharacters = 3_500

    static func make(
        _ candidates: [RepoDescriptionTranslationCandidate]
    ) -> [[RepoDescriptionTranslationCandidate]] {
        var remaining = ArraySlice(candidates)
        var result: [[RepoDescriptionTranslationCandidate]] = []
        while !remaining.isEmpty {
            var batch: [RepoDescriptionTranslationCandidate] = []
            var characters = 0
            while let next = remaining.first, batch.count < maxCount {
                if !batch.isEmpty, characters + next.description.count > maxCharacters {
                    break
                }
                batch.append(next)
                characters += next.description.count
                remaining = remaining.dropFirst()
            }
            guard !batch.isEmpty else { break }
            result.append(batch)
        }
        return result
    }
}
