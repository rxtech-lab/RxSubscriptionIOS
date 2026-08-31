import SwiftUI

public struct SubscriptionPlanView<Header: View>: View {
    @StateObject private var model: SubscriptionPlanViewModel
    @Environment(\.openURL) private var openURL
    private let header: Header
    @State private var selectedPlanID: String?

    public init(client: Client, @ViewBuilder header: () -> Header) {
        _model = StateObject(wrappedValue: SubscriptionPlanViewModel(client: client))
        self.header = header()
    }

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    planListContent
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await model.load(force: true) }
            .task { await model.load() }
            .onChange(of: model.plans) { _, plans in
                if selectedPlanID == nil {
                    let recommended = plans.first(where: { isRecommended($0) })
                    selectedPlanID = (recommended ?? plans.first)?.id
                }
            }
            .alert("Purchase", isPresented: $model.showingMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }

            if model.processingID != nil || model.isRestoring {
                busyOverlay
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var planListContent: some View {
        if model.isLoading && model.plans.isEmpty {
            LoadingView(title: "Loading plans…")
        } else if let error = model.error, model.plans.isEmpty {
            InlineErrorView(message: error) { Task { await model.load(force: true) } }
        } else if model.plans.isEmpty {
            EmptyStateView(
                icon: "rectangle.stack",
                title: "No plans available",
                message: "Active subscription plans will appear here."
            )
        } else {
            VStack(spacing: 12) {
                Text("Choose a plan")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(model.plans) { plan in
                    planCard(plan)
                }

                purchaseButton

                if model.hasAppleProducts {
                    Button("Restore Purchases") {
                        Task { await model.restore() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .disabled(model.isRestoring || model.processingID != nil)
                }

                renewalDisclosure
            }
        }
    }

    private func planCard(_ plan: SubscriptionPlan) -> some View {
        let isSelected = selectedPlanID == plan.id
        let showBadge = isRecommended(plan)

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedPlanID = plan.id
            }
        } label: {
            VStack(spacing: 0) {
                if showBadge {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("BEST VALUE")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.accentColor)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 17, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 17
                        )
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(plan.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if plan.trialDays > 0 {
                                Text("\(plan.trialDays)-day trial")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                        Text(intervalText(for: plan))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        if let desc = plan.description, !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(model.price(for: plan))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if plan.billingInterval != "one_time" {
                            Text("/ \(plan.billingInterval)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: showBadge
                        ? AnyShape(UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 17,
                            bottomTrailingRadius: 17, topTrailingRadius: 0
                          ))
                        : AnyShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.processingID != nil || model.isRestoring)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }

    private var purchaseButton: some View {
        Button(action: purchaseSelected) {
            Group {
                if model.processingID != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Processing…")
                    }
                } else {
                    Text(actionButtonTitle)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent)
        .cornerRadius(16)
        .disabled(selectedPlanID == nil || model.processingID != nil || model.isRestoring)
    }

    private var renewalDisclosure: some View {
        Text("Payment will be charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. You can manage or cancel anytime in App Store account settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(model.isRestoring ? "Restoring purchases…" : "Completing purchase…")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - Helpers

    private var actionButtonTitle: String {
        guard let id = selectedPlanID,
              let plan = model.plans.first(where: { $0.id == id }) else {
            return "Continue"
        }
        if plan.trialDays > 0 { return "Start \(plan.trialDays)-Day Free Trial" }
        if plan.billingInterval == "one_time" { return "Buy \(plan.name)" }
        return "Continue with \(plan.name)"
    }

    private func purchaseSelected() {
        guard let id = selectedPlanID,
              let plan = model.plans.first(where: { $0.id == id }) else { return }
        Task {
            if let url = await model.purchase(plan) { openURL(url) }
        }
    }

    private func intervalText(for plan: SubscriptionPlan) -> String {
        if plan.billingInterval == "one_time" { return "One-time purchase" }
        let count = plan.intervalCount
        let interval = count == 1 ? plan.billingInterval : "\(plan.billingInterval)s"
        return count == 1 ? "Billed every \(interval)" : "Billed every \(count) \(interval)"
    }

    private func isRecommended(_ plan: SubscriptionPlan) -> Bool {
        let name = plan.name.lowercased()
        if name.contains("annual") || name.contains("yearly") || name.contains("year") { return true }
        return plan.billingInterval == "year"
    }
}

// MARK: - Empty header convenience

public extension SubscriptionPlanView where Header == EmptyView {
    init(client: Client) {
        self.init(client: client) { EmptyView() }
    }
}

// MARK: - View Model

@MainActor
private final class SubscriptionPlanViewModel: ObservableObject {
    @Published var plans: [SubscriptionPlan] = []
    @Published var products: [String: StoreProductInfo] = [:]
    @Published var isLoading = false
    @Published var isRestoring = false
    @Published var processingID: String?
    @Published var error: String?
    @Published var message: String?
    @Published var showingMessage = false

    let client: Client
    var hasAppleProducts: Bool {
        plans.contains { plan in plan.purchaseOptions.contains { $0.provider == .appleAppStore } }
    }

    init(client: Client) { self.client = client }

    func load(force: Bool = false) async {
        guard force || plans.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let catalog = try await client.catalog()
            plans = catalog.plans
            let ids = catalog.plans.flatMap(\.purchaseOptions).compactMap { option in
                option.provider == .appleAppStore ? option.productID : nil
            }
            let loaded = ids.isEmpty ? [] : try await client.storeProducts(productIDs: ids)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        } catch {
            self.error = error.localizedDescription
        }
    }

    func price(for plan: SubscriptionPlan) -> String {
        if let id = appleOption(for: plan)?.productID, let product = products[id] {
            return product.displayPrice
        }
        return SubscriptionFormatting.price(cents: plan.priceAmountCents, currency: plan.currency)
    }

    func purchase(_ plan: SubscriptionPlan) async -> URL? {
        processingID = plan.id
        defer { processingID = nil }
        do {
            if let productID = appleOption(for: plan)?.productID {
                let outcome = try await client.purchaseApple(productID: productID)
                switch outcome {
                case .completed: show("Purchase fulfilled successfully.")
                case .pending: show("The purchase is pending approval.")
                case .cancelled: break
                }
                return nil
            }
            return try await client.checkoutPlan(id: plan.id).checkoutURL
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }

    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            let restored = try await client.restoreApplePurchases()
            show(restored.isEmpty ? "No restorable purchases found." : "Restored \(restored.count) purchase(s).")
        } catch {
            show(error.localizedDescription)
        }
    }

    private func appleOption(for plan: SubscriptionPlan) -> PurchaseOption? {
        plan.purchaseOptions.first { $0.provider == .appleAppStore && $0.flow == .storeKit }
    }

    private func show(_ message: String) {
        self.message = message
        showingMessage = true
    }
}

// MARK: - Preview

#Preview("Subscription Plans") {
    NavigationStack {
        SubscriptionPlanView(client: PreviewFixtures.client()) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "sparkles")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 82, height: 82)

                VStack(spacing: 8) {
                    Text("Plans that fit your work")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Start free and upgrade whenever you need more.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .navigationTitle("Subscriptions")
    }
}
