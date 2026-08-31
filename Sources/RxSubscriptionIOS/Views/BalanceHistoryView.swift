import SwiftUI

public struct BalanceHistoryView: View {
    @StateObject private var model: BalanceHistoryViewModel

    public init(client: Client, unit: String? = nil) {
        _model = StateObject(wrappedValue: BalanceHistoryViewModel(client: client, unit: unit))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                if model.isLoading && model.entries.isEmpty {
                    LoadingView(title: "Loading history…")
                } else if let error = model.error, model.entries.isEmpty {
                    InlineErrorView(message: error) { Task { await model.reload() } }
                } else if model.entries.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No balance history",
                        message: "Credits and usage will appear here."
                    )
                } else {
                    ForEach(groupedEntries, id: \.label) { group in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    BalanceHistoryRow(entry: entry, showTime: true)
                                        .padding(.horizontal, 18)
                                    if index < group.entries.count - 1 {
                                        Divider().padding(.leading, 74)
                                    }
                                }
                            }
                            .cardGlass(cornerRadius: 20)
                        } header: {
                            Text(group.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if model.hasMore {
                        GlassButton(
                            model.isLoading ? "Loading…" : "Load More",
                            isDisabled: model.isLoading
                        ) {
                            Task { await model.loadNextPage() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await model.reload() }
        .task { if model.entries.isEmpty { await model.reload() } }
    }

    private var groupedEntries: [(label: String, entries: [LedgerEntry])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var result: [(label: String, entries: [LedgerEntry])] = []
        var labelToIndex: [String: Int] = [:]

        for entry in model.entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            let label: String
            if day == today {
                label = "Today"
            } else if day == yesterday {
                label = "Yesterday"
            } else {
                label = formatter.string(from: day)
            }

            if let idx = labelToIndex[label] {
                result[idx].entries.append(entry)
            } else {
                labelToIndex[label] = result.count
                result.append((label: label, entries: [entry]))
            }
        }
        return result
    }
}

#Preview("Balance History") {
    NavigationStack {
        BalanceHistoryView(client: PreviewFixtures.client())
            .navigationTitle("Balance History")
    }
}

@MainActor
private final class BalanceHistoryViewModel: ObservableObject {
    @Published var entries: [LedgerEntry] = []
    @Published var isLoading = false
    @Published var error: String?

    let client: Client
    let unit: String?
    private var page = 0
    private var pageCount = 1
    var hasMore: Bool { page < pageCount }

    init(client: Client, unit: String?) {
        self.client = client
        self.unit = unit
    }

    func reload() async {
        page = 0
        pageCount = 1
        entries = []
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !isLoading, page < pageCount else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let next = try await client.ledger(unit: unit, page: page + 1)
            entries.append(contentsOf: next.entries)
            page = next.page
            pageCount = next.pageCount
        } catch {
            self.error = error.localizedDescription
        }
    }
}
