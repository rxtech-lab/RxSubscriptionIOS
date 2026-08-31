import SwiftUI

public struct TopUpView<Header: View>: View {
    @StateObject private var model: TopUpViewModel
    @Environment(\.openURL) private var openURL
    private let header: Header

    public init(client: Client, @ViewBuilder header: () -> Header) {
        _model = StateObject(wrappedValue: TopUpViewModel(client: client))
        self.header = header()
    }

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    content
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await model.load(force: true) }
            .task { await model.load() }
            .alert("Top Up", isPresented: $model.showingMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }

            if model.processingID != nil {
                busyOverlay
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.topUps.isEmpty {
            LoadingView(title: "Loading top-ups…")
        } else if let error = model.error, model.topUps.isEmpty {
            InlineErrorView(message: error) { Task { await model.load(force: true) } }
        } else if model.topUps.isEmpty {
            EmptyStateView(
                icon: "plus.circle",
                title: "No top-ups available",
                message: "Eligible balance packs will appear here."
            )
        } else {
            topUpList
        }
    }

    private var topUpList: some View {
        let eligible = model.topUps.filter { $0.eligible != false }
        let ineligible = model.topUps.filter { $0.eligible == false }

        return VStack(spacing: 24) {
            if !eligible.isEmpty {
                topUpSection(title: "Available", items: eligible)
            }
            if !ineligible.isEmpty {
                topUpSection(title: "Not Available", items: ineligible)
            }
        }
    }

    private func topUpSection(title: String, items: [TopUpProduct]) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(items) { topUp in
                topUpCard(topUp)
            }
        }
    }

    private func topUpCard(_ topUp: TopUpProduct) -> some View {
        let isEligible = topUp.eligible != false
        let isProcessing = model.processingID == topUp.id

        return HStack(alignment: .center, spacing: 14) {
            // Amount badge
            VStack(spacing: 3) {
                Text(topUp.amount.formatted())
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(isEligible ? Color.accentColor : Color.secondary)
                Text(topUp.unit ?? "units")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            .frame(width: 68)
            .padding(.vertical, 14)
            .tintedRect(isEligible ? Color.accentColor : Color.gray, cornerRadius: 12)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(topUp.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let description = topUp.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isEligible {
                    Label(eligibilityText(for: topUp), systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            // Price + buy
            VStack(alignment: .trailing, spacing: 8) {
                Text(model.price(for: topUp))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)

                Button {
                    Task {
                        if let url = await model.purchase(topUp) { openURL(url) }
                    }
                } label: {
                    Group {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Buy").font(.footnote.weight(.semibold))
                        }
                    }
                    .frame(width: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isProcessing || !isEligible || model.processingID != nil)
            }
        }
        .padding(16)
        .cardGlass(cornerRadius: 16)
        .opacity(isEligible ? 1 : 0.55)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Completing purchase…")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func eligibilityText(for topUp: TopUpProduct) -> String {
        let rules = topUp.blockedBy?.map(\.ruleType) ?? []
        if rules.contains("purchase_limit") { return "Purchase limit reached" }
        if rules.contains("requires_role") { return "Membership required" }
        if rules.contains("requires_active_plan") { return "Specific plan required" }
        if rules.contains("requires_any_plan") { return "Active plan required" }
        return "Not currently eligible"
    }
}

public extension TopUpView where Header == EmptyView {
    init(client: Client) {
        self.init(client: client) { EmptyView() }
    }
}

// MARK: - View Model

@MainActor
private final class TopUpViewModel: ObservableObject {
    @Published var topUps: [TopUpProduct] = []
    @Published var products: [String: StoreProductInfo] = [:]
    @Published var isLoading = false
    @Published var processingID: String?
    @Published var error: String?
    @Published var message: String?
    @Published var showingMessage = false

    let client: Client

    init(client: Client) { self.client = client }

    func load(force: Bool = false) async {
        guard force || topUps.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let catalog = try await client.catalog()
            topUps = catalog.topups
            let ids = catalog.topups.flatMap(\.purchaseOptions).compactMap { option in
                option.provider == .appleAppStore ? option.productID : nil
            }
            let loaded = ids.isEmpty ? [] : try await client.storeProducts(productIDs: ids)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        } catch {
            self.error = error.localizedDescription
        }
    }

    func price(for topUp: TopUpProduct) -> String {
        if let id = appleOption(for: topUp)?.productID, let product = products[id] {
            return product.displayPrice
        }
        return SubscriptionFormatting.price(cents: topUp.priceAmountCents, currency: topUp.currency)
    }

    func purchase(_ topUp: TopUpProduct) async -> URL? {
        guard topUp.eligible != false else { return nil }
        processingID = topUp.id
        defer { processingID = nil }
        do {
            if let productID = appleOption(for: topUp)?.productID {
                let outcome = try await client.purchaseApple(productID: productID)
                switch outcome {
                case .completed:
                    show("Balance added successfully.")
                    await load(force: true)
                case .pending:
                    show("The purchase is pending approval.")
                case .cancelled:
                    break
                }
                return nil
            }
            return try await client.checkoutTopUp(id: topUp.id).checkoutURL
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }

    private func appleOption(for topUp: TopUpProduct) -> PurchaseOption? {
        topUp.purchaseOptions.first { $0.provider == .appleAppStore && $0.flow == .storeKit }
    }

    private func show(_ message: String) {
        self.message = message
        showingMessage = true
    }
}

// MARK: - Preview

#Preview("Top-ups") {
    NavigationStack {
        TopUpView(client: PreviewFixtures.client()) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 82, height: 82)

                VStack(spacing: 8) {
                    Text("Need a little more?")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Top up your balance without changing your plan.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .navigationTitle("Top-ups")
    }
}
