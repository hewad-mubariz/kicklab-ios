import Combine
import Foundation
import StoreKit

struct SubscriptionAccountReply: Decodable, Sendable {
    let userID: UUID
    let productID: String?
    let validUntilMS: Double?
    let environment: String?
    let link: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", productID = "product_id", validUntilMS = "valid_until_ms"
        case environment, link
    }
}

@MainActor
protocol SubscriptionAccountService {
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply
}

@MainActor
final class SupabaseSubscriptionService: SubscriptionAccountService {
    private let config: AccountConfiguration
    private let session: URLSession
    private let token: (UUID) async throws -> String
    private let appEnvironment: () async throws -> AppStore.Environment
    init(config: AccountConfiguration, session: URLSession = .shared,
         appEnvironment: @escaping () async throws -> AppStore.Environment = {
             do {
                 guard case .verified(let app) = try await AppTransaction.shared else {
                     throw SubscriptionAccountError.unavailable
                 }
                 return app.environment
             } catch let error as SubscriptionAccountError { throw error }
             catch is CancellationError { throw CancellationError() }
             catch { throw SubscriptionAccountError.temporarilyUnavailable }
         },
         token: @escaping (UUID) async throws -> String) {
        self.config = config; self.session = session; self.token = token
        self.appEnvironment = appEnvironment
    }

    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        // The environment travels with the already-verified purchase proof. Linking
        // that purchase must not depend on a second, possibly unavailable app receipt.
        // Without a purchase, account recovery still requires a verified app receipt.
        let verifiedEnvironment: AppStore.Environment
        if signedTransaction != nil, let purchaseEnvironment {
            verifiedEnvironment = purchaseEnvironment
        } else {
            verifiedEnvironment = try await appEnvironment()
        }
        let environment: String
        switch verifiedEnvironment {
        case .production: environment = "Production"
        case .sandbox: environment = "Sandbox"
        default: throw SubscriptionAccountError.localTestingOnly // Local Xcode test receipts stay local.
        }
        let auth = try await token(userID)
        try Task.checkCancellation()
        var request = URLRequest(url: config.projectURL.appendingPathComponent("functions/v1/subscription-account"),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = signedTransaction == nil ? "GET" : "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(environment, forHTTPHeaderField: "X-Store-Environment")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let signedTransaction {
            request.httpBody = try JSONEncoder().encode(["signed_transaction": signedTransaction])
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SubscriptionAccountError.temporarilyUnavailable
        }
        if response.statusCode == 429 || (500...599).contains(response.statusCode) {
            throw SubscriptionAccountError.temporarilyUnavailable
        }
        guard response.statusCode == 200 else {
            throw SubscriptionAccountError.unavailable
        }
        let reply = try JSONDecoder().decode(SubscriptionAccountReply.self, from: data)
        guard reply.userID == userID, reply.environment == nil || reply.environment == environment else {
            throw SubscriptionAccountError.unavailable
        }
        return reply
    }
}

enum SubscriptionAccountError: Error {
    case unavailable, temporarilyUnavailable
    /// Xcode's local StoreKit environment has no server-side counterpart. Not a failure.
    case localTestingOnly
}

/// Account access is isolated from local StoreKit access. Never persist a naked Pro
/// flag; a new launch verifies again. A bounded lease permits brief offline use.
@MainActor
final class SubscriptionAccountLink: ObservableObject {
    @Published private(set) var plan: ProPlan?
    @Published private(set) var message: String?
    @Published private(set) var isChecking = false
    /// The purchase belongs to a different, existing account. Retrying cannot change that.
    @Published private(set) var linkedElsewhere = false
    private(set) var userID: UUID?
    private let service: (any SubscriptionAccountService)?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var validUntil: Date?
    private var workProof: String?
    private var workEnvironment: AppStore.Environment?
    private let retryDelays: [Duration]
    init(service: (any SubscriptionAccountService)? = nil,
         retryDelays: [Duration] = [.seconds(1), .seconds(3)]) {
        self.service = service; self.retryDelays = retryDelays
    }
    deinit { work?.cancel(); expiry?.cancel() }

    func useAccount(_ id: UUID?) {
        guard id != userID else { return }
        generation = UUID(); work?.cancel(); expiry?.cancel()
        work = nil; workProof = nil; workEnvironment = nil
        userID = id; plan = nil; validUntil = nil; message = nil; isChecking = false; linkedElsewhere = false
    }

    func refresh(signedTransaction: String?, purchaseEnvironment: AppStore.Environment? = nil) async {
        guard let service, let owner = userID else { return }
        if let work, workProof == signedTransaction, workEnvironment == purchaseEnvironment {
            await work.value
            return
        }
        generation = UUID()
        let current = generation
        work?.cancel()
        workProof = signedTransaction; workEnvironment = purchaseEnvironment
        isChecking = true
        message = nil; linkedElsewhere = false
        if let validUntil, validUntil <= Date() { clearAccess() }
        let task = Task { [weak self] in
            defer {
                if let self, self.generation == current {
                    self.isChecking = false; self.work = nil
                    self.workProof = nil; self.workEnvironment = nil
                }
            }
            do {
                let delays = self?.retryDelays ?? []
                var attempt = 0
                let reply: SubscriptionAccountReply
                while true {
                    try Task.checkCancellation()
                    do {
                        reply = try await service.sync(userID: owner, signedTransaction: signedTransaction,
                                                       purchaseEnvironment: purchaseEnvironment)
                        break
                    } catch {
                        guard Self.canRetry(error), attempt < delays.count else { throw error }
                        try await Task.sleep(for: delays[attempt])
                        attempt += 1
                    }
                }
                guard let self, !Task.isCancelled, self.generation == current, self.userID == owner else { return }
                guard reply.userID == owner else { throw SubscriptionAccountError.unavailable }
                self.clearAccess()
                if let id = reply.productID, let plan = ProPlan(productID: id),
                   let ms = reply.validUntilMS, ms.isFinite {
                    let end = Date(timeIntervalSince1970: ms / 1000)
                    guard end > Date(), end.timeIntervalSinceNow <= 6 * 3600 + 60 else {
                        throw SubscriptionAccountError.unavailable
                    }
                    self.plan = plan; self.validUntil = end
                    self.expiry = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
                        guard !Task.isCancelled, let self, self.userID == owner, self.validUntil == end else { return }
                        self.clearAccess()
                    }
                } else if reply.productID != nil { throw SubscriptionAccountError.unavailable }
                self.linkedElsewhere = reply.link == "another_account"
                self.message = reply.link == "another_account"
                    ? String(localized: "This Apple purchase is linked to another Juggle Dude account. Sign in to that account for account recovery.")
                    : nil
            } catch SubscriptionAccountError.localTestingOnly {
                // Nothing to sync in local StoreKit testing; never show an unfixable error.
                guard let self, !Task.isCancelled, self.generation == current, self.userID == owner else { return }
                self.clearAccess(); self.message = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == current, self.userID == owner else { return }
                if self.validUntil.map({ $0 <= Date() }) ?? true { self.clearAccess() }
                self.message = String(localized: "Couldn’t sync Pro with your account. Please try again.")
            }
        }
        work = task
        await task.value
    }

    private static func canRetry(_ error: Error) -> Bool {
        if case SubscriptionAccountError.temporarilyUnavailable = error { return true }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    private func clearAccess() {
        expiry?.cancel(); expiry = nil; plan = nil; validUntil = nil
    }
}
