import SwiftUI

/// Loads and renders the published native-view tree from RxSubscription.
struct ServerPaywallView: View {
    @StateObject private var model: ServerPaywallViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(client: Client) {
        _model = StateObject(wrappedValue: ServerPaywallViewModel(client: client))
    }

    var body: some View {
        ZStack {
            content

            if model.isBusy {
                busyOverlay
            }
        }
        .task { await model.load() }
        .alert("Purchase", isPresented: $model.showingMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .preferredColorScheme(model.document?.spec.theme.preferredColorScheme)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.document == nil {
            LoadingView(title: "Loading paywall…")
        } else if let error = model.error, model.document == nil {
            InlineErrorView(message: error) {
                Task { await model.load(force: true) }
            }
        } else if let document = model.document {
            ServerPaywallRenderer(spec: document.spec, model: model, action: perform)
                .refreshable { await model.load(force: true) }
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(model.isRestoring ? "Restoring purchases…" : "Completing purchase…")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func perform(_ action: PaywallAction) {
        switch action {
        case .selectProduct(let productID):
            model.selectProduct(productID)
        case .openURL(let url):
            openURL(url)
        case .dismiss:
            dismiss()
        case .restorePurchases:
            Task { await model.restorePurchases() }
        case .purchase(let productID):
            Task {
                if let url = await model.purchase(productID: productID) {
                    openURL(url)
                }
            }
        }
    }
}

@MainActor
private final class ServerPaywallViewModel: ObservableObject {
    @Published private(set) var document: PaywallDocument?
    @Published private(set) var selectedProductID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoring = false
    @Published private(set) var processingID: String?
    @Published var error: String?
    @Published var message: String?
    @Published var showingMessage = false

    private let client: Client
    private var products: [PaywallProduct] = []

    var isBusy: Bool { isRestoring || processingID != nil }

    init(client: Client) {
        self.client = client
    }

    func load(force: Bool = false) async {
        guard force || document == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let document = try await client.paywall()
            guard document.spec.version == 1 else {
                throw ClientError.invalidConfiguration(
                    "Unsupported paywall specification version: \(document.spec.version)."
                )
            }
            self.document = document
            products = Self.products(in: document.spec.root)

            if let selectedProductID,
               products.contains(where: { $0.id == selectedProductID }) {
                return
            }
            self.selectedProductID = Self.highlightedProductID(in: document.spec.root)
                ?? products.first?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectProduct(_ productID: String) {
        guard products.contains(where: { $0.id == productID }) else { return }
        selectedProductID = productID
    }

    func purchase(productID: String?) async -> URL? {
        let requested = productID ?? selectedProductID
        guard let requested,
              let product = products.first(where: { $0.id == requested || $0.key == requested })
        else {
            show("Choose a plan before continuing.")
            return nil
        }

        processingID = product.id
        defer { processingID = nil }

        do {
            if let option = product.purchaseOptions.first(where: {
                $0.provider == .appleAppStore && $0.flow == .storeKit && $0.productID != nil
            }), let storeProductID = option.productID {
                switch try await client.purchaseApple(productID: storeProductID) {
                case .completed:
                    show("Purchase fulfilled successfully.")
                case .pending:
                    show("The purchase is pending approval.")
                case .cancelled:
                    break
                }
                return nil
            }
            return try await client.checkoutPlan(id: product.id).checkoutURL
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            let restored = try await client.restoreApplePurchases()
            show(restored.isEmpty
                ? "No restorable purchases found."
                : "Restored \(restored.count) purchase(s).")
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ message: String) {
        self.message = message
        showingMessage = true
    }

    private static func products(in node: PaywallNode) -> [PaywallProduct] {
        var result: [PaywallProduct] = []
        var seen = Set<String>()

        func visit(_ node: PaywallNode) {
            for product in node.products ?? [] where seen.insert(product.id).inserted {
                result.append(product)
            }
            node.children?.forEach(visit)
        }
        visit(node)
        return result
    }

    /// The plan the design wants preselected.
    ///
    /// A `TabView` is searched through the tab it opens on only: the plans on
    /// the other tabs are still purchasable, but preselecting one of them
    /// would put Continue on a card the buyer cannot see.
    static func highlightedProductID(in node: PaywallNode) -> String? {
        if let highlightedProductID = node.highlightedProductID {
            return highlightedProductID
        }
        let children = node.children ?? []
        if node.type == "TabView" {
            let opening = min(max(node.int("selectedIndex") ?? 0, 0), max(children.count - 1, 0))
            guard children.indices.contains(opening) else { return nil }
            return highlightedProductID(in: children[opening])
        }
        for child in children {
            if let highlightedProductID = highlightedProductID(in: child) {
                return highlightedProductID
            }
        }
        return nil
    }
}

private struct ServerPaywallRenderer: View {
    let spec: PaywallSpec
    @ObservedObject var model: ServerPaywallViewModel
    let action: (PaywallAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PaywallNodeView(
            node: spec.root,
            theme: spec.theme,
            parentAxis: .column,
            model: model,
            action: action
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(spec.theme.color("background", in: colorScheme).ignoresSafeArea())
        .fontDesign(spec.theme.swiftUIFontDesign)
    }
}

private enum PaywallParentAxis {
    case column
    case row
    case stack
    case grid
}

private struct PaywallNodeView: View {
    let node: PaywallNode
    let theme: PaywallTheme
    let parentAxis: PaywallParentAxis
    @ObservedObject var model: ServerPaywallViewModel
    let action: (PaywallAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if node.modifiers?.hidden != true {
            applyModifiers(to: AnyView(nodeContent))
        }
    }

    @ViewBuilder
    private var nodeContent: some View {
        switch node.type {
        case "ScrollView":
            scrollView
        case "VStack":
            VStack(
                alignment: horizontalAlignment(node.string("alignment")),
                spacing: node.number("spacing") ?? 8
            ) {
                children(parentAxis: .column)
            }
            .frame(
                maxWidth: parentAxis == .column ? .infinity : nil,
                alignment: frameAlignment(node.string("alignment"))
            )
        case "HStack":
            HStack(
                alignment: verticalAlignment(node.string("alignment")),
                spacing: node.number("spacing") ?? 8
            ) {
                children(parentAxis: .row)
            }
            .frame(maxWidth: parentAxis == .column ? .infinity : nil)
        case "ZStack":
            ZStack(alignment: zStackAlignment(node.string("alignment"))) {
                children(parentAxis: .stack)
            }
            .frame(maxWidth: parentAxis == .column ? .infinity : nil)
        case "Grid":
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: node.number("spacing") ?? 8),
                    count: max(1, node.int("columns") ?? 2)
                ),
                spacing: node.number("spacing") ?? 8
            ) {
                children(parentAxis: .grid)
            }
            .frame(maxWidth: parentAxis == .column ? .infinity : nil)
        case "List":
            paywallList
        case "TabView":
            PaywallTabsView(
                node: node,
                theme: theme,
                parentAxis: parentAxis,
                model: model,
                action: action
            )
        case "Text":
            paywallText
        case "Image":
            paywallImage
        case "Button":
            paywallButton
        case "Spacer":
            Spacer(minLength: node.number("minLength") ?? 0)
        case "Divider":
            Divider().overlay(theme.color("muted", in: colorScheme).opacity(0.3))
        case "Badge":
            paywallBadge
        case "FeatureRow":
            featureRow
        case "Link":
            paywallLink
        case "ProductList":
            PaywallProductListView(node: node, theme: theme, model: model)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scrollView: some View {
        let horizontal = node.string("axis") == "horizontal"
        let showsIndicators = node.bool("showsIndicators") != false
        if horizontal {
            ScrollView(.horizontal, showsIndicators: showsIndicators) {
                LazyHStack(spacing: 0) { children(parentAxis: .row) }
            }
        } else {
            ScrollView(.vertical, showsIndicators: showsIndicators) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    children(parentAxis: .column)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var paywallList: some View {
        let children = node.children ?? []
        let spacing = node.number("spacing") ?? 8
        let showsSeparators = node.bool("showsSeparators") != false
        return VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                PaywallNodeView(
                    node: child,
                    theme: theme,
                    parentAxis: .column,
                    model: model,
                    action: action
                )
                .padding(.vertical, spacing / 2)
                if showsSeparators, index < children.count - 1 {
                    Divider().overlay(theme.color("muted", in: colorScheme).opacity(0.25))
                }
            }
        }
        .frame(maxWidth: parentAxis == .column ? .infinity : nil)
    }

    private var paywallText: some View {
        Text(node.string("text") ?? "")
            .font(textFont(node.string("style")))
            .fontWeight(textWeight(node.string("weight")))
            .foregroundStyle(theme.color(node.string("color"), in: colorScheme, fallback: "foreground"))
            .multilineTextAlignment(textAlignment(node.string("alignment")))
            .lineLimit(node.int("maxLines"))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var paywallImage: some View {
        let width = node.number("width") ?? (node.string("url") == nil ? 40 : 160)
        let height = node.number("height") ?? (node.string("url") == nil ? 40 : 120)
        let radius = node.number("cornerRadius") ?? 0
        if let urlString = node.string("url"), let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: node.string("contentMode") == "fill" ? .fill : .fit)
                case .failure:
                    Image(systemName: "photo")
                        .foregroundStyle(theme.color("muted", in: colorScheme))
                default:
                    ProgressView()
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            Image(systemName: node.string("systemName") ?? "photo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.color(node.string("tint"), in: colorScheme, fallback: "primary"))
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    private var paywallButton: some View {
        let style = node.string("style") ?? "filled"
        let color = theme.color(node.string("color"), in: colorScheme, fallback: "primary")
        let fullWidth = node.bool("fullWidth") == true
        let button = Button {
            if let declaredAction = node.action {
                action(declaredAction)
            }
        } label: {
            Group {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(node.string("label") ?? "")
                }
            }
            .font(style == "plain" ? .subheadline.weight(.semibold) : .headline)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, style == "plain" ? 8 : 20)
            .padding(.vertical, style == "plain" ? 6 : 13)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || node.action == nil)

        if style == "outlined" {
            button
                .foregroundStyle(color)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                        .stroke(color, lineWidth: 1.5)
                }
        } else if style == "plain" {
            button.foregroundStyle(color)
        } else {
            button
                .foregroundStyle(theme.readableColor(on: node.string("color") ?? "primary"))
                .background(color, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        }
    }

    private var paywallBadge: some View {
        let color = theme.color(node.string("color"), in: colorScheme, fallback: "accent")
        return Text(node.string("text") ?? "")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var featureRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.string("icon") ?? "checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.color("primary", in: colorScheme))
                .frame(width: 28, height: 28)
                .background(
                    theme.color("primary", in: colorScheme).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(node.string("title") ?? "")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.color("foreground", in: colorScheme))
                if let subtitle = node.string("subtitle") {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.color("muted", in: colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: parentAxis == .column ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private var paywallLink: some View {
        if let text = node.string("text"),
           let urlString = node.string("url"),
           let url = URL(string: urlString) {
            Link(text, destination: url)
                .font(.footnote)
                .foregroundStyle(theme.color("muted", in: colorScheme))
        }
    }

    @ViewBuilder
    private func children(parentAxis: PaywallParentAxis) -> some View {
        ForEach(node.children ?? []) { child in
            PaywallNodeView(
                node: child,
                theme: theme,
                parentAxis: parentAxis,
                model: model,
                action: action
            )
        }
    }

    private func applyModifiers(to view: AnyView) -> AnyView {
        guard let modifiers = node.modifiers else { return view }
        var result = view

        if let padding = modifiers.padding {
            switch padding {
            case .all(let value):
                result = AnyView(result.padding(value))
            case .edges(let edges):
                result = AnyView(result.padding(EdgeInsets(
                    top: edges.top ?? 0,
                    leading: edges.leading ?? 0,
                    bottom: edges.bottom ?? 0,
                    trailing: edges.trailing ?? 0
                )))
            }
        }
        if let frame = modifiers.frame {
            let width = frame.width.map { CGFloat($0) }
            let height = frame.height.map { CGFloat($0) }
            let maxWidth = frame.maxWidth.map { CGFloat($0) }
            let maxHeight = frame.maxHeight.map { CGFloat($0) }
            result = AnyView(result.frame(width: width, height: height))
            result = AnyView(result.frame(maxWidth: maxWidth, maxHeight: maxHeight))
        }
        if let background = modifiers.background {
            result = AnyView(result.background(theme.color(background, in: colorScheme)))
        }
        if let radius = modifiers.cornerRadius {
            result = AnyView(result.clipShape(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
            ))
        }
        if let border = modifiers.border {
            result = AnyView(result.overlay {
                RoundedRectangle(cornerRadius: modifiers.cornerRadius ?? 0, style: .continuous)
                    .stroke(theme.color(border.color, in: colorScheme), lineWidth: border.width)
            })
        }
        if let opacity = modifiers.opacity {
            result = AnyView(result.opacity(opacity))
        }
        return result
    }
}

/// One control in a tab bar or a period switcher.
private struct PaywallSegment: Identifiable, Hashable {
    let id: Int
    let title: String
    var icon: String?
    var badge: String?
}

/// The one control behind a `TabView`'s tab bar and a product list's period
/// switcher, so a paywall that uses both does not show two different pickers.
///
/// This is drawn by hand rather than with a segmented `Picker` because the
/// document decides the look — segmented, underline, pill, or chips — and
/// carries per-tab symbols and badges that a `Picker` has nowhere to put.
private struct PaywallSegmentedBar: View {
    let segments: [PaywallSegment]
    let selected: Int
    let style: String
    let tint: Color
    let barBackground: Color
    let mutedColor: Color
    let surfaceColor: Color
    let onTint: Color
    var alignment: String?
    let select: (Int) -> Void

    private var underline: Bool { style == "underline" }
    private var chips: Bool { style == "chips" }

    var body: some View {
        HStack(spacing: chips ? 8 : underline ? 4 : 2) {
            ForEach(segments) { segment in
                Button { select(segment.id) } label: { label(segment) }
                    .buttonStyle(.plain)
            }
        }
        .padding(underline || chips ? 0 : 3)
        .background(underline || chips ? Color.clear : barBackground)
        .clipShape(RoundedRectangle(cornerRadius: style == "pill" ? 999 : 10, style: .continuous))
        .overlay(alignment: .bottom) {
            if underline {
                Rectangle()
                    .fill(mutedColor.opacity(0.25))
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment(alignment ?? (chips ? "leading" : "center")))
    }

    @ViewBuilder
    private func label(_ segment: PaywallSegment) -> some View {
        let isSelected = segment.id == selected
        let filled = isSelected && (style == "pill" || chips)
        let foreground = filled ? onTint : (isSelected ? tint : mutedColor)

        HStack(spacing: 6) {
            if let icon = segment.icon, !icon.isEmpty {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            }
            Text(segment.title).lineLimit(1)
            if let badge = segment.badge, !badge.isEmpty {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(foreground.opacity(0.18), in: Capsule())
            }
        }
        .font(.subheadline.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, chips ? 14 : 10)
        .padding(.vertical, underline ? 8 : 7)
        .frame(maxWidth: chips ? nil : .infinity)
        .background(segmentBackground(isSelected: isSelected, filled: filled))
        .clipShape(RoundedRectangle(cornerRadius: style == "pill" || chips ? 999 : 8, style: .continuous))
        .overlay {
            if chips {
                Capsule().stroke(isSelected ? tint : mutedColor.opacity(0.4), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if underline {
                Rectangle()
                    .fill(isSelected ? tint : Color.clear)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
    }

    private func segmentBackground(isSelected: Bool, filled: Bool) -> Color {
        if filled { return tint }
        if isSelected, !underline, !chips { return surfaceColor }
        return .clear
    }
}

/// A tab bar over one child per tab.
///
/// Which tab is open is the viewer's business: the document only names the tab
/// the paywall opens on, so tapping another one is navigation, not an edit.
private struct PaywallTabsView: View {
    let node: PaywallNode
    let theme: PaywallTheme
    let parentAxis: PaywallParentAxis
    @ObservedObject var model: ServerPaywallViewModel
    let action: (PaywallAction) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var chosen: Int?

    private var pages: [PaywallNode] { node.children ?? [] }

    private var segments: [PaywallSegment] {
        node.tabs.enumerated().map { index, tab in
            PaywallSegment(
                id: index,
                title: tab.title.isEmpty ? "Tab \(index + 1)" : tab.title,
                icon: tab.icon,
                badge: tab.badge
            )
        }
    }

    private var index: Int {
        let last = max(segments.count - 1, 0)
        let opening = min(max(node.int("selectedIndex") ?? 0, 0), last)
        return min(chosen ?? opening, last)
    }

    var body: some View {
        VStack(spacing: node.number("spacing") ?? 12) {
            if !segments.isEmpty {
                PaywallSegmentedBar(
                    segments: segments,
                    selected: index,
                    style: node.string("style") ?? "segmented",
                    tint: theme.color(node.string("tint"), in: colorScheme, fallback: "primary"),
                    barBackground: node.string("barBackground").map {
                        theme.color($0, in: colorScheme)
                    } ?? theme.color("muted", in: colorScheme).opacity(0.14),
                    mutedColor: theme.color("muted", in: colorScheme),
                    surfaceColor: theme.color("background", in: colorScheme),
                    onTint: theme.readableColor(on: node.string("tint") ?? "primary"),
                    select: select
                )
            }
            if pages.indices.contains(index) {
                PaywallNodeView(
                    node: pages[index],
                    theme: theme,
                    parentAxis: .column,
                    model: model,
                    action: action
                )
            }
        }
        .frame(maxWidth: parentAxis == .column ? .infinity : nil)
    }

    /// Opening a tab moves the selection to the plan that tab pushes, so
    /// Continue buys what the buyer is looking at rather than a plan left
    /// selected on the tab they just left. A tab with no plans changes nothing.
    private func select(_ tab: Int) {
        chosen = tab
        guard pages.indices.contains(tab),
              let highlighted = ServerPaywallViewModel.highlightedProductID(in: pages[tab])
        else { return }
        model.selectProduct(highlighted)
    }
}

private struct PaywallProductListView: View {
    let node: PaywallNode
    let theme: PaywallTheme
    @ObservedObject var model: ServerPaywallViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var chosenPeriod: Int?

    private var periods: [PaywallPeriodOption] { node.periodOptions ?? [] }

    /// The period in play: the one the design opens on until the buyer picks
    /// another. The server already dropped periods with no plans, so an option
    /// here always has something to show.
    private var period: PaywallPeriodOption? {
        guard !periods.isEmpty else { return nil }
        let opening = max(periods.firstIndex(where: { $0.selected }) ?? 0, 0)
        return periods[min(chosenPeriod ?? opening, periods.count - 1)]
    }

    var body: some View {
        let spacing = node.number("spacing") ?? 10
        let horizontal = node.string("layout") == "horizontal"
        let period = period
        let products = (node.products ?? []).filter { product in
            period.map { $0.productIDs.contains(product.id) } ?? true
        }

        VStack(spacing: 12) {
            if let period {
                periodSwitcher(selected: period)
            }
            list(products: products, spacing: spacing, horizontal: horizontal)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func periodSwitcher(selected: PaywallPeriodOption) -> some View {
        let filter = node.object("periodFilter")
        PaywallSegmentedBar(
            segments: periods.enumerated().map { index, option in
                PaywallSegment(id: index, title: option.label)
            },
            selected: periods.firstIndex(of: selected) ?? 0,
            style: filter?.string("style") ?? "segmented",
            tint: theme.color(node.string("highlightColor"), in: colorScheme, fallback: "primary"),
            barBackground: theme.color("muted", in: colorScheme).opacity(0.14),
            mutedColor: theme.color("muted", in: colorScheme),
            surfaceColor: theme.color("background", in: colorScheme),
            onTint: theme.readableColor(on: node.string("highlightColor") ?? "primary"),
            alignment: filter?.string("alignment"),
            select: { index in
                chosenPeriod = index
                // The plan to push is not the same one from one period to the
                // next, so switching moves the selection with it — otherwise
                // Continue would buy a plan that is no longer on screen.
                if let highlighted = periods[index].highlightedProductID {
                    model.selectProduct(highlighted)
                }
            }
        )
    }

    @ViewBuilder
    private func list(products: [PaywallProduct], spacing: Double, horizontal: Bool) -> some View {
        Group {
            if products.isEmpty {
                Text("No plans are available right now.")
                    .font(.footnote)
                    .foregroundStyle(theme.color("muted", in: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .overlay {
                        RoundedRectangle(cornerRadius: node.number("cornerRadius") ?? theme.cornerRadius)
                            .stroke(
                                theme.color("muted", in: colorScheme).opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [5])
                            )
                    }
            } else if horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        productCards(products, horizontal: true)
                    }
                    .padding(.bottom, 4)
                }
            } else {
                VStack(spacing: spacing) {
                    productCards(products, horizontal: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func productCards(_ products: [PaywallProduct], horizontal: Bool) -> some View {
        ForEach(products) { product in
            PaywallProductCard(
                product: product,
                selected: model.selectedProductID == product.id,
                compact: node.string("style") == "row",
                horizontal: horizontal,
                style: PaywallProductCardStyle(node: node, theme: theme, colorScheme: colorScheme)
            ) {
                model.selectProduct(product.id)
            }
        }
    }
}

private struct PaywallProductCardStyle {
    let radius: Double
    let borderWidth: Double
    let cardBackground: Color
    let cardBorder: Color
    let highlightColor: Color
    let highlightBackground: Color
    let nameColor: Color
    let priceColor: Color
    let detailColor: Color
    let showDescription: Bool
    let showPeriod: Bool
    let showSelector: Bool
    let showTrial: Bool
    let showSavings: Bool

    init(node: PaywallNode, theme: PaywallTheme, colorScheme: ColorScheme) {
        radius = node.number("cornerRadius") ?? theme.cornerRadius
        borderWidth = node.number("borderWidth") ?? 1
        highlightColor = theme.color(node.string("highlightColor"), in: colorScheme, fallback: "primary")
        cardBackground = node.string("cardBackground").map {
            theme.color($0, in: colorScheme)
        } ?? .clear
        cardBorder = node.string("cardBorderColor").map {
            theme.color($0, in: colorScheme)
        } ?? theme.color("muted", in: colorScheme).opacity(0.35)
        highlightBackground = node.string("highlightBackground").map {
            theme.color($0, in: colorScheme)
        } ?? highlightColor.opacity(0.08)
        nameColor = theme.color(node.string("nameColor"), in: colorScheme, fallback: "foreground")
        priceColor = theme.color(node.string("priceColor"), in: colorScheme, fallback: "foreground")
        detailColor = theme.color(node.string("detailColor"), in: colorScheme, fallback: "muted")
        showDescription = node.bool("showDescription") != false
        showPeriod = node.bool("showPeriod") != false
        showSelector = node.bool("showSelector") != false
        showTrial = node.bool("showTrialBadge") == true
        showSavings = node.bool("showSavings") == true
    }
}

private struct PaywallProductCard: View {
    let product: PaywallProduct
    let selected: Bool
    let compact: Bool
    let horizontal: Bool
    let style: PaywallProductCardStyle
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            if compact {
                compactCard
            } else {
                regularCard
            }
        }
        .buttonStyle(.plain)
    }

    private var compactCard: some View {
        HStack(spacing: 12) {
            if style.showSelector {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? style.highlightColor : style.detailColor.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.nameColor)
                if !badges.isEmpty {
                    Text(badges.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? style.highlightColor : style.detailColor)
                } else if style.showDescription, let description = product.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(style.detailColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(product.priceLabel)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(style.priceColor)
                if style.showPeriod {
                    Text(product.periodLabel)
                        .font(.caption)
                        .foregroundStyle(style.detailColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: horizontal ? 220 : nil)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .background(selected ? style.highlightBackground : style.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: style.radius, style: .continuous))
        .overlay(cardBorder)
    }

    private var regularCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(selected ? style.highlightColor : style.detailColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                (selected ? style.highlightColor : style.detailColor).opacity(0.16),
                                in: Capsule()
                            )
                    }
                }
            }
            Text(product.name)
                .font(.headline)
                .foregroundStyle(style.nameColor)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(product.priceLabel)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(style.priceColor)
                if style.showPeriod {
                    Text(product.periodLabel)
                        .font(.footnote)
                        .foregroundStyle(style.detailColor)
                }
            }
            if style.showDescription, let description = product.description {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(style.detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(minWidth: horizontal ? 180 : nil)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .background(selected ? style.highlightBackground : style.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: style.radius, style: .continuous))
        .overlay(cardBorder)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: style.radius, style: .continuous)
            .stroke(
                selected ? style.highlightColor : style.cardBorder,
                lineWidth: selected ? style.borderWidth + 1 : style.borderWidth
            )
    }

    private var badges: [String] {
        [
            product.badge,
            style.showTrial && product.trialDays > 0
                ? "\(product.trialDays)-day free trial"
                : nil,
            style.showSavings ? product.savingsLabel : nil,
        ].compactMap { $0 }
    }
}

private extension PaywallNode {
    func string(_ key: String) -> String? {
        guard case .string(let value) = props[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value) = props[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        number(key).map(Int.init)
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = props[key] else { return nil }
        return value
    }

    /// A nested prop object, such as a product list's `periodFilter`.
    func object(_ key: String) -> [String: JSONValue]? {
        guard case .object(let value) = props[key] else { return nil }
        return value
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }
}

private extension PaywallTheme {
    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var swiftUIFontDesign: Font.Design? {
        switch fontDesign {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    func color(
        _ value: String?,
        in environment: ColorScheme,
        fallback: String = "foreground"
    ) -> Color {
        let name = value ?? fallback
        let resolved: String
        if name.hasPrefix("#") {
            resolved = name
        } else if colorScheme == "system", environment == .dark {
            switch name {
            case "background": resolved = "#0B0F1A"
            case "foreground": resolved = "#F8FAFC"
            case "muted": resolved = "#94A3B8"
            default: resolved = token(name) ?? token(fallback) ?? "#0F172A"
            }
        } else {
            resolved = token(name) ?? token(fallback) ?? "#0F172A"
        }
        return Color(paywallHex: resolved)
    }

    func readableColor(on value: String) -> Color {
        let resolved = value.hasPrefix("#") ? value : (token(value) ?? colors.primary)
        guard let components = resolved.paywallRGBA else { return .white }
        let luminance = 0.2126 * components.red
            + 0.7152 * components.green
            + 0.0722 * components.blue
        return luminance > 0.6 ? Color(paywallHex: "#0F172A") : .white
    }

    private func token(_ name: String) -> String? {
        switch name {
        case "primary": return colors.primary
        case "background": return colors.background
        case "foreground": return colors.foreground
        case "muted": return colors.muted
        case "accent": return colors.accent
        case "success": return "#16A34A"
        case "warning": return "#D97706"
        case "danger": return "#DC2626"
        default: return nil
        }
    }
}

private extension String {
    var paywallRGBA: (red: Double, green: Double, blue: Double, alpha: Double)? {
        let value = hasPrefix("#") ? String(dropFirst()) : self
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16)
        else { return nil }

        if value.count == 8 {
            return (
                Double((number >> 24) & 0xff) / 255,
                Double((number >> 16) & 0xff) / 255,
                Double((number >> 8) & 0xff) / 255,
                Double(number & 0xff) / 255
            )
        }
        return (
            Double((number >> 16) & 0xff) / 255,
            Double((number >> 8) & 0xff) / 255,
            Double(number & 0xff) / 255,
            1
        )
    }
}

private extension Color {
    init(paywallHex: String) {
        guard let value = paywallHex.paywallRGBA else {
            self = .primary
            return
        }
        self.init(
            .sRGB,
            red: value.red,
            green: value.green,
            blue: value.blue,
            opacity: value.alpha
        )
    }
}

private func horizontalAlignment(_ value: String?) -> HorizontalAlignment {
    switch value {
    case "leading": return .leading
    case "trailing": return .trailing
    default: return .center
    }
}

private func verticalAlignment(_ value: String?) -> VerticalAlignment {
    switch value {
    case "top": return .top
    case "bottom": return .bottom
    default: return .center
    }
}

private func frameAlignment(_ value: String?) -> Alignment {
    switch value {
    case "leading": return .leading
    case "trailing": return .trailing
    default: return .center
    }
}

private func zStackAlignment(_ value: String?) -> Alignment {
    switch value {
    case "topLeading": return .topLeading
    case "top": return .top
    case "topTrailing": return .topTrailing
    case "leading": return .leading
    case "trailing": return .trailing
    case "bottomLeading": return .bottomLeading
    case "bottom": return .bottom
    case "bottomTrailing": return .bottomTrailing
    default: return .center
    }
}

private func textAlignment(_ value: String?) -> TextAlignment {
    switch value {
    case "center": return .center
    case "trailing": return .trailing
    default: return .leading
    }
}

private func textFont(_ value: String?) -> Font {
    switch value {
    case "largeTitle": return .largeTitle
    case "title": return .title
    case "title2": return .title2
    case "title3": return .title3
    case "headline": return .headline
    case "callout": return .callout
    case "subheadline": return .subheadline
    case "footnote": return .footnote
    case "caption": return .caption
    default: return .body
    }
}

private func textWeight(_ value: String?) -> Font.Weight? {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return nil
    }
}
