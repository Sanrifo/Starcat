//
//  EntitlementGateTests.swift
//  StarcatTests
//
//  StoreKit Pro 门控规则单测。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("EntitlementGate")
struct EntitlementGateTests {

    @Test("付费墙取消后，未订阅用户也可以使用全部能力")
    func featuresStayOpenWithoutSubscription() throws {
        let gate = makeGate(isPro: false, userID: 42)

        #expect(gate.isProUser)
        try gate.requirePro(.aiSummary)
        try gate.requirePro(.aiTags, usesLocalOnly: false)
        try gate.validateTagCreation(currentTagCount: 200)
        try gate.validateReleaseSubscription(activeSubscriptionCount: 50, isAlreadySubscribed: false)
        try gate.validateSmartCollectionCreation(currentCount: 40)
    }

    private func makeGate(
        isPro: Bool,
        userID: Int64? = nil
    ) -> EntitlementGate {
        return EntitlementGate(
            entitlementProvider: MockProEntitlementProvider(isPro: isPro),
            userIDProvider: { userID }
        )
    }
}

@MainActor
private final class MockProEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}
