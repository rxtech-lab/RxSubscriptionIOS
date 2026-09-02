import SwiftUI

/// What the user has, and where it went.
///
/// The cards answer "how much is left"; the ledger underneath answers "what spent it", which is the
/// question a balance actually raises. Both load independently so a failing ledger still shows a
/// balance, and vice versa.
public struct BalanceView: View {
    @StateObject private var model: BalanceViewModel
    @StateObject private var history: BalanceHistoryLoader

    public init(client: Client, unit: String? = nil) {
        _model = StateObject(wrappedValue: BalanceViewModel(client: client))
        _history = StateObject(wrappedValue: BalanceHistoryLoader(client: client, unit: unit))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                balances

                if showsHistory {
                    Text("Activity")
                        .font(.headline)
                        .padding(.horizontal, 4)

                    BalanceHistoryList(model: history)
                }
            }
            .padding(20)
        }
        .refreshable { await load() }
        .task {
            if model.balances.isEmpty && history.entries.isEmpty { await load() }
        }
    }

    @ViewBuilder
    private var balances: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 145), spacing: 12)],
            spacing: 12
        ) {
            if model.isLoading && model.balances.isEmpty {
                LoadingView(title: "Loading balances…")
            } else if let error = model.error, model.balances.isEmpty {
                InlineErrorView(message: error) { Task { await model.load() } }
            } else if model.balances.isEmpty {
                EmptyStateView(
                    icon: "creditcard",
                    title: "No balances",
                    message: "Available units will appear here."
                )
            } else {
                ForEach(model.balances) { BalanceCard(balance: $0) }
            }
        }
    }

    /// A user with nothing at all gets one empty state, not two stacked on top of each other.
    private var showsHistory: Bool {
        !model.balances.isEmpty
            || !history.entries.isEmpty
            || history.isLoading
            || history.error != nil
    }

    private func load() async {
        async let balances: Void = model.load()
        async let ledger: Void = history.reload()
        _ = await (balances, ledger)
    }
}

#Preview("Balances") {
    NavigationStack {
        BalanceView(client: PreviewFixtures.client())
            .navigationTitle("Balances")
    }
}

@MainActor
final class BalanceViewModel: ObservableObject {
    @Published var balances: [Balance] = []
    @Published var isLoading = false
    @Published var error: String?

    let client: Client
    init(client: Client) { self.client = client }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { balances = try await client.balances() }
        catch { self.error = error.localizedDescription }
    }
}
