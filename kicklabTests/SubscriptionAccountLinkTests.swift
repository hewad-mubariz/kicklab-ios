import XCTest
import StoreKit
@testable import kicklab

@MainActor
final class SubscriptionAccountLinkTests: XCTestCase {
    func testGuestPurchaseLinksAfterSignInWithoutAnotherPurchase() async {
        let service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service)
        await link.refresh(signedTransaction: "verified-guest-purchase")
        XCTAssertEqual(service.calls.count, 0)
        let id = UUID(); link.useAccount(id)
        service.reply = reply(id, plan: .monthly)
        await link.refresh(signedTransaction: "verified-guest-purchase")
        XCTAssertEqual(service.calls.first?.0, id)
        XCTAssertEqual(service.calls.first?.1, "verified-guest-purchase")
        XCTAssertEqual(link.plan, .monthly)
    }

    func testNewPhoneRecoversThroughAccountWithoutLocalPurchase() async {
        let id = UUID(), service = AccountSubscriptionStub()
        service.reply = reply(id, plan: .yearly)
        let fresh = SubscriptionAccountLink(service: service)
        fresh.useAccount(id)
        await fresh.refresh(signedTransaction: nil)
        XCTAssertNil(service.calls.first?.1)
        XCTAssertEqual(fresh.plan, .yearly)
        fresh.useAccount(nil)
        XCTAssertNil(fresh.plan)
    }

    func testRefundRemovesPreviouslyLinkedAccess() async {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        service.reply = reply(id, plan: .monthly)
        await link.refresh(signedTransaction: nil)
        XCTAssertEqual(link.plan, .monthly)
        service.reply = reply(id, plan: nil)
        await link.refresh(signedTransaction: nil)
        XCTAssertNil(link.plan)
    }

    func testAccountSwitchDiscardsLateReplyAndPreviousAccess() async {
        let old = UUID(), new = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(old)
        service.delayed = true
        let pending = Task { await link.refresh(signedTransaction: nil) }
        while service.continuation == nil { await Task.yield() }
        link.useAccount(new)
        service.continuation?.resume(returning: reply(old, plan: .yearly))
        await pending.value
        XCTAssertNil(link.plan)
        XCTAssertEqual(link.userID, new)
    }

    func testWrongOwnerAndExpiredLeaseNeverGrantAccess() async {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        service.reply = reply(UUID(), plan: .monthly)
        await link.refresh(signedTransaction: nil)
        XCTAssertNil(link.plan)
        service.reply = reply(id, plan: .monthly, duration: -1)
        await link.refresh(signedTransaction: nil)
        XCTAssertNil(link.plan)
        service.reply = reply(id, plan: .monthly, duration: 24 * 3600)
        await link.refresh(signedTransaction: nil)
        XCTAssertNil(link.plan)
    }

    func testLeaseExpiresWithoutReopeningApp() async throws {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        service.reply = reply(id, plan: .monthly, duration: 0.1)
        await link.refresh(signedTransaction: nil)
        XCTAssertEqual(link.plan, .monthly)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(link.plan)
    }

    func testUnavailableBackendNeverInventsAccess() async {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        await link.refresh(signedTransaction: nil)
        XCTAssertNil(link.plan)
        XCTAssertNotNil(link.message)
    }

    func testOwnershipConflictIsExplained() async {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        service.reply = SubscriptionAccountReply(userID: id, productID: nil, validUntilMS: nil,
                                                environment: nil, link: "another_account")
        await link.refresh(signedTransaction: "already-linked")
        XCTAssertNil(link.plan)
        XCTAssertTrue(link.message?.contains("another Juggle Dude account") == true)
    }

    func testTransientSignInFailureRecoversWithoutRelaunch() async {
        let id = UUID(), service = AccountSubscriptionStub()
        service.transientFailures = 1; service.reply = reply(id, plan: .monthly)
        let link = SubscriptionAccountLink(service: service, retryDelays: [.zero, .zero])
        link.useAccount(id)
        await link.refresh(signedTransaction: "guest-proof", purchaseEnvironment: .sandbox)
        XCTAssertEqual(service.calls.count, 2)
        XCTAssertEqual(link.plan, .monthly)
        XCTAssertNil(link.message)
        XCTAssertFalse(link.isChecking)
    }

    func testTransientRetryIsBoundedAndManualRetryClearsWarning() async {
        let id = UUID(), service = AccountSubscriptionStub()
        service.transientFailures = 5
        let link = SubscriptionAccountLink(service: service, retryDelays: [.zero, .zero])
        link.useAccount(id)
        await link.refresh(signedTransaction: "proof")
        XCTAssertEqual(service.calls.count, 3)
        XCTAssertNil(link.plan)
        XCTAssertNotNil(link.message)
        service.transientFailures = 0; service.reply = reply(id, plan: .monthly)
        service.delayed = true
        let retry = Task { await link.refresh(signedTransaction: "proof") }
        while service.continuation == nil { await Task.yield() }
        XCTAssertTrue(link.isChecking)
        XCTAssertNil(link.message)
        service.continuation?.resume(returning: reply(id, plan: .monthly))
        await retry.value
        XCTAssertEqual(link.plan, .monthly)
        XCTAssertFalse(link.isChecking)
        XCTAssertNil(link.message)
    }

    func testRepeatedRefreshJoinsSameInFlightRequest() async {
        let id = UUID(), service = AccountSubscriptionStub()
        let link = SubscriptionAccountLink(service: service); link.useAccount(id)
        service.delayed = true
        let first = Task { await link.refresh(signedTransaction: "proof", purchaseEnvironment: .sandbox) }
        while service.continuation == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await link.refresh(signedTransaction: "proof", purchaseEnvironment: .sandbox)
        }
        while !secondStarted { await Task.yield() }
        service.continuation?.resume(returning: reply(id, plan: .monthly))
        await first.value; await second.value
        XCTAssertEqual(service.calls.count, 1)
        XCTAssertEqual(link.plan, .monthly)
    }

    func testSignOutDuringRetryCancelsRecovery() async throws {
        let id = UUID(), service = AccountSubscriptionStub()
        service.transientFailures = 1; service.reply = reply(id, plan: .monthly)
        let link = SubscriptionAccountLink(service: service, retryDelays: [.seconds(60)])
        link.useAccount(id)
        let pending = Task { await link.refresh(signedTransaction: "proof") }
        while service.calls.isEmpty { await Task.yield() }
        link.useAccount(nil)
        await pending.value
        XCTAssertEqual(service.calls.count, 1)
        XCTAssertNil(link.plan)
        XCTAssertNil(link.message)
        XCTAssertFalse(link.isChecking)
    }

    private func reply(_ id: UUID, plan: ProPlan?, duration: TimeInterval = 3600) -> SubscriptionAccountReply {
        SubscriptionAccountReply(userID: id, productID: plan?.productID,
            validUntilMS: plan == nil ? nil : Date().addingTimeInterval(duration).timeIntervalSince1970 * 1000,
            environment: plan == nil ? nil : "Production", link: "linked")
    }
}

@MainActor
private final class AccountSubscriptionStub: SubscriptionAccountService {
    var calls: [(UUID, String?)] = []
    var reply: SubscriptionAccountReply?
    var delayed = false
    var transientFailures = 0
    var continuation: CheckedContinuation<SubscriptionAccountReply, Never>?
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        calls.append((userID, signedTransaction))
        if transientFailures > 0 {
            transientFailures -= 1
            throw SubscriptionAccountError.temporarilyUnavailable
        }
        if delayed { return await withCheckedContinuation { continuation = $0 } }
        guard let reply else { throw SubscriptionAccountError.unavailable }
        return reply
    }
}
