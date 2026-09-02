# RxSubscriptionIOS

`RxSubscriptionIOS` is a Swift Package for the RxSubscription backend. It includes:

- a typed client for every public `/api/v1` endpoint;
- StoreKit 2 product loading, purchase fulfillment, and restore support;
- reusable SwiftUI plan, top-up, usage, balance, and balance-history screens;
- local and server-driven SwiftUI paywalls, including native StoreKit actions.

The package requires iOS 26+, macOS 26+, and Swift 5.9+.

## Add the package

```swift
.package(url: "https://github.com/rxtech-lab/RxSubscriptionIOS.git", from: "0.2.0")
```

Or in Xcode, **File → Add Package Dependencies…** with that URL. Import the library where it is used:

```swift
import RxSubscriptionIOS
```

## Configure a client

Create one client for the currently signed-in RxLab user. The key controls whether the server uses sandbox or production data.

Which initializer you want depends on the kind of key you hold. **In an app, use a publishable key.**

### Publishable key — for apps

A publishable key is safe to ship inside a binary because it does nothing on its own. Every request also carries the signed-in user's rxlab access token, and the server acts only for whoever that token identifies — so a key lifted out of your app grants an attacker nothing they did not already have.

```swift
let subscriptions = Client(
    serverURL: URL(string: "https://subscription.example.com")!,
    publishableKey: configuration.subscriptionPublishableKey,
    rxlabUserID: session.userID,
    email: session.email,
    userToken: { forceRefresh in
        try await session.accessToken(forceRefresh: forceRefresh)
    }
)
```

The `userToken` closure is called before every request, and called again with `forceRefresh: true` if the server rejects the token — so an access token that expired while a screen sat open recovers without the user noticing. Your app's existing session machinery stays the only thing that knows how to refresh.

Publishable keys reach the read and purchase endpoints: catalog, entitlements, usage, balances, ledger, consumption, invoices, purchases, coupon validation, checkout, and the App Store bridge. Crediting a balance, recording usage, and the whole reservation family answer `403 insufficient_key_scope` — those belong on a server.

### Secret key — for servers

```swift
let subscriptions = Client(
    serverURL: URL(string: "https://subscription.example.com")!,
    apiKey: configuration.subscriptionAPIKey,
    rxlabUserID: session.userID,
    email: session.email,
    displayName: session.displayName
)
```

A secret key reaches every endpoint and names whichever user it likes, so it must never ship in an app bundle — mobile app secrets can be extracted, and this one can credit any balance for any user.

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

`PaywallView` defaults to `.local`, which exposes one section or a segmented set
of sections with a host-app supplied header:

```swift
PaywallView(
    client: subscriptions,
    paywall: .local,
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

Use `.server` to fetch `GET /api/v1/paywall` and recursively render the published
SwiftUI tree assigned to the application:

```swift
PaywallView(client: subscriptions, paywall: .server)
```

The server document controls layout, theme, text, images, product lists, links,
and purchase, restore, dismiss, open-URL, and product-selection actions. Product
lists arrive with the application's active plans and display prices already
resolved. Pull to refresh fetches the currently published design again.

A `TabView` node draws a tab bar and shows one child at a time — tab *n* is
child *n* — so a design can put monthly and yearly offers on their own pages.
A product list can instead carry its own period switcher: its `periodOptions`
arrive resolved, each naming the plans it reveals and the one to preselect.
Both move the selection with the buyer, so Continue always buys the plan they
are looking at rather than one left selected on a page they navigated away
from.

Both this request and `catalog()` send `platform=ios`, so a plan sold from an
App Store price tier is labelled with that price rather than with the price the
same plan costs through Stripe. The server can infer the platform from the user
agent, but the client names it outright so a host app that replaces the user
agent cannot end up showing web prices next to a StoreKit purchase.

For a publishable client, this request uses the configured key as `X-Api-Key`
and the access token returned by `userToken` as `Authorization: Bearer`. The
OAuth client ID is the verified `client_id` claim in that token and must be in
the publishable key's allowed-client list in RxSubscription; it is not sent as
an unverified query parameter. A secret-key client can fetch the same endpoint
without a user token, but a secret key must not ship in an app.

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

Start `observeTransactionUpdates()` once at launch and hold the task for the lifetime of the session:

```swift
transactionObserver = subscriptions.observeTransactionUpdates { _ in
    Task { await store.refresh() }
}
```

Renewals, Ask-to-Buy approvals, purchases made on another device, and interrupted flows all arrive on `Transaction.updates` rather than as the result of `purchaseApple`. Without an observer they are never finished, so StoreKit re-delivers them on every launch. The backend still learns about them from App Store Server Notifications either way; this just keeps the app in step.

Enable the **In-App Purchase** capability in the containing app target. Products and Notifications V2 still need to be configured in App Store Connect and in the RxSubscription console.

## Client API

The client covers the backend's complete public API surface.

| Area | Methods |
| --- | --- |
| Catalog, paywall, and access | `catalog`, `paywall`, `entitlements` |
| Balances | `balances`, `adjustBalance`, `ledger`, `consumptionStatistics` |
| Reservations | `reserveBalance`, both `reservation` overloads, `increaseReservation`, `settleReservation`, `releaseReservation` |
| Usage | `usage`, `recordUsage`, `usageStatistics` |
| Stripe | `checkoutPlan`, `checkoutTopUp`, `billingPortal`, `validateCoupon`, `invoices` |
| Purchases | `purchases` |
| App Store bridge | `appleAccountToken`, `setAppleConsumptionConsent`, `submitAppleTransaction` |
| StoreKit | `storeProducts`, `purchaseApple`, `restoreApplePurchases`, `observeTransactionUpdates` |

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

The test suite verifies authentication and user scoping, StoreKit catalog decoding, error payloads, HTTP 402 usage behavior, date handling, formatting, and request/response coverage for every public backend route. It also covers the publishable-key path: that both credentials are sent, that a 401 triggers exactly one refreshed retry and no more, that a secret-key client is never retried, and that a failed token lookup surfaces as `ClientError.userTokenUnavailable` rather than as a network error.
