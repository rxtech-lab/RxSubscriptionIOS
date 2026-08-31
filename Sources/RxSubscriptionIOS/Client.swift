import Foundation

public struct UserIdentity: Hashable, Sendable {
    public let rxlabUserID: String
    public let email: String?
    public let displayName: String?

    public init(rxlabUserID: String, email: String? = nil, displayName: String? = nil) {
        self.rxlabUserID = rxlabUserID
        self.email = email
        self.displayName = displayName
    }
}

public enum ClientError: Error, LocalizedError {
    case invalidConfiguration(String)
    case invalidURL
    case invalidResponse
    case server(statusCode: Int, payload: APIErrorPayload?, responseBody: String?)
    case storeProductNotFound(String)
    case unverifiedStoreTransaction

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .invalidURL: return "The subscription server URL is invalid."
        case .invalidResponse: return "The subscription server returned an invalid response."
        case .server(_, let payload, let body):
            return payload?.errorDescription ?? payload?.error ?? body ?? "The subscription request failed."
        case .storeProductNotFound(let id): return "App Store product not found: \(id)"
        case .unverifiedStoreTransaction: return "StoreKit could not verify the transaction on this device."
        }
    }
}

/// Application-scoped client for the RxSubscription HTTP and StoreKit APIs.
///
/// Create one client for the signed-in user and pass it directly to the package's
/// SwiftUI views. The backend API key determines sandbox versus production.
@MainActor
public final class Client {
    public let serverURL: URL
    public let apiKey: String
    public let user: UserIdentity

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        serverURL: URL,
        apiKey: String,
        rxlabUserID: String,
        email: String? = nil,
        displayName: String? = nil,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.user = UserIdentity(
            rxlabUserID: rxlabUserID,
            email: email,
            displayName: displayName
        )
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = Self.makeDecoder()
    }

    // MARK: Storefront and entitlements

    public func catalog(includeEligibility: Bool = true) async throws -> Catalog {
        try await get(
            "api/v1/catalog",
            query: includeEligibility ? [query("rxlabUserId", user.rxlabUserID)] : []
        )
    }

    public func entitlements() async throws -> Entitlements {
        try await get(
            "api/v1/entitlements",
            query: userQuery(includeProfile: true)
        )
    }

    public func balances() async throws -> [Balance] {
        let response: BalancesResponse = try await get(
            "api/v1/balances",
            query: [query("rxlabUserId", user.rxlabUserID)]
        )
        return response.balances
    }

    public func adjustBalance(
        unit: String,
        amount: Int,
        operation: BalanceOperation,
        description: String = "API adjustment",
        idempotencyKey: String,
        metadata: [String: JSONValue]? = nil
    ) async throws -> BalanceMutationResult {
        try await send(
            "POST",
            path: "api/v1/balances",
            body: BalanceMutationBody(
                rxlabUserID: user.rxlabUserID,
                unit: unit,
                amount: amount,
                operation: operation,
                description: description,
                idempotencyKey: idempotencyKey,
                metadata: metadata
            )
        )
    }

    public func ledger(
        unit: String? = nil,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> LedgerPage {
        try await get(
            "api/v1/balances/ledger",
            query: [
                query("rxlabUserId", user.rxlabUserID),
                optionalQuery("unit", unit),
                query("page", page),
                query("pageSize", pageSize),
            ].compactMap { $0 }
        )
    }

    // MARK: Balance reservations

    public func reserveBalance(
        unit: String,
        amount: Int,
        idempotencyKey: String,
        description: String = "Balance reservation",
        metadata: [String: JSONValue]? = nil,
        expiresInSeconds: Int = 1_800
    ) async throws -> BalanceReservationResult {
        try await send(
            "POST",
            path: "api/v1/balances/reserve",
            body: ReserveBalanceBody(
                rxlabUserID: user.rxlabUserID,
                unit: unit,
                amount: amount,
                idempotencyKey: idempotencyKey,
                description: description,
                metadata: metadata,
                expiresInSeconds: expiresInSeconds
            )
        )
    }

    public func reservation(id: String) async throws -> BalanceReservation {
        let response: BalanceReservationResponse = try await get(
            "api/v1/balances/reservations/\(pathComponent(id))"
        )
        return response.reservation
    }

    public func reservation(idempotencyKey: String) async throws -> BalanceReservation {
        let response: BalanceReservationResponse = try await get(
            "api/v1/balances/reservations",
            query: [query("idempotencyKey", idempotencyKey)]
        )
        return response.reservation
    }

    public func increaseReservation(
        id: String,
        amount: Int,
        idempotencyKey: String
    ) async throws -> BalanceReservationResult {
        try await send(
            "POST",
            path: "api/v1/balances/reservations/\(pathComponent(id))/increase",
            body: IncreaseReservationBody(amount: amount, idempotencyKey: idempotencyKey)
        )
    }

    public func settleReservation(
        id: String,
        amount: Int,
        idempotencyKey: String,
        final: Bool = false,
        description: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async throws -> ReservationSettlement {
        try await send(
            "POST",
            path: "api/v1/balances/reservations/\(pathComponent(id))/settle",
            body: SettleReservationBody(
                amount: amount,
                idempotencyKey: idempotencyKey,
                final: final,
                description: description,
                metadata: metadata
            )
        )
    }

    public func releaseReservation(
        id: String,
        idempotencyKey: String,
        reason: String? = nil
    ) async throws -> ReservationRelease {
        try await send(
            "POST",
            path: "api/v1/balances/reservations/\(pathComponent(id))/release",
            body: ReleaseReservationBody(idempotencyKey: idempotencyKey, reason: reason)
        )
    }

    // MARK: Usage and statistics

    public func usage() async throws -> [UsageStatus] {
        let response: UsageResponse = try await get(
            "api/v1/usage",
            query: [query("rxlabUserId", user.rxlabUserID)]
        )
        return response.usage
    }

    /// Records a metered event. A 402 response is decoded as a normal result with `allowed == false`.
    public func recordUsage(
        item: String,
        amount: Int = 1,
        idempotencyKey: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) async throws -> UsageRecordResult {
        try await send(
            "POST",
            path: "api/v1/usage",
            body: RecordUsageBody(
                rxlabUserID: user.rxlabUserID,
                item: item,
                amount: amount,
                idempotencyKey: idempotencyKey,
                metadata: metadata
            ),
            acceptedStatusCodes: Set(200...299).union([402])
        )
    }

    public func usageStatistics(
        from: Date,
        to: Date,
        granularity: SeriesGranularity = .day,
        item: String? = nil,
        groupByItem: Bool = false,
        forCurrentUser: Bool = true
    ) async throws -> UsageSeries {
        try await get(
            "api/v1/usage/statistics",
            query: seriesQuery(from: from, to: to, granularity: granularity) + [
                optionalQuery("rxlabUserId", forCurrentUser ? user.rxlabUserID : nil),
                optionalQuery("item", item),
                optionalQuery("groupBy", groupByItem ? "item" : nil),
            ].compactMap { $0 }
        )
    }

    public func consumptionStatistics(
        from: Date,
        to: Date,
        granularity: SeriesGranularity = .day,
        unit: String? = nil,
        groupBy: ConsumptionGrouping? = nil,
        forCurrentUser: Bool = true
    ) async throws -> ConsumptionSeries {
        try await get(
            "api/v1/balances/consumption",
            query: seriesQuery(from: from, to: to, granularity: granularity) + [
                optionalQuery("rxlabUserId", forCurrentUser ? user.rxlabUserID : nil),
                optionalQuery("unit", unit),
                optionalQuery("groupBy", groupBy?.rawValue),
            ].compactMap { $0 }
        )
    }

    // MARK: Stripe checkout, coupons, and history

    public func checkoutPlan(
        id: String,
        couponCode: String? = nil,
        successURL: URL? = nil,
        cancelURL: URL? = nil
    ) async throws -> CheckoutSession {
        try await checkout(
            kind: .plan,
            planID: id,
            couponCode: couponCode,
            successURL: successURL,
            cancelURL: cancelURL
        )
    }

    public func checkoutTopUp(
        id: String,
        couponCode: String? = nil,
        successURL: URL? = nil,
        cancelURL: URL? = nil
    ) async throws -> CheckoutSession {
        try await checkout(
            kind: .topup,
            topupID: id,
            couponCode: couponCode,
            successURL: successURL,
            cancelURL: cancelURL
        )
    }

    public func billingPortal(returnURL: URL? = nil) async throws -> BillingPortalSession {
        try await send(
            "POST",
            path: "api/v1/checkout",
            body: CheckoutBody(
                user: user,
                kind: .portal,
                planID: nil,
                topupID: nil,
                couponCode: nil,
                successURL: nil,
                cancelURL: nil,
                returnURL: returnURL
            )
        )
    }

    public func validateCoupon(
        code: String,
        planID: String? = nil,
        topupID: String? = nil
    ) async throws -> CouponValidation {
        try await send(
            "POST",
            path: "api/v1/coupons/validate",
            body: CouponBody(
                user: user,
                code: code,
                planID: planID,
                topupID: topupID
            )
        )
    }

    public func purchases(page: Int = 1, pageSize: Int = 20) async throws -> PurchasePage {
        try await get(
            "api/v1/purchases",
            query: [
                query("rxlabUserId", user.rxlabUserID),
                query("page", page),
                query("pageSize", pageSize),
            ].compactMap { $0 }
        )
    }

    public func invoices(after: String? = nil, before: String? = nil) async throws -> InvoicePage {
        try await get(
            "api/v1/invoices",
            query: [
                query("rxlabUserId", user.rxlabUserID),
                optionalQuery("after", after),
                optionalQuery("before", before),
            ].compactMap { $0 }
        )
    }

    // MARK: App Store server bridge

    public func appleAccountToken() async throws -> AppleAccountToken {
        try await send(
            "POST",
            path: "api/v1/iap/apple/account-token",
            body: AppleUserBody(rxlabUserID: user.rxlabUserID)
        )
    }

    public func setAppleConsumptionConsent(_ consented: Bool) async throws -> ConsumptionConsent {
        try await send(
            "PUT",
            path: "api/v1/iap/apple/consumption-consent",
            body: AppleConsentBody(rxlabUserID: user.rxlabUserID, consented: consented)
        )
    }

    public func submitAppleTransaction(_ signedTransaction: String) async throws -> AppleFulfillment {
        try await send(
            "POST",
            path: "api/v1/iap/apple/transactions",
            body: AppleTransactionBody(
                rxlabUserID: user.rxlabUserID,
                signedTransaction: signedTransaction
            )
        )
    }

    // MARK: Transport

    private func checkout(
        kind: CheckoutKind,
        planID: String? = nil,
        topupID: String? = nil,
        couponCode: String? = nil,
        successURL: URL? = nil,
        cancelURL: URL? = nil
    ) async throws -> CheckoutSession {
        try await send(
            "POST",
            path: "api/v1/checkout",
            body: CheckoutBody(
                user: user,
                kind: kind,
                planID: planID,
                topupID: topupID,
                couponCode: couponCode,
                successURL: successURL,
                cancelURL: cancelURL,
                returnURL: nil
            )
        )
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await request(method: "GET", path: path, query: query, body: nil)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ method: String,
        path: String,
        body: Body,
        acceptedStatusCodes: Set<Int> = Set(200...299)
    ) async throws -> Response {
        try await request(
            method: method,
            path: path,
            query: [],
            body: try encoder.encode(body),
            acceptedStatusCodes: acceptedStatusCodes
        )
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        acceptedStatusCodes: Set<Int> = Set(200...299)
    ) async throws -> Response {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.invalidConfiguration("apiKey must not be empty.")
        }
        guard !user.rxlabUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.invalidConfiguration("rxlabUserID must not be empty.")
        }
        guard var components = URLComponents(
            url: url(for: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ClientError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            throw ClientError.server(
                statusCode: http.statusCode,
                payload: try? decoder.decode(APIErrorPayload.self, from: data),
                responseBody: String(data: data, encoding: .utf8)
            )
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func url(for path: String) -> URL {
        path.split(separator: "/").reduce(serverURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func userQuery(includeProfile: Bool) -> [URLQueryItem] {
        [
            query("rxlabUserId", user.rxlabUserID),
            optionalQuery("email", includeProfile ? user.email : nil),
        ].compactMap { $0 }
    }

    private func seriesQuery(
        from: Date,
        to: Date,
        granularity: SeriesGranularity
    ) -> [URLQueryItem] {
        [
            query("from", Self.apiDateFormatter.string(from: from)),
            query("to", Self.apiDateFormatter.string(from: to)),
            query("granularity", granularity.rawValue),
        ].compactMap { $0 }
    }

    private func query(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    private func optionalQuery(_ name: String, _ value: String?) -> URLQueryItem? {
        value.map { URLQueryItem(name: name, value: $0) }
    }

    private func query(_ name: String, _ value: Int) -> URLQueryItem {
        URLQueryItem(name: name, value: String(value))
    }

    private static let apiDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseAPIDate(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        return decoder
    }

    nonisolated private static func parseAPIDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

// MARK: - Wire request bodies

private struct BalanceMutationBody: Encodable {
    let rxlabUserID: String
    let unit: String
    let amount: Int
    let operation: BalanceOperation
    let description: String
    let idempotencyKey: String
    let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case unit, amount, operation, description, idempotencyKey, metadata
        case rxlabUserID = "rxlabUserId"
    }
}

private struct ReserveBalanceBody: Encodable {
    let rxlabUserID: String
    let unit: String
    let amount: Int
    let idempotencyKey: String
    let description: String
    let metadata: [String: JSONValue]?
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case unit, amount, idempotencyKey, description, metadata, expiresInSeconds
        case rxlabUserID = "rxlabUserId"
    }
}

private struct IncreaseReservationBody: Encodable {
    let amount: Int
    let idempotencyKey: String
}

private struct SettleReservationBody: Encodable {
    let amount: Int
    let idempotencyKey: String
    let final: Bool
    let description: String?
    let metadata: [String: JSONValue]?
}

private struct ReleaseReservationBody: Encodable {
    let idempotencyKey: String
    let reason: String?
}

private struct RecordUsageBody: Encodable {
    let rxlabUserID: String
    let item: String
    let amount: Int
    let idempotencyKey: String?
    let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case item, amount, idempotencyKey, metadata
        case rxlabUserID = "rxlabUserId"
    }
}

private struct CheckoutBody: Encodable {
    let rxlabUserID: String
    let email: String?
    let displayName: String?
    let kind: CheckoutKind
    let planID: String?
    let topupID: String?
    let couponCode: String?
    let successURL: URL?
    let cancelURL: URL?
    let returnURL: URL?

    init(
        user: UserIdentity,
        kind: CheckoutKind,
        planID: String?,
        topupID: String?,
        couponCode: String?,
        successURL: URL?,
        cancelURL: URL?,
        returnURL: URL?
    ) {
        rxlabUserID = user.rxlabUserID
        email = user.email
        displayName = user.displayName
        self.kind = kind
        self.planID = planID
        self.topupID = topupID
        self.couponCode = couponCode
        self.successURL = successURL
        self.cancelURL = cancelURL
        self.returnURL = returnURL
    }

    enum CodingKeys: String, CodingKey {
        case email, displayName, kind, couponCode
        case rxlabUserID = "rxlabUserId"
        case planID = "planId"
        case topupID = "topupId"
        case successURL = "successUrl"
        case cancelURL = "cancelUrl"
        case returnURL = "returnUrl"
    }
}

private struct CouponBody: Encodable {
    let rxlabUserID: String
    let email: String?
    let displayName: String?
    let code: String
    let planID: String?
    let topupID: String?

    init(user: UserIdentity, code: String, planID: String?, topupID: String?) {
        rxlabUserID = user.rxlabUserID
        email = user.email
        displayName = user.displayName
        self.code = code
        self.planID = planID
        self.topupID = topupID
    }

    enum CodingKeys: String, CodingKey {
        case email, displayName, code
        case rxlabUserID = "rxlabUserId"
        case planID = "planId"
        case topupID = "topupId"
    }
}

private struct AppleUserBody: Encodable {
    let rxlabUserID: String
    enum CodingKeys: String, CodingKey { case rxlabUserID = "rxlabUserId" }
}

private struct AppleConsentBody: Encodable {
    let rxlabUserID: String
    let consented: Bool
    enum CodingKeys: String, CodingKey {
        case consented
        case rxlabUserID = "rxlabUserId"
    }
}

private struct AppleTransactionBody: Encodable {
    let rxlabUserID: String
    let signedTransaction: String
    enum CodingKeys: String, CodingKey {
        case signedTransaction
        case rxlabUserID = "rxlabUserId"
    }
}
