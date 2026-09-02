import SwiftUI

public struct BalanceHistoryView: View {
    @StateObject private var model: BalanceHistoryLoader

    public init(client: Client, unit: String? = nil) {
        _model = StateObject(wrappedValue: BalanceHistoryLoader(client: client, unit: unit))
    }

    public var body: some View {
        ScrollView {
            BalanceHistoryList(model: model)
                .padding(20)
        }
        .refreshable { await model.reload() }
        .task { if model.entries.isEmpty { await model.reload() } }
    }
}

#Preview("Balance History") {
    NavigationStack {
        BalanceHistoryView(client: PreviewFixtures.client())
            .navigationTitle("Balance History")
    }
}

// MARK: - Shared list

/// The ledger itself, without a scroll view of its own, so it can stand alone on the history
/// screen or sit underneath the cards on the balance screen.
struct BalanceHistoryList: View {
    @ObservedObject var model: BalanceHistoryLoader

    var body: some View {
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
                ForEach(model.groupedEntries, id: \.label) { group in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                BalanceHistoryRow(entry: entry, showTime: true)
                                    .padding(.horizontal, 18)
                                    .onAppear {
                                        guard entry.id == model.prefetchTriggerID else { return }
                                        Task { await model.loadNextPage() }
                                    }
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

                // Pages load themselves as the user nears the end. The footer only reports what
                // is happening, except after a failure: a page that failed must wait for a tap,
                // or an offline device would spin against the network forever.
                if model.hasMore {
                    Group {
                        if let error = model.error {
                            VStack(spacing: 10) {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                GlassButton("Try Again") {
                                    Task { await model.loadNextPage() }
                                }
                            }
                        } else {
                            // Safety net for the case where the trigger row scrolled past while a
                            // page was already in flight and never re-appeared.
                            ProgressView()
                                .controlSize(.small)
                                .onAppear { Task { await model.loadNextPage() } }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Loader

@MainActor
final class BalanceHistoryLoader: ObservableObject {
    @Published var entries: [LedgerEntry] = []
    @Published var isLoading = false
    @Published var error: String?

    let client: Client
    let unit: String?
    private var page = 0
    private var pageCount = 1
    /// Bumped by every reload so a page still in flight from the previous one lands nowhere.
    private var generation = 0

    var hasMore: Bool { page < pageCount }

    /// The row whose appearance pulls the next page. Kept a few rows short of the end so the
    /// request is already running by the time the user reaches the bottom.
    var prefetchTriggerID: String? {
        guard hasMore else { return nil }
        return entries.suffix(Self.prefetchDistance).first?.id
    }

    private static let prefetchDistance = 4

    init(client: Client, unit: String?) {
        self.client = client
        self.unit = unit
    }

    func reload() async {
        generation += 1
        page = 0
        pageCount = 1
        entries = []
        error = nil
        // Abandon rather than await: pull-to-refresh should not queue behind a page request that
        // may still be waiting on a slow network.
        isLoading = false
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        let token = generation
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false } }
        do {
            let next = try await client.ledger(unit: unit, page: page + 1)
            guard token == generation else { return }
            entries.append(contentsOf: next.entries)
            page = next.page
            pageCount = next.pageCount
        } catch {
            guard token == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Entries bucketed by calendar day, newest bucket first, in the order the server returned them.
    var groupedEntries: [(label: String, entries: [LedgerEntry])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var result: [(label: String, entries: [LedgerEntry])] = []
        var labelToIndex: [String: Int] = [:]

        for entry in entries {
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
