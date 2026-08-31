import Foundation

// MARK: - Common values

/// A Codable representation of arbitrary JSON used by metadata fields.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum BillingProvider: String, Codable, CaseIterable, Sendable {
    case stripe
    case appleAppStore = "apple_app_store"
    /// Reserved by the backend contract. No Google purchase transport is exposed yet.
    case googlePlay = "google_play"
}

public enum PurchaseFlow: String, Codable, Sendable {
    case checkout
    case storeKit = "storekit"
}

public enum StoreProductType: String, Codable, Sendable {
    case autoRenewableSubscription = "auto_renewable_subscription"
    case nonConsumable = "non_consumable"
    case consumable
}

public struct APIErrorPayload: Codable, Hashable, Sendable {
    public let error: String
    public let errorDescription: String?
    public let available: Int?
    public let required: Int?
    public let status: String?
    public let blockers: [JSONValue]?
    public let blockedBy: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case available, required, status, blockers, blockedBy
    }
}

// MARK: - Catalog

public struct PurchaseOption: Codable, Hashable, Sendable, Identifiable {
    public let provider: BillingProvider
    public let flow: PurchaseFlow
    public let productID: String?
    public let productType: StoreProductType?

    public var id: String {
        [provider.rawValue, flow.rawValue, productID ?? "default"].joined(separator: ":")
    }

    enum CodingKeys: String, CodingKey {
        case provider, flow
        case productID = "productId"
        case productType
    }
}

public struct SubscriptionPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let description: String?
    public let planGroup: String
    public let billingInterval: String
    public let intervalCount: Int
    public let priceAmountCents: Int
    public let currency: String
    public let trialDays: Int
    public let purchaseOptions: [PurchaseOption]
}

public struct TopUpEligibilityBlocker: Codable, Hashable, Sendable {
    public let ruleType: String
    public let planID: String?
    public let roleID: String?

    enum CodingKeys: String, CodingKey {
        case ruleType
        case planID = "planId"
        case roleID = "roleId"
    }
}

public struct TopUpProduct: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let description: String?
    public let unit: String?
    public let amount: Int
    public let priceAmountCents: Int
    public let currency: String
    public let eligible: Bool?
    public let blockedBy: [TopUpEligibilityBlocker]?
    public let purchaseOptions: [PurchaseOption]
}

public struct Catalog: Codable, Hashable, Sendable {
    public let plans: [SubscriptionPlan]
    public let topups: [TopUpProduct]
}

// MARK: - Entitlements, balances, and usage

public struct SubscriptionUser: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let rxlabUserID: String
    public let level: Int
    public let levelKey: String?

    enum CodingKeys: String, CodingKey {
        case id, level, levelKey
        case rxlabUserID = "rxlabUserId"
    }
}

public struct EntitledPlan: Codable, Hashable, Sendable, Identifiable {
    public let subscriptionID: String?
    public let purchaseID: String?
    public let planID: String
    public let planKey: String
    public let planName: String
    public let planGroup: String
    public let status: String
    public let currentPeriodStart: Date?
    public let currentPeriodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    public let billingProvider: BillingProvider
    public let providerProductID: String?

    public var id: String { subscriptionID ?? purchaseID ?? planID }

    enum CodingKeys: String, CodingKey {
        case status, planKey, planName, planGroup, currentPeriodStart, currentPeriodEnd
        case cancelAtPeriodEnd, billingProvider
        case subscriptionID = "subscriptionId"
        case purchaseID = "purchaseId"
        case planID = "planId"
        case providerProductID = "providerProductId"
    }
}

public struct Balance: Codable, Hashable, Sendable, Identifiable {
    public let unit: String
    public let name: String
    public let symbol: String?
    public let precision: Int
    public let amount: Int
    public let available: Int

    public var id: String { unit }
}

public struct UsageStatus: Codable, Hashable, Sendable, Identifiable {
    public let itemID: String?
    public let key: String
    public let name: String
    public let used: Int
    public let limit: Int?
    public let remaining: Int?
    public let periodStart: Date?
    public let periodEnd: Date?
    public let resetsAt: Date?
    public let resetPolicy: String
    public let overagePolicy: String?

    public var id: String { itemID ?? key }

    enum CodingKeys: String, CodingKey {
        case key, name, used, limit, remaining, periodStart, periodEnd, resetsAt
        case resetPolicy, overagePolicy
        case itemID = "itemId"
    }
}

public struct Entitlements: Codable, Hashable, Sendable {
    public let user: SubscriptionUser
    public let plans: [EntitledPlan]
    public let roles: [String]
    public let permissions: [String]
    public let features: [String: String?]
    public let balances: [Balance]
    public let usage: [UsageStatus]
}

public struct BalancesResponse: Codable, Hashable, Sendable {
    public let balances: [Balance]
}

public enum BalanceOperation: String, Codable, Sendable {
    case credit
    case debit
}

public struct BalanceMutationResult: Codable, Hashable, Sendable {
    public let entryID: String
    public let duplicate: Bool
    public let balanceAfter: Int

    enum CodingKeys: String, CodingKey {
        case duplicate, balanceAfter
        case entryID = "entryId"
    }
}

public struct LedgerEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let unit: String
    public let delta: Int
    public let balanceAfter: Int
    public let description: String
    public let referenceType: String?
    public let referenceID: String?
    public let createdAt: Date
    public let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, kind, unit, delta, balanceAfter, description, referenceType, createdAt, metadata
        case referenceID = "referenceId"
    }
}

public struct LedgerPage: Codable, Hashable, Sendable {
    public let entries: [LedgerEntry]
    public let total: Int
    public let page: Int
    public let pageSize: Int
    public let pageCount: Int
}

public struct UsageResponse: Codable, Hashable, Sendable {
    public let usage: [UsageStatus]
}

public struct UsageRecordResult: Codable, Hashable, Sendable {
    public let allowed: Bool
    public let reason: String?
    public let used: Int
    public let limit: Int?
    public let remaining: Int?
    public let chargedUnits: Int
    public let periodEnd: Date?
    public let duplicate: Bool
}

// MARK: - Time series

public enum SeriesGranularity: String, Codable, CaseIterable, Sendable {
    case minute, hour, day, week, month
}

public enum ConsumptionGrouping: String, Codable, Sendable {
    case kind
    case description
}

public struct ConsumptionBucket: Codable, Hashable, Sendable, Identifiable {
    public let start: Date
    public let spent: Int
    public let granted: Int
    public let net: Int
    public let entryCount: Int

    public var id: Date { start }
}

public struct ConsumptionGroup: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let spent: Int
    public let granted: Int
    public let net: Int
    public let entryCount: Int
    public let buckets: [ConsumptionBucket]

    public var id: String { key }
}

public struct BalanceUnitSummary: Codable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let symbol: String?
    public let precision: Int
}

public struct ConsumptionSeries: Codable, Hashable, Sendable {
    public let from: Date
    public let to: Date
    public let granularity: SeriesGranularity
    public let totals: [ConsumptionBucket]
    public let groups: [ConsumptionGroup]?
    public let unit: BalanceUnitSummary?
}

public struct UsageBucket: Codable, Hashable, Sendable, Identifiable {
    public let start: Date
    public let amount: Int
    public let consumed: Int
    public let eventCount: Int
    public let chargedUnits: Int

    public var id: Date { start }
}

public struct UsageGroup: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let amount: Int
    public let consumed: Int
    public let eventCount: Int
    public let chargedUnits: Int
    public let buckets: [UsageBucket]

    public var id: String { key }
}

public struct UsageSeries: Codable, Hashable, Sendable {
    public let from: Date
    public let to: Date
    public let granularity: SeriesGranularity
    public let totals: [UsageBucket]
    public let groups: [UsageGroup]?
}

// MARK: - Reservations

public struct BalanceReservationResult: Codable, Hashable, Sendable {
    public let reservationID: String
    public let amount: Int
    public let available: Int
    public let expiresAt: Date
    public let status: String?
    public let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case amount, available, expiresAt, status, duplicate
        case reservationID = "reservationId"
    }
}

public struct BalanceReservation: Codable, Hashable, Sendable, Identifiable {
    public let reservationID: String
    public let rxlabUserID: String
    public let unit: String
    public let initialAmount: Int
    public let remainingReserved: Int
    public let status: String
    public let description: String
    public let metadata: [String: JSONValue]?
    public let requestedAmount: Int
    public let settledAmount: Int
    public let shortfallAmount: Int
    public let releasedAmount: Int
    public let available: Int
    public let balanceAfter: Int?
    public let expiresAt: Date
    public let releaseReason: String?
    public let entryID: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?

    public var id: String { reservationID }

    enum CodingKeys: String, CodingKey {
        case unit, initialAmount, remainingReserved, status, description, metadata
        case requestedAmount, settledAmount, shortfallAmount, releasedAmount, available
        case balanceAfter, expiresAt, releaseReason, createdAt, updatedAt, closedAt
        case reservationID = "reservationId"
        case rxlabUserID = "rxlabUserId"
        case entryID = "entryId"
    }
}

public struct BalanceReservationResponse: Codable, Hashable, Sendable {
    public let reservation: BalanceReservation
}

public struct ReservationSettlement: Codable, Hashable, Sendable {
    public let reservationID: String
    public let entryID: String
    public let operationRequestedAmount: Int
    public let operationSettledAmount: Int
    public let operationShortfallAmount: Int
    public let requestedAmount: Int
    public let settledAmount: Int
    public let shortfallAmount: Int
    public let remainingReserved: Int
    public let balanceAfter: Int
    public let status: String
    public let expiresAt: Date?
    public let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case operationRequestedAmount, operationSettledAmount, operationShortfallAmount
        case requestedAmount, settledAmount, shortfallAmount, remainingReserved
        case balanceAfter, status, expiresAt, duplicate
        case reservationID = "reservationId"
        case entryID = "entryId"
    }
}

public struct ReservationRelease: Codable, Hashable, Sendable {
    public let reservationID: String
    public let released: Bool
    public let releasedAmount: Int
    public let remainingReserved: Int
    public let balanceAfter: Int
    public let status: String
    public let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case released, releasedAmount, remainingReserved, balanceAfter, status, duplicate
        case reservationID = "reservationId"
    }
}

// MARK: - Checkout and history

public enum CheckoutKind: String, Codable, Sendable {
    case plan
    case topup
    case portal
}

public struct CheckoutDiscount: Codable, Hashable, Sendable {
    public let code: String
    public let discountCents: Int
}

public struct CheckoutSession: Codable, Hashable, Sendable {
    public let checkoutURL: URL
    public let sessionID: String
    public let purchaseID: String?
    public let discount: CheckoutDiscount?
    public let promotionCodesEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case discount, promotionCodesEnabled
        case checkoutURL = "checkoutUrl"
        case sessionID = "sessionId"
        case purchaseID = "purchaseId"
    }
}

public struct BillingPortalSession: Codable, Hashable, Sendable {
    public let url: URL
}

public struct CouponValidation: Codable, Hashable, Sendable {
    public let valid: Bool
    public let code: String?
    public let name: String?
    public let description: String?
    public let terms: String?
    public let duration: String?
    public let durationInMonths: Int?
    public let discountCents: Int?
    public let totalCents: Int?
    public let currency: String?
    public let capped: Bool?
    public let reason: String?
    public let blockers: [String]
}

public struct PurchaseRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let applicationID: String?
    public let appUserID: String?
    public let kind: String
    public let planID: String?
    public let topupProductID: String?
    public let unitID: String?
    public let unit: String?
    public let unitsGranted: Int
    public let amountCents: Int
    public let currency: String
    public let status: String
    public let billingProvider: BillingProvider
    public let providerTransactionID: String?
    public let providerOriginalTransactionID: String?
    public let providerProductID: String?
    public let quantity: Int
    public let priceMilliunits: Int?
    public let entitlementSnapshot: [String: JSONValue]?
    public let fulfillmentFailureCode: String?
    public let stripeCheckoutSessionID: String?
    public let stripePaymentIntentID: String?
    public let stripeInvoiceID: String?
    public let hostedInvoiceURL: URL?
    public let invoicePDFURL: URL?
    public let refundedAmountCents: Int?
    public let reversedUnits: Int?
    public let createdAt: Date
    public let updatedAt: Date?
    public let paidAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, unit, unitsGranted, amountCents, currency, status, billingProvider
        case quantity, priceMilliunits, entitlementSnapshot, fulfillmentFailureCode
        case refundedAmountCents, reversedUnits, createdAt, updatedAt, paidAt
        case applicationID = "applicationId"
        case appUserID = "appUserId"
        case planID = "planId"
        case topupProductID = "topupProductId"
        case unitID = "unitId"
        case providerTransactionID = "providerTransactionId"
        case providerOriginalTransactionID = "providerOriginalTransactionId"
        case providerProductID = "providerProductId"
        case stripeCheckoutSessionID = "stripeCheckoutSessionId"
        case stripePaymentIntentID = "stripePaymentIntentId"
        case stripeInvoiceID = "stripeInvoiceId"
        case hostedInvoiceURL = "hostedInvoiceUrl"
        case invoicePDFURL = "invoicePdfUrl"
    }
}

public struct PurchasePage: Codable, Hashable, Sendable {
    public let purchases: [PurchaseRecord]
    public let total: Int
    public let page: Int
    public let pageSize: Int
    public let pageCount: Int
}

public struct Invoice: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let number: String?
    public let description: String
    public let status: String
    public let amountCents: Int
    public let currency: String
    public let createdAt: Date
    public let hostedInvoiceURL: URL?
    public let invoicePDFURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, number, description, status, amountCents, currency, createdAt
        case hostedInvoiceURL = "hostedInvoiceUrl"
        case invoicePDFURL = "invoicePdfUrl"
    }
}

public struct CursorPagination: Codable, Hashable, Sendable {
    public let hasMore: Bool
    public let firstCursor: String?
    public let lastCursor: String?
}

public struct InvoicePage: Codable, Hashable, Sendable {
    public let invoices: [Invoice]
    public let pagination: CursorPagination
}

// MARK: - App Store

public struct AppleAccountToken: Codable, Hashable, Sendable {
    public let appAccountToken: UUID
    public let environment: String
}

public struct ConsumptionConsent: Codable, Hashable, Sendable {
    public let consented: Bool
    public let updatedAt: Date?
}

public struct AppleTransaction: Codable, Hashable, Sendable {
    public let transactionID: String
    public let originalTransactionID: String
    public let productID: String
    public let productType: StoreProductType
    public let environment: String
    public let quantity: Int
    public let priceMilliunits: Int?
    public let currency: String?
    public let purchaseAt: Date
    public let expiresAt: Date?
    public let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case productType, environment, quantity, priceMilliunits, currency
        case purchaseAt, expiresAt, revokedAt
        case transactionID = "transactionId"
        case originalTransactionID = "originalTransactionId"
        case productID = "productId"
    }
}

public struct SubscriptionRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let applicationID: String
    public let appUserID: String
    public let planID: String
    public let status: String
    public let currentPeriodStart: Date?
    public let currentPeriodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    public let billingProvider: BillingProvider
    public let providerSubscriptionID: String?
    public let providerProductID: String?
    public let providerSignedAt: Date?
    public let stripeSubscriptionID: String?
    public let stripeCustomerID: String?
    public let entitlementSnapshot: [String: JSONValue]?
    public let startedAt: Date
    public let endedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status, currentPeriodStart, currentPeriodEnd, cancelAtPeriodEnd
        case billingProvider, providerSignedAt, entitlementSnapshot, startedAt
        case endedAt, createdAt, updatedAt
        case applicationID = "applicationId"
        case appUserID = "appUserId"
        case planID = "planId"
        case providerSubscriptionID = "providerSubscriptionId"
        case providerProductID = "providerProductId"
        case stripeSubscriptionID = "stripeSubscriptionId"
        case stripeCustomerID = "stripeCustomerId"
    }
}

public struct AppleFulfillment: Codable, Hashable, Sendable {
    public let processed: String
    public let transaction: AppleTransaction
    public let purchase: PurchaseRecord?
    public let subscription: SubscriptionRecord?
}

public enum StorePurchaseOutcome: Hashable, Sendable {
    case completed(AppleFulfillment)
    case pending
    case cancelled
}

public struct StoreProductInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let displayPrice: String

    public init(id: String, displayName: String, description: String, displayPrice: String) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
    }
}
