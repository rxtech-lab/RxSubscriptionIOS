import Foundation
@testable import RxSubscriptionIOS
import XCTest

@MainActor
final class PaywallTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testServerPaywallUsesPublishableCredentialsAndDecodesResolvedTree() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = Client(
            serverURL: URL(string: "https://subscriptions.example.test")!,
            publishableKey: "rxs_pk_sandbox_test",
            rxlabUserID: "user-42",
            userToken: { _ in "oauth-access-token" },
            session: URLSession(configuration: configuration)
        )

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/paywall")
            // The only query it carries: product labels must be priced from the
            // App Store, not from the Stripe catalog.
            XCTAssertEqual(request.url?.query, "platform=ios")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "rxs_pk_sandbox_test")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer oauth-access-token"
            )
            return (200, Self.paywallJSON)
        }

        let paywall = try await client.paywall()
        XCTAssertEqual(paywall.name, "Classic")
        XCTAssertEqual(paywall.designVersion, 2)
        XCTAssertEqual(paywall.spec.version, 1)
        XCTAssertEqual(paywall.spec.root.type, "ScrollView")

        let page = try XCTUnwrap(paywall.spec.root.children?.first)
        guard case .edges(let padding) = page.modifiers?.padding else {
            return XCTFail("Expected per-edge page padding")
        }
        XCTAssertEqual(padding.top, 24)
        XCTAssertEqual(padding.leading, 20)

        let productList = try XCTUnwrap(page.children?.first(where: { $0.type == "ProductList" }))
        XCTAssertEqual(productList.highlightedProductID, "plan-pro")
        XCTAssertEqual(productList.products?.first?.key, "pro")
        XCTAssertEqual(productList.products?.first?.priceLabel, "$9.99")
        XCTAssertEqual(productList.products?.first?.purchaseOptions.first?.productID, "app.pro.monthly")
        // A list with no period switcher must stay a plain list.
        XCTAssertNil(productList.periodOptions)

        let button = try XCTUnwrap(page.children?.first(where: { $0.type == "Button" }))
        XCTAssertEqual(button.action, .purchase(productID: nil))
    }

    func testTabViewExposesOneTitledTabPerPage() throws {
        let spec = try JSONDecoder().decode(PaywallSpec.self, from: Data(Self.tabbedSpecJSON.utf8))
        let tabs = try XCTUnwrap(spec.root.children?.first)
        XCTAssertEqual(tabs.type, "TabView")
        XCTAssertEqual(tabs.props["selectedIndex"], .number(1))
        XCTAssertEqual(tabs.tabs.map(\.title), ["Monthly", "Yearly", ""])
        XCTAssertEqual(tabs.tabs[1].badge, "-20%")
        XCTAssertEqual(tabs.tabs[0].icon, "calendar")
        // The third page has no entry of its own; padding it is what keeps a
        // page the design forgot to name reachable instead of dropped.
        XCTAssertEqual(tabs.children?.count, 3)
    }

    func testProductListDecodesItsPeriodSwitcher() throws {
        let spec = try JSONDecoder().decode(PaywallSpec.self, from: Data(Self.tabbedSpecJSON.utf8))
        let list = try XCTUnwrap(spec.root.children?.first?.children?.first)
        let periods = try XCTUnwrap(list.periodOptions)
        XCTAssertEqual(periods.map(\.key), ["month", "year"])
        XCTAssertEqual(periods.map(\.label), ["Monthly", "Yearly"])
        XCTAssertEqual(periods[1].productIDs, ["plan-yearly"])
        XCTAssertEqual(periods[1].highlightedProductID, "plan-yearly")
        XCTAssertEqual(periods.filter(\.selected).map(\.key), ["year"])
    }

    func testPaywallSourceSupportsLocalAndServerModes() {
        XCTAssertEqual(PaywallSource.local.rawValue, "local")
        XCTAssertEqual(PaywallSource.server.rawValue, "server")
    }

    private static let paywallJSON = """
    {
      "id": "paywall-1",
      "name": "Classic",
      "designVersion": 2,
      "publishedAt": "2026-09-02T06:00:00.000Z",
      "spec": {
        "version": 1,
        "theme": {
          "colorScheme": "system",
          "colors": {
            "primary": "#2563EB",
            "background": "#FFFFFF",
            "foreground": "#0F172A",
            "muted": "#64748B",
            "accent": "#F59E0B"
          },
          "cornerRadius": 14,
          "fontDesign": "default"
        },
        "root": {
          "id": "root",
          "type": "ScrollView",
          "props": { "axis": "vertical", "showsIndicators": false },
          "children": [{
            "id": "page",
            "type": "VStack",
            "props": { "spacing": 20, "alignment": "leading" },
            "modifiers": { "padding": { "top": 24, "leading": 20, "bottom": 32, "trailing": 20 } },
            "children": [
              {
                "id": "title",
                "type": "Text",
                "props": { "text": "Unlock everything", "style": "largeTitle", "weight": "bold" }
              },
              {
                "id": "products",
                "type": "ProductList",
                "props": { "layout": "vertical", "style": "card", "showTrialBadge": true },
                "products": [{
                  "id": "plan-pro",
                  "key": "pro",
                  "name": "Pro",
                  "description": "Full access",
                  "planGroup": "default",
                  "billingInterval": "month",
                  "intervalCount": 1,
                  "priceAmountCents": 999,
                  "currency": "usd",
                  "trialDays": 7,
                  "purchaseOptions": [{
                    "provider": "apple_app_store",
                    "flow": "storekit",
                    "productId": "app.pro.monthly",
                    "productType": "auto_renewable_subscription"
                  }],
                  "priceLabel": "$9.99",
                  "periodLabel": "per month",
                  "savingsLabel": null,
                  "badge": "Most popular"
                }],
                "highlightedProductId": "plan-pro"
              },
              {
                "id": "cta",
                "type": "Button",
                "props": {
                  "label": "Continue",
                  "action": { "type": "purchase" },
                  "style": "filled",
                  "fullWidth": true
                }
              }
            ]
          }]
        }
      }
    }
    """
    private static let tabbedSpecJSON = """
    {
      "version": 1,
      "theme": {
        "colorScheme": "system",
        "colors": {
          "primary": "#2563EB",
          "background": "#FFFFFF",
          "foreground": "#0F172A",
          "muted": "#64748B",
          "accent": "#F59E0B"
        },
        "cornerRadius": 14,
        "fontDesign": "default"
      },
      "root": {
        "id": "root",
        "type": "VStack",
        "props": {},
        "children": [{
          "id": "tabs",
          "type": "TabView",
          "props": {
            "tabs": [
              { "title": "Monthly", "icon": "calendar" },
              { "title": "Yearly", "badge": "-20%" }
            ],
            "selectedIndex": 1,
            "style": "segmented"
          },
          "children": [
            {
              "id": "plans",
              "type": "ProductList",
              "props": { "periodFilter": { "style": "chips" } },
              "products": [],
              "highlightedProductId": "plan-yearly",
              "periodOptions": [
                {
                  "key": "month",
                  "label": "Monthly",
                  "productIds": ["plan-monthly"],
                  "highlightedProductId": "plan-monthly",
                  "selected": false
                },
                {
                  "key": "year",
                  "label": "Yearly",
                  "productIds": ["plan-yearly"],
                  "highlightedProductId": "plan-yearly",
                  "selected": true
                }
              ]
            },
            { "id": "note", "type": "Text", "props": { "text": "Second page" } },
            { "id": "extra", "type": "Text", "props": { "text": "Unnamed page" } }
          ]
        }]
      }
    }
    """
}
