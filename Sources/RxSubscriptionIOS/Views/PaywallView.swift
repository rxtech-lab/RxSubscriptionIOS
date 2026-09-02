import SwiftUI

public enum PaywallSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case plans
    case topUps
    case usage
    case balances
    case balanceHistory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plans: return "Plans"
        case .topUps: return "Top-ups"
        case .usage: return "Usage"
        case .balances: return "Balance"
        case .balanceHistory: return "History"
        }
    }
}

#Preview("Complete Paywall") {
    PaywallView(
        client: PreviewFixtures.client(),
        sections: [.plans, .topUps, .usage, .balances, .balanceHistory]
    ) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unlock more with Pro")
                .font(.largeTitle.bold())
            Text("Manage your plan, usage, and balance in one place.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A configurable subscription surface.
///
/// `.local` preserves the package's section-based screens and optional host
/// header. `.server` renders the complete published tree returned by the
/// backend, so `sections`, `initialSection`, and `header` do not apply.
public struct PaywallView<Header: View>: View {
    private let client: Client
    private let paywall: PaywallSource
    private let sections: [PaywallSection]
    private let header: Header
    @State private var selection: PaywallSection

    public init(
        client: Client,
        paywall: PaywallSource = .local,
        sections: [PaywallSection] = [.plans, .topUps],
        initialSection: PaywallSection? = nil,
        @ViewBuilder header: () -> Header
    ) {
        var seen = Set<PaywallSection>()
        let unique = sections.filter { seen.insert($0).inserted }
        let available = unique.isEmpty ? [.plans] : unique
        self.client = client
        self.paywall = paywall
        self.sections = available
        self.header = header()
        _selection = State(initialValue: initialSection.flatMap { available.contains($0) ? $0 : nil } ?? available[0])
    }

    public var body: some View {
        switch paywall {
        case .local:
            localPaywall
        case .server:
            ServerPaywallView(client: client)
        }
    }

    private var localPaywall: some View {
        VStack(spacing: 0) {
            // Header
            if !(header is EmptyView) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, sections.count > 1 ? 12 : 16)
            }

            // Section picker
            if sections.count > 1 {
                Picker("Section", selection: $selection) {
                    ForEach(sections) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

                Divider()
            }

            // Section content
            switch selection {
            case .plans:
                SubscriptionPlanView(client: client)
            case .topUps:
                TopUpView(client: client)
            case .usage:
                UsageView(client: client)
            case .balances:
                BalanceView(client: client)
            case .balanceHistory:
                BalanceHistoryView(client: client)
            }
        }
    }
}

public extension PaywallView where Header == EmptyView {
    init(
        client: Client,
        paywall: PaywallSource = .local,
        sections: [PaywallSection] = [.plans, .topUps],
        initialSection: PaywallSection? = nil
    ) {
        self.init(client: client, paywall: paywall, sections: sections, initialSection: initialSection) {
            EmptyView()
        }
    }
}
