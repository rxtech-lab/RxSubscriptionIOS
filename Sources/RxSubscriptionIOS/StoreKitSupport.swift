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
