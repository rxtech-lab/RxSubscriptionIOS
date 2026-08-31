import Foundation

final class RxSubscriptionPreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let json = PreviewFixtures.response(for: request.url?.path ?? "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
enum PreviewFixtures {
    static func client() -> Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RxSubscriptionPreviewURLProtocol.self]
        return Client(
            serverURL: URL(string: "https://preview.rxsubscription.local")!,
            apiKey: "rxs_sandbox_preview",
            rxlabUserID: "preview-user",
            email: "preview@example.com",
            displayName: "Preview User",
            session: URLSession(configuration: configuration)
        )
    }

    nonisolated static func response(for path: String) -> String {
        switch path {
        case "/api/v1/catalog": catalog
        case "/api/v1/usage": usage
        case "/api/v1/balances": balances
        case "/api/v1/balances/ledger": ledger
        case "/api/v1/checkout": checkout
        default: "{}"
        }
    }

    nonisolated static let catalog = """
    {
      "plans": [
        {
          "id": "starter", "key": "starter", "name": "Starter",
          "description": "Essential features for personal projects.",
          "planGroup": "default", "billingInterval": "month", "intervalCount": 1,
          "priceAmountCents": 499, "currency": "usd", "trialDays": 7,
          "purchaseOptions": [{"provider": "stripe", "flow": "checkout"}]
        },
        {
          "id": "pro", "key": "pro", "name": "Pro",
          "description": "Higher limits, premium tools, and priority processing.",
          "planGroup": "default", "billingInterval": "month", "intervalCount": 1,
          "priceAmountCents": 1499, "currency": "usd", "trialDays": 14,
          "purchaseOptions": [{"provider": "stripe", "flow": "checkout"}]
        }
      ],
      "topups": [
        {
          "id": "points-100", "key": "points-100", "name": "Quick refill",
          "description": "A small boost for occasional extra usage.",
          "unit": "points", "amount": 100, "priceAmountCents": 199,
          "currency": "usd", "eligible": true, "blockedBy": [],
          "purchaseOptions": [{"provider": "stripe", "flow": "checkout"}]
        },
        {
          "id": "points-1000", "key": "points-1000", "name": "Power pack",
          "description": "Best for a busy month or a large project.",
          "unit": "points", "amount": 1000, "priceAmountCents": 1299,
          "currency": "usd", "eligible": true, "blockedBy": [],
          "purchaseOptions": [{"provider": "stripe", "flow": "checkout"}]
        }
      ]
    }
    """

    nonisolated static let usage = """
    {
      "usage": [
        {
          "itemId": "generation", "key": "generation", "name": "Generations",
          "used": 68, "limit": 100, "remaining": 32,
          "periodStart": "2026-08-01T00:00:00.000Z",
          "periodEnd": "2026-09-01T00:00:00.000Z",
          "resetsAt": "2026-09-01T00:00:00.000Z",
          "resetPolicy": "billing_period", "overagePolicy": "block"
        },
        {
          "itemId": "exports", "key": "exports", "name": "Report exports",
          "used": 4, "limit": 20, "remaining": 16,
          "periodStart": "2026-08-01T00:00:00.000Z",
          "periodEnd": "2026-09-01T00:00:00.000Z",
          "resetsAt": "2026-09-01T00:00:00.000Z",
          "resetPolicy": "billing_period", "overagePolicy": "block"
        },
        {
          "itemId": "projects", "key": "projects", "name": "Projects",
          "used": 12, "limit": null, "remaining": null,
          "periodStart": "2026-08-01T00:00:00.000Z", "periodEnd": null,
          "resetsAt": null, "resetPolicy": "never", "overagePolicy": "allow"
        }
      ]
    }
    """

    nonisolated static let balances = """
    {
      "balances": [
        {"unit": "points", "name": "Points", "amount": 2450, "available": 2325, "precision": 0},
        {"unit": "credits", "name": "AI credits", "amount": 18750, "available": 18750, "precision": 2},
        {"unit": "exports", "name": "Export tokens", "amount": 8, "available": 8, "precision": 0}
      ]
    }
    """

    nonisolated static let ledger = """
    {
      "entries": [
        {"id": "entry-1", "kind": "topup", "unit": "points", "delta": 1000, "balanceAfter": 2450, "description": "Power pack", "referenceType": "purchase", "referenceId": "purchase-1", "createdAt": "2026-08-30T10:15:00.000Z", "metadata": null},
        {"id": "entry-2", "kind": "usage", "unit": "points", "delta": -75, "balanceAfter": 1450, "description": "Report generation", "referenceType": "usage_item", "referenceId": "generation", "createdAt": "2026-08-29T16:45:00.000Z", "metadata": null},
        {"id": "entry-3", "kind": "plan_grant", "unit": "points", "delta": 500, "balanceAfter": 1525, "description": "Pro monthly allowance", "referenceType": "subscription", "referenceId": "subscription-1", "createdAt": "2026-08-28T08:00:00.000Z", "metadata": null},
        {"id": "entry-4", "kind": "usage", "unit": "points", "delta": -25, "balanceAfter": 1025, "description": "Document export", "referenceType": "usage_item", "referenceId": "exports", "createdAt": "2026-08-27T13:20:00.000Z", "metadata": null}
      ],
      "total": 4, "page": 1, "pageSize": 20, "pageCount": 1
    }
    """

    nonisolated static let checkout = """
    {"checkoutUrl":"https://checkout.example.com/preview","sessionId":"preview-session","purchaseId":null,"discount":null,"promotionCodesEnabled":false}
    """
}
