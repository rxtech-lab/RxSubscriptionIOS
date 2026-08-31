import SwiftUI

// MARK: - Formatting

public enum SubscriptionFormatting {
    public static func price(cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        return formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? "\(currency.uppercased()) \(Double(cents) / 100)"
    }

    public static func balance(_ amount: Int, precision: Int, symbol: String? = nil) -> String {
        let divisor = pow(10.0, Double(precision))
        let value = Double(amount) / divisor
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, precision)
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return [symbol, number].compactMap { $0 }.joined(separator: symbol == nil ? "" : " ")
    }
}

// MARK: - Design Helpers (Liquid Glass on iOS 26+, material fallback on older)

extension View {
    /// Card background: Liquid Glass on iOS 26+, regularMaterial otherwise.
    @ViewBuilder
    func cardGlass(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
        }
    }

    /// Capsule badge with tinted glass on iOS 26+, tinted opacity fill otherwise.
    @ViewBuilder
    func tintedCapsule(_ color: Color) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(color), in: .capsule)
        } else {
            self.background(color.opacity(0.15), in: Capsule())
        }
    }

    /// Rounded-rect badge with tinted glass on iOS 26+, tinted opacity fill otherwise.
    @ViewBuilder
    func tintedRect(_ color: Color, cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(color), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

/// Secondary-action button: Glass style on iOS 26+, bordered otherwise.
struct GlassButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    init(_ title: String, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        if #available(iOS 26, *) {
            Button(title, action: action)
                .buttonStyle(.glass)
                .disabled(isDisabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .disabled(isDisabled)
        }
    }
}

// MARK: - Subscription Plan Card

public struct SubscriptionPlanCard: View {
    public let plan: SubscriptionPlan
    public let price: String
    public let actionTitle: String
    public let isLoading: Bool
    public let action: () -> Void

    public init(
        plan: SubscriptionPlan,
        price: String,
        actionTitle: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.plan = plan
        self.price = price
        self.actionTitle = actionTitle
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Info section
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name)
                            .font(.title3.weight(.bold))
                        Text(intervalText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(price)
                            .font(.title2.weight(.bold).monospacedDigit())
                        if plan.billingInterval != "one_time" {
                            Text("/ \(plan.billingInterval)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let description = plan.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if plan.trialDays > 0 {
                    Label("\(plan.trialDays)-day free trial", systemImage: "gift.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Action section
            Button(action: action) {
                Group {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Processing…")
                        }
                    } else {
                        Text(actionTitle)
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .cardGlass(cornerRadius: 20)
    }

    private var intervalText: String {
        if plan.billingInterval == "one_time" { return "One-time purchase" }
        let count = plan.intervalCount
        let interval = count == 1 ? plan.billingInterval : "\(plan.billingInterval)s"
        return count == 1 ? "Billed every \(interval)" : "Billed every \(count) \(interval)"
    }
}

// MARK: - Top-up Card

public struct TopUpCard: View {
    public let topUp: TopUpProduct
    public let price: String
    public let isLoading: Bool
    public let action: () -> Void

    public init(
        topUp: TopUpProduct,
        price: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.topUp = topUp
        self.price = price
        self.isLoading = isLoading
        self.action = action
    }

    private var isEligible: Bool { topUp.eligible != false }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
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
            .frame(width: 70)
            .padding(.vertical, 14)
            .tintedRect(isEligible ? Color.accentColor : Color.gray, cornerRadius: 12)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(topUp.name)
                    .font(.headline)
                if let description = topUp.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !isEligible {
                    Label(eligibilityText, systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            // Price + buy
            VStack(alignment: .trailing, spacing: 8) {
                Text(price)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Button(action: action) {
                    Group {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Buy").font(.footnote.weight(.semibold))
                        }
                    }
                    .frame(width: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isLoading || !isEligible)
            }
        }
        .padding(16)
        .cardGlass(cornerRadius: 16)
        .opacity(isEligible ? 1 : 0.55)
    }

    private var eligibilityText: String {
        let rules = topUp.blockedBy?.map(\.ruleType) ?? []
        if rules.contains("purchase_limit") { return "Purchase limit reached" }
        if rules.contains("requires_role") { return "Membership required" }
        if rules.contains("requires_active_plan") { return "Specific plan required" }
        if rules.contains("requires_any_plan") { return "Active plan required" }
        return "Not currently eligible"
    }
}

// MARK: - Usage Item Row

public struct UsageItemRow: View {
    public let item: UsageStatus

    public init(item: UsageStatus) {
        self.item = item
    }

    private var progressFraction: Double {
        guard let limit = item.limit, limit > 0 else { return 0 }
        return min(1, Double(item.used) / Double(limit))
    }

    private var progressTint: Color {
        guard let remaining = item.remaining else { return Color.accentColor }
        if remaining == 0 { return .red }
        if progressFraction > 0.8 { return .orange }
        return Color.accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if let limit = item.limit, limit > 0 {
                    Text(usageSummary)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Label("Unlimited", systemImage: "infinity")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }

            if let limit = item.limit, limit > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 7)
                        Capsule()
                            .fill(progressTint)
                            .frame(width: max(7, geo.size.width * progressFraction), height: 7)
                            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: progressFraction)
                    }
                }
                .frame(height: 7)
            }

            if let resetsAt = item.resetsAt {
                Label(
                    "Resets \(resetsAt.formatted(date: .abbreviated, time: .omitted))",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 14)
    }

    private var usageSummary: String {
        guard let limit = item.limit else { return "\(item.used.formatted()) used" }
        return "\(item.used.formatted()) / \(limit.formatted())"
    }
}

// MARK: - Balance Card

public struct BalanceCard: View {
    public let balance: Balance

    public init(balance: Balance) {
        self.balance = balance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                Text(balance.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }

            Text(SubscriptionFormatting.balance(
                balance.available,
                precision: balance.precision,
                symbol: balance.symbol
            ))
            .font(.title.bold().monospacedDigit())
            .minimumScaleFactor(0.65)
            .lineLimit(1)

            if balance.available != balance.amount {
                let total = SubscriptionFormatting.balance(balance.amount, precision: balance.precision)
                Text("\(total) total")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardGlass(cornerRadius: 18)
    }
}

// MARK: - Balance History Row

public struct BalanceHistoryRow: View {
    public let entry: LedgerEntry
    public let showTime: Bool

    public init(entry: LedgerEntry, showTime: Bool = true) {
        self.entry = entry
        self.showTime = showTime
    }

    private var isCredit: Bool { entry.delta >= 0 }

    private var kindIcon: String {
        switch entry.kind {
        case "topup":       return "cart.fill"
        case "plan_grant":  return "gift.fill"
        case "usage":       return "bolt.fill"
        case "adjustment":  return "slider.horizontal.3"
        case "refund":      return "arrow.uturn.backward"
        case "credit":      return "plus.circle.fill"
        case "debit":       return "minus.circle.fill"
        default:            return isCredit ? "arrow.down" : "arrow.up"
        }
    }

    private var kindColor: Color {
        switch entry.kind {
        case "topup":       return .green
        case "plan_grant":  return .indigo
        case "usage":       return .orange
        case "adjustment":  return .teal
        case "refund":      return .purple
        default:            return isCredit ? .green : .orange
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case "topup":       return "Top-up"
        case "plan_grant":  return "Plan grant"
        case "usage":       return "Usage"
        case "adjustment":  return "Adjustment"
        case "refund":      return "Refund"
        case "credit":      return "Credit"
        case "debit":       return "Debit"
        default:            return entry.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kindIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(kindColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(kindLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(kindColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(kindColor.opacity(0.12), in: Capsule())
                    if showTime {
                        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(isCredit ? "+" : "")\(entry.delta.formatted()) \(entry.unit)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCredit ? kindColor : .primary)
                Text("Bal: \(entry.balanceAfter.formatted())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - State Views

struct LoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 32)
    }
}

struct InlineErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("Something went wrong")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GlassButton("Try Again", action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.horizontal, 32)
    }
}
