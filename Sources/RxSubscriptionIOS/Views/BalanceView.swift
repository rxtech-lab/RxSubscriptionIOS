import SwiftUI

public struct BalanceView: View {
    @StateObject private var model: BalanceViewModel

    public init(client: Client) {
        _model = StateObject(wrappedValue: BalanceViewModel(client: client))
    }

    public var body: some View {
        ScrollView {
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
            .padding(20)
        }
        .refreshable { await model.load() }
        .task { if model.balances.isEmpty { await model.load() } }
    }
}

#Preview("Balances") {
    NavigationStack {
        BalanceView(client: PreviewFixtures.client())
            .navigationTitle("Balances")
    }
}

@MainActor
private final class BalanceViewModel: ObservableObject {
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
