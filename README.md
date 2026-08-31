# RxSubscriptionIOS

`RxSubscriptionIOS` is a Swift Package for the RxSubscription backend. It includes:

- a typed client for every public `/api/v1` endpoint;
- StoreKit 2 product loading, purchase fulfillment, and restore support;
- reusable SwiftUI plan, top-up, usage, balance, and balance-history screens;
- a section-selectable paywall with a host-app supplied SwiftUI header.

The package supports iOS 16+, macOS 13+, and Swift 5.9+.

## Add the package

In Xcode, choose **File → Add Package Dependencies → Add Local…** and select this folder. Import the library where it is used:

```swift
import RxSubscriptionIOS
```

## Configure a client

Create one client for the currently signed-in RxLab user. The API key controls whether the server uses sandbox or production data.

```swift
let subscriptions = Client(
    serverURL: URL(string: "https://subscription.example.com")!,
    apiKey: configuration.subscriptionAPIKey,
    rxlabUserID: session.userID,
    email: session.email,
    displayName: session.displayName
)
```

Do not place an unrestricted or unrelated server credential in an app bundle. Mobile app secrets can be extracted. Use a dedicated, revocable application key for this backend contract and rotate it if the app is compromised.

## SwiftUI views

Each view can be used independently:

```swift
SubscriptionPlanView(client: subscriptions)
TopUpView(client: subscriptions)
UsageView(client: subscriptions)
BalanceView(client: subscriptions)
BalanceHistoryView(client: subscriptions)
```

Plans and top-ups accept a custom header:

```swift
SubscriptionPlanView(client: subscriptions) {
    VStack(alignment: .leading, spacing: 8) {
        Text("Choose your plan")
            .font(.largeTitle.bold())
        Text("Upgrade, restore, or keep using the free tier.")
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

Use `PaywallView` to expose one section or a segmented set of sections with a single custom header:

```swift
PaywallView(
    client: subscriptions,
    sections: [.plans, .topUps, .usage, .balances],
    initialSection: .plans
) {
    PaywallHeroView()
}
```

For a focused screen, pass only one section:

```swift
PaywallView(client: subscriptions, sections: [.usage])
```

## StoreKit lifecycle

When an Apple mapping is present in the catalog, the views prefer StoreKit and show Apple's localized price. The package performs the required sequence:

1. requests the stable App Store account token from the backend;
2. attaches it as StoreKit's `appAccountToken`;
3. purchases and verifies the StoreKit transaction locally;
4. submits the signed JWS to the backend for authoritative fulfillment;
5. finishes the StoreKit transaction only after fulfillment succeeds.

The plan screen includes Restore Purchases. You can also invoke StoreKit directly:

```swift
let outcome = try await subscriptions.purchaseApple(
    productID: "com.example.pro.monthly"
)

let restored = try await subscriptions.restoreApplePurchases()
```

Enable the **In-App Purchase** capability in the containing app target. Products and Notifications V2 still need to be configured in App Store Connect and in the RxSubscription console.

## Client API

The client covers the backend's complete public API surface.

| Area | Methods |
| --- | --- |
| Catalog and access | `catalog`, `entitlements` |
| Balances | `balances`, `adjustBalance`, `ledger`, `consumptionStatistics` |
| Reservations | `reserveBalance`, both `reservation` overloads, `increaseReservation`, `settleReservation`, `releaseReservation` |
| Usage | `usage`, `recordUsage`, `usageStatistics` |
| Stripe | `checkoutPlan`, `checkoutTopUp`, `billingPortal`, `validateCoupon`, `invoices` |
| Purchases | `purchases` |
| App Store bridge | `appleAccountToken`, `setAppleConsumptionConsent`, `submitAppleTransaction` |
| StoreKit | `storeProducts`, `purchaseApple`, `restoreApplePurchases` |

Metadata values use the package's `JSONValue` type. Balance and usage mutations preserve the server's idempotency contract. In particular, supply stable idempotency keys when retrying balance mutations or reservation operations.

`BillingProvider.googlePlay` is present as the future provider discriminator. The package intentionally exposes no inactive Google Play purchase endpoint because the backend does not have one yet.

## Direct API examples

```swift
let entitlement = try await subscriptions.entitlements()
let currentUsage = try await subscriptions.usage()
let history = try await subscriptions.ledger(page: 1, pageSize: 20)

let result = try await subscriptions.recordUsage(
    item: "generation",
    amount: 1,
    idempotencyKey: requestID
)

guard result.allowed else {
    // `reason` is `limit_exceeded` or `insufficient_balance`.
    return
}
```

The backend returns usage denials with HTTP 402. `recordUsage` decodes those responses as `UsageRecordResult` rather than throwing, so callers can handle `allowed == false` normally.

## Tests

```sh
swift test
```

The test suite verifies authentication and user scoping, StoreKit catalog decoding, error payloads, HTTP 402 usage behavior, date handling, formatting, and request/response coverage for every public backend route.
