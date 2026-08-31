import SwiftUI

public struct UsageView: View {
    @StateObject private var model: UsageViewModel

    public init(client: Client) {
        _model = StateObject(wrappedValue: UsageViewModel(client: client))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.isLoading && model.items.isEmpty {
                    LoadingView(title: "Loading usage…")
                } else if let error = model.error, model.items.isEmpty {
                    InlineErrorView(message: error) { Task { await model.load() } }
                } else if model.items.isEmpty {
                    EmptyStateView(
                        icon: "gauge.with.dots.needle.33percent",
                        title: "No usage meters",
                        message: "Usage allowances will appear here when configured."
                    )
                } else {
                    // Group all rows in a single card with internal dividers
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            UsageItemRow(item: item)
                                .padding(.horizontal, 20)
                            if index < model.items.count - 1 {
                                Divider().padding(.horizontal, 20)
                            }
                        }
                    }
                    .cardGlass(cornerRadius: 20)
                }
            }
            .padding(20)
        }
        .refreshable { await model.load() }
        .task { if model.items.isEmpty { await model.load() } }
    }
}

#Preview("Usage") {
    NavigationStack {
        UsageView(client: PreviewFixtures.client())
            .navigationTitle("Usage")
    }
}

@MainActor
private final class UsageViewModel: ObservableObject {
    @Published var items: [UsageStatus] = []
    @Published var isLoading = false
    @Published var error: String?

    let client: Client

    init(client: Client) { self.client = client }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { items = try await client.usage() }
        catch { self.error = error.localizedDescription }
    }
}
