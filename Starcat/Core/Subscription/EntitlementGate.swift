//
//  EntitlementGate.swift
//  Starcat
//
//  Pro 权益与免费限额门控。
//

import Foundation
import Observation

/// 需要 Pro 或受免费限额控制的功能。
///
/// 枚举放在 Core/Subscription，是为了让业务层只表达“我要使用哪个能力”，不关心
/// StoreKit 或数量上限的具体实现。
/// 仓库上下文与本地代码图谱向所有用户开放，不属于 Pro 门控能力。
///
/// **历史变更（dong4j 2026-06-21 拍板放开）**：曾有 `case anySearchWeb`，对应
/// AnySearch Web 搜索的 Pro 拦截。dong4j 决定网页搜索对所有用户开放后：
///  - 该 case 整体删除（含 `title` switch 分支）
///  - `EntitlementGate.requirePro(.anySearchWeb)` 调用点全部撤除
///  - `subscription.feature.anySearchWeb` i18n key 一并清理（orphan）
///  - `SearchCenterViewModel.canRunExplicitWebSearch` 改保留为 stub 函数，
///    详见该函数顶部 doc comment
enum ProFeature: String, CaseIterable, Sendable {
    case aiSummary
    case aiTags
    case aiChat
    case batchAI
    case autoOrganize
    case readmeTranslation
    case semanticSearch
    case knowledgeRAG
    case releaseSubscription
    case tagCreation
    case cloudSync
    case repoHealth
    case mcpService
    case smartCollections
    /// Pro 功能：外部 Wiki 查阅（详情页 hero action 区 Wiki 入口）。
    case externalWiki
    /// Pro 功能：相似仓库推荐（详情页 hero action 区推荐入口）。
    case repoRecommendations

    var title: String {
        switch self {
        case .aiSummary: return String.l10n("subscription.feature.aiSummary")
        case .aiTags: return String.l10n("subscription.feature.aiTags")
        case .aiChat: return String.l10n("subscription.feature.aiChat")
        case .batchAI: return String.l10n("subscription.feature.batchAI")
        case .autoOrganize: return String.l10n("subscription.feature.autoOrganize")
        case .readmeTranslation: return String.l10n("subscription.feature.readmeTranslation")
        case .semanticSearch: return String.l10n("subscription.feature.semanticSearch")
        case .knowledgeRAG: return String.l10n("subscription.feature.knowledgeRAG")
        case .releaseSubscription: return String.l10n("subscription.feature.releaseSubscription")
        case .tagCreation: return String.l10n("subscription.feature.tagCreation")
        case .cloudSync: return String.l10n("subscription.feature.cloudSync")
        case .repoHealth: return String.l10n("subscription.feature.repoHealth")
        case .mcpService: return String.l10n("subscription.feature.mcpService")
        case .smartCollections: return String.l10n("subscription.feature.smartCollections")
        case .externalWiki: return String.l10n("subscription.feature.externalWiki")
        case .repoRecommendations: return String.l10n("subscription.feature.repoRecommendations")
        }
    }

}

/// 门控失败原因。
enum EntitlementGateError: Error, LocalizedError, Equatable {
    case requiresPro(feature: ProFeature)
    case tagLimitReached(limit: Int)
    case releaseSubscriptionLimitReached(limit: Int)
    case smartCollectionLimitReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature):
            return String(format: String.l10n("subscription.gate.requiresProFormat"), feature.title)
        case .tagLimitReached(let limit):
            return String(format: String.l10n("subscription.gate.tagLimitFormat"), limit)
        case .releaseSubscriptionLimitReached(let limit):
            return String(format: String.l10n("subscription.gate.releaseLimitFormat"), limit)
        case .smartCollectionLimitReached(let limit):
            return String(format: String.l10n("subscription.gate.smartCollectionLimitFormat"), limit)
        }
    }

    var feature: ProFeature {
        switch self {
        case .requiresPro(let feature):
            return feature
        case .tagLimitReached:
            return .tagCreation
        case .releaseSubscriptionLimitReached:
            return .releaseSubscription
        case .smartCollectionLimitReached:
            return .smartCollections
        }
    }
}

/// 统一权益门控。
///
/// 业务层不要直接读取 `AppSettings.isProUser` 来判断是否放行；这样可以保证 StoreKit、
/// 数量上限和后续 CloudKit Pro 门控都走同一条规则。
@MainActor
@Observable
final class EntitlementGate {
    static let freeTagLimit = 20
    static let freeReleaseSubscriptionLimit = 5
    static let freeSmartCollectionLimit = 4

    private let entitlementProvider: any ProEntitlementProviding
    private let userIDProvider: @MainActor () -> Int64?

    init(
        entitlementProvider: any ProEntitlementProviding,
        userIDProvider: @escaping @MainActor () -> Int64?
    ) {
        self.entitlementProvider = entitlementProvider
        self.userIDProvider = userIDProvider
    }

    /// 付费墙已取消（2026-11-12）。订阅状态仍由 provider 持有，但不再决定能否使用功能。
    var isProUser: Bool {
        _ = entitlementProvider
        return true
    }

    /// 功能校验。付费墙取消后一律放行，保留方法签名以免调用点散落判断。
    func requirePro(_ feature: ProFeature) throws {
        _ = feature
    }

    /// 功能校验。`usesLocalOnly` 仍由调用方传入，门控不再据此拦截。
    func requirePro(_ feature: ProFeature, usesLocalOnly: Bool) throws {
        _ = (feature, usesLocalOnly)
    }

    func validateTagCreation(currentTagCount: Int) throws {
        _ = currentTagCount
    }

    func validateReleaseSubscription(activeSubscriptionCount: Int, isAlreadySubscribed: Bool) throws {
        _ = (activeSubscriptionCount, isAlreadySubscribed)
    }

    func validateSmartCollectionCreation(currentCount: Int) throws {
        _ = currentCount
    }
}
