import Foundation
import StoreKit

@MainActor
public extension Client {
    /// Loads localized App Store product information for the mapped product IDs.
    func storeProducts(productIDs: [String]) async throws -> [StoreProductInfo] {
        let products = try await Product.products(for: Array(Set(productIDs)))
        return products.map {
            StoreProductInfo(
                id: $0.id,
                displayName: $0.displayName,
                description: $0.description,
                displayPrice: $0.displayPrice
            )
        }
    }

    /// Purchases one mapped StoreKit product, waits for server fulfillment, then finishes it.
    func purchaseApple(productID: String, quantity: Int = 1) async throws -> StorePurchaseOutcome {
        guard let product = try await Product.products(for: [productID]).first else {
            throw ClientError.storeProductNotFound(productID)
        }
        let account = try await appleAccountToken()
        var options: Set<Product.PurchaseOption> = [.appAccountToken(account.appAccountToken)]
        if quantity > 1 { options.insert(.quantity(quantity)) }

        switch try await product.purchase(options: options) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw ClientError.unverifiedStoreTransaction
            }
            let fulfillment = try await submitAppleTransaction(verification.jwsRepresentation)
            await transaction.finish()
            return .completed(fulfillment)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .pending
        }
    }

    /// Forwards StoreKit transactions that arrive outside a purchase call.
    ///
    /// Renewals, Ask-to-Buy approvals, purchases made on another device, and
    /// anything interrupted mid-flight all land on `Transaction.updates` rather
    /// than as the result of ``purchaseApple(productID:quantity:)``. Without an
    /// observer they are never finished, so StoreKit re-delivers them on every
    /// launch and the app's own view of the entitlement lags.
    ///
    /// The server is still the authority — App Store Server Notifications reach
    /// it whether or not the app is running — so a submission that fails here
    /// is logged past rather than retried: the transaction stays unfinished and
    /// StoreKit will offer it again.
    ///
    /// Start this once, early, and hold the returned task for the lifetime of
    /// the session; cancelling it stops the observation.
    ///
    /// - Parameter onFulfillment: Called on the main actor after each accepted
    ///   transaction, so a store can refresh its cached balance.
    func observeTransactionUpdates(
        onFulfillment: (@MainActor (AppleFulfillment) -> Void)? = nil
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = verification else { continue }
                do {
                    let fulfillment = try await self.submitAppleTransaction(
                        verification.jwsRepresentation
                    )
                    await transaction.finish()
                    onFulfillment?(fulfillment)
                } catch {
                    // Deliberately left unfinished — see above.
                    continue
                }
            }
        }
    }

    /// Presents Apple's restore sheet, reconciles every current entitlement, and finishes it.
    @discardableResult
    func restoreApplePurchases() async throws -> [AppleFulfillment] {
        try await AppStore.sync()
        var restored: [AppleFulfillment] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            let fulfillment = try await submitAppleTransaction(verification.jwsRepresentation)
            await transaction.finish()
            restored.append(fulfillment)
        }
        return restored
    }
}
