import Foundation
import XCTest
@testable import RxSubscriptionIOS

final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, json) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class ClientTests: XCTestCase {
    private var client: Client!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        client = Client(
            serverURL: URL(string: "https://subscriptions.example.test")!,
            apiKey: "rxs_sandbox_test",
            rxlabUserID: "user-42",
            email: "reader@example.test",
            displayName: "Reader",
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        client = nil
        super.tearDown()
    }

    func testCatalogUsesAPIKeyUserAndDecodesStoreKitMapping() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "rxs_sandbox_test")
            XCTAssertEqual(request.url?.path, "/api/v1/catalog")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "rxlabUserId" })?.value,
                "user-42"
            )
            return (200, Self.catalogJSON)
        }

        let catalog = try await client.catalog()
        XCTAssertEqual(catalog.plans.first?.name, "Pro")
        XCTAssertEqual(catalog.plans.first?.purchaseOptions.last?.provider, .appleAppStore)
        XCTAssertEqual(catalog.plans.first?.purchaseOptions.last?.productID, "app.pro.monthly")
        XCTAssertEqual(catalog.topups.first?.eligible, true)
    }

    func testUsageDenialAtHTTP402DecodesAsResult() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/usage")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["rxlabUserId"] as? String, "user-42")
            XCTAssertEqual(object["item"] as? String, "generation")
            return (402, """
                {"allowed":false,"reason":"limit_exceeded","used":10,"limit":10,"remaining":0,"chargedUnits":0,"periodEnd":"2026-09-01T00:00:00.000Z","duplicate":false}
                """)
        }

        let result = try await client.recordUsage(item: "generation", idempotencyKey: "turn-1")
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.reason, "limit_exceeded")
        XCTAssertEqual(result.remaining, 0)
    }

    func testServerErrorRetainsMachineReadablePayload() async throws {
        URLProtocolStub.handler = { _ in
            (401, """
                {"error":"invalid_api_key","error_description":"API key is invalid or revoked"}
                """)
        }

        do {
            _ = try await client.balances()
            XCTFail("Expected an API error")
        } catch ClientError.server(let status, let payload, _) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(payload?.error, "invalid_api_key")
            XCTAssertEqual(payload?.errorDescription, "API key is invalid or revoked")
        }
    }

    func testCompletePublicAPISurfaceBuildsAndDecodesRequests() async throws {
        URLProtocolStub.handler = { request in
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            switch (method, path) {
            case ("GET", "/api/v1/entitlements"):
                return (200, Self.entitlementsJSON)
            case ("GET", "/api/v1/balances"):
                return (200, Self.balancesJSON)
            case ("POST", "/api/v1/balances"):
                return (200, "{\"entryId\":\"entry-1\",\"duplicate\":false,\"balanceAfter\":125}")
            case ("GET", "/api/v1/balances/ledger"):
                return (200, Self.ledgerJSON)
            case ("POST", "/api/v1/balances/reserve"):
                return (200, Self.reservationResultJSON)
            case ("GET", "/api/v1/balances/reservations"):
                return (200, Self.reservationJSON)
            case ("GET", let route) where route.hasPrefix("/api/v1/balances/reservations/"):
                return (200, Self.reservationJSON)
            case ("POST", let route) where route.hasSuffix("/increase"):
                return (200, Self.reservationResultJSON)
            case ("POST", let route) where route.hasSuffix("/settle"):
                return (200, Self.settlementJSON)
            case ("POST", let route) where route.hasSuffix("/release"):
                return (200, Self.releaseJSON)
            case ("GET", "/api/v1/usage"):
                return (200, Self.usageJSON)
            case ("GET", "/api/v1/usage/statistics"):
                return (200, Self.usageSeriesJSON)
            case ("GET", "/api/v1/balances/consumption"):
                return (200, Self.consumptionSeriesJSON)
            case ("POST", "/api/v1/checkout"):
                let body = try XCTUnwrap(Self.bodyData(from: request))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if object["kind"] as? String == "portal" {
                    return (200, "{\"url\":\"https://billing.example.test/portal\"}")
                }
                return (200, Self.checkoutJSON)
            case ("POST", "/api/v1/coupons/validate"):
                return (200, Self.couponJSON)
            case ("GET", "/api/v1/purchases"):
                return (200, Self.purchasesJSON)
            case ("GET", "/api/v1/invoices"):
                return (200, Self.invoicesJSON)
            case ("POST", "/api/v1/iap/apple/account-token"):
                return (200, "{\"appAccountToken\":\"492f2a34-88cf-4faa-a6db-bf1b145f899c\",\"environment\":\"sandbox\"}")
            case ("PUT", "/api/v1/iap/apple/consumption-consent"):
                return (200, "{\"consented\":true,\"updatedAt\":\"2026-08-30T12:00:00.000Z\"}")
            case ("POST", "/api/v1/iap/apple/transactions"):
                return (200, Self.fulfillmentJSON)
            default:
                XCTFail("Unhandled request: \(method) \(path)")
                return (500, "{\"error\":\"unhandled\"}")
            }
        }

        _ = try await client.entitlements()
        _ = try await client.balances()
        _ = try await client.adjustBalance(
            unit: "points",
            amount: 25,
            operation: .credit,
            idempotencyKey: "credit-1"
        )
        _ = try await client.ledger()
        let held = try await client.reserveBalance(
            unit: "points",
            amount: 10,
            idempotencyKey: "hold-1"
        )
        _ = try await client.reservation(id: held.reservationID)
        _ = try await client.reservation(idempotencyKey: "hold-1")
        _ = try await client.increaseReservation(id: held.reservationID, amount: 5, idempotencyKey: "grow-1")
        _ = try await client.settleReservation(id: held.reservationID, amount: 5, idempotencyKey: "settle-1")
        _ = try await client.releaseReservation(id: held.reservationID, idempotencyKey: "release-1")
        _ = try await client.usage()

        let from = Date(timeIntervalSince1970: 1_787_952_000)
        let to = Date(timeIntervalSince1970: 1_788_038_400)
        _ = try await client.usageStatistics(from: from, to: to, groupByItem: true)
        _ = try await client.consumptionStatistics(from: from, to: to, groupBy: .kind)
        _ = try await client.checkoutPlan(id: "plan-pro")
        _ = try await client.checkoutTopUp(id: "topup-100")
        _ = try await client.billingPortal()
        _ = try await client.validateCoupon(code: "SAVE10", planID: "plan-pro")
        _ = try await client.purchases()
        _ = try await client.invoices()
        _ = try await client.appleAccountToken()
        _ = try await client.setAppleConsumptionConsent(true)
        let fulfillment = try await client.submitAppleTransaction("header.payload.signature")
        XCTAssertEqual(fulfillment.transaction.productID, "app.pro.monthly")
    }

    func testFormattingUsesMinorUnitsAndPrecision() {
        XCTAssertFalse(SubscriptionFormatting.price(cents: 999, currency: "usd").isEmpty)
        XCTAssertEqual(SubscriptionFormatting.balance(12_345, precision: 2), "123.45")
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1_024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static let catalogJSON = """
    {
      "plans":[{
        "id":"plan-pro","key":"pro","name":"Pro","description":"Full access",
        "planGroup":"default","billingInterval":"month","intervalCount":1,
        "priceAmountCents":999,"currency":"usd","trialDays":7,
        "purchaseOptions":[
          {"provider":"stripe","flow":"checkout"},
          {"provider":"apple_app_store","flow":"storekit","productId":"app.pro.monthly","productType":"auto_renewable_subscription"}
        ]
      }],
      "topups":[{
        "id":"topup-100","key":"points-100","name":"100 points","description":null,
        "unit":"points","amount":100,"priceAmountCents":199,"currency":"usd",
        "eligible":true,"blockedBy":[],
        "purchaseOptions":[{"provider":"apple_app_store","flow":"storekit","productId":"app.points.100","productType":"consumable"}]
      }]
    }
    """

    private static let entitlementsJSON = """
    {
      "user":{"id":"local-user","rxlabUserId":"user-42","level":2,"levelKey":"pro"},
      "plans":[{
        "subscriptionId":"sub-1","purchaseId":null,"planId":"plan-pro","planKey":"pro","planName":"Pro","planGroup":"default",
        "status":"active","currentPeriodStart":"2026-08-01T00:00:00.000Z","currentPeriodEnd":"2026-09-01T00:00:00.000Z",
        "cancelAtPeriodEnd":false,"billingProvider":"apple_app_store","providerProductId":"app.pro.monthly"
      }],
      "roles":["subscriber"],"permissions":["read:reports:all"],"features":{"exports":"enabled"},
      "balances":[{"unit":"points","name":"Points","symbol":"pt","precision":0,"amount":100,"available":95}],
      "usage":[{"key":"generation","name":"Generations","used":2,"limit":10,"remaining":8,"resetsAt":"2026-09-01T00:00:00.000Z","resetPolicy":"billing_period"}]
    }
    """

    private static let balancesJSON = """
    {"balances":[{"unit":"points","name":"Points","amount":100,"available":95,"precision":0}]}
    """

    private static let ledgerJSON = """
    {"entries":[{"id":"entry-1","kind":"topup","unit":"points","delta":100,"balanceAfter":100,"description":"App Store top-up","referenceType":"store_transaction","referenceId":"store-1","createdAt":"2026-08-30T12:00:00.000Z","metadata":null}],"total":1,"page":1,"pageSize":20,"pageCount":1}
    """

    private static let reservationResultJSON = """
    {"reservationId":"reservation-1","amount":10,"available":85,"expiresAt":"2026-08-30T12:30:00.000Z","status":"open","duplicate":false}
    """

    private static let reservationJSON = """
    {"reservation":{"reservationId":"reservation-1","rxlabUserId":"user-42","unit":"points","initialAmount":10,"remainingReserved":10,"status":"open","description":"Balance reservation","metadata":null,"requestedAmount":0,"settledAmount":0,"shortfallAmount":0,"releasedAmount":0,"available":85,"balanceAfter":null,"expiresAt":"2026-08-30T12:30:00.000Z","releaseReason":null,"entryId":null,"createdAt":"2026-08-30T12:00:00.000Z","updatedAt":"2026-08-30T12:00:00.000Z","closedAt":null}}
    """

    private static let settlementJSON = """
    {"reservationId":"reservation-1","entryId":"entry-2","operationRequestedAmount":5,"operationSettledAmount":5,"operationShortfallAmount":0,"requestedAmount":5,"settledAmount":5,"shortfallAmount":0,"remainingReserved":5,"balanceAfter":95,"status":"open","expiresAt":"2026-08-30T12:30:00.000Z","duplicate":false}
    """

    private static let releaseJSON = """
    {"reservationId":"reservation-1","released":true,"releasedAmount":5,"remainingReserved":0,"balanceAfter":95,"status":"closed","duplicate":false}
    """

    private static let usageJSON = """
    {"usage":[{"itemId":"usage-1","key":"generation","name":"Generations","used":2,"limit":10,"remaining":8,"periodStart":"2026-08-01T00:00:00.000Z","periodEnd":"2026-09-01T00:00:00.000Z","resetsAt":"2026-09-01T00:00:00.000Z","resetPolicy":"billing_period","overagePolicy":"block"}]}
    """

    private static let usageSeriesJSON = """
    {"from":"2026-08-29T00:00:00.000Z","to":"2026-08-30T00:00:00.000Z","granularity":"day","totals":[{"start":"2026-08-29T00:00:00.000Z","amount":2,"consumed":2,"eventCount":1,"chargedUnits":0}],"groups":[]}
    """

    private static let consumptionSeriesJSON = """
    {"from":"2026-08-29T00:00:00.000Z","to":"2026-08-30T00:00:00.000Z","granularity":"day","totals":[{"start":"2026-08-29T00:00:00.000Z","spent":2,"granted":0,"net":-2,"entryCount":1}],"groups":[],"unit":null}
    """

    private static let checkoutJSON = """
    {"checkoutUrl":"https://checkout.example.test/session","sessionId":"cs_test","purchaseId":null,"discount":null,"promotionCodesEnabled":true}
    """

    private static let couponJSON = """
    {"valid":true,"code":"SAVE10","name":"Save 10","description":null,"terms":"10% off","duration":"once","durationInMonths":null,"discountCents":100,"totalCents":899,"currency":"usd","capped":false,"reason":null,"blockers":[]}
    """

    private static let purchasesJSON = """
    {"purchases":[{"id":"purchase-1","kind":"topup","status":"paid","unit":"points","unitsGranted":100,"amountCents":199,"currency":"usd","billingProvider":"apple_app_store","providerTransactionId":"tx-1","providerProductId":"app.points.100","quantity":1,"priceMilliunits":1990,"fulfillmentFailureCode":null,"createdAt":"2026-08-30T12:00:00.000Z","hostedInvoiceUrl":null,"invoicePdfUrl":null}],"total":1,"page":1,"pageSize":20,"pageCount":1}
    """

    private static let invoicesJSON = """
    {"invoices":[{"id":"in-1","number":"INV-1","description":"Pro","status":"paid","amountCents":999,"currency":"usd","createdAt":"2026-08-30T12:00:00.000Z","hostedInvoiceUrl":"https://invoice.example.test/in-1","invoicePdfUrl":null}],"pagination":{"hasMore":false,"firstCursor":"in-1","lastCursor":"in-1"}}
    """

    private static let fulfillmentJSON = """
    {"processed":"new","transaction":{"transactionId":"tx-1","originalTransactionId":"original-1","productId":"app.pro.monthly","productType":"auto_renewable_subscription","environment":"sandbox","quantity":1,"priceMilliunits":9990,"currency":"usd","purchaseAt":"2026-08-30T12:00:00.000Z","expiresAt":"2026-09-30T12:00:00.000Z","revokedAt":null},"purchase":null,"subscription":null}
    """
}
