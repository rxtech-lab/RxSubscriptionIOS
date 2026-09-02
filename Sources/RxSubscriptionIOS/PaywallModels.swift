import Foundation

/// Selects whether ``PaywallView`` uses the package's built-in screens or the
/// published paywall assigned in the RxSubscription console.
public enum PaywallSource: String, Codable, Hashable, Sendable {
    case local
    case server
}

/// The published paywall returned by `GET /api/v1/paywall`.
public struct PaywallDocument: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let designVersion: Int
    public let publishedAt: Date
    public let spec: PaywallSpec
}

public struct PaywallSpec: Codable, Hashable, Sendable {
    public let version: Int
    public let theme: PaywallTheme
    public let root: PaywallNode
}

public struct PaywallTheme: Codable, Hashable, Sendable {
    public let colorScheme: String
    public let colors: PaywallColors
    public let cornerRadius: Double
    public let fontDesign: String
}

public struct PaywallColors: Codable, Hashable, Sendable {
    public let primary: String
    public let background: String
    public let foreground: String
    public let muted: String
    public let accent: String
}

/// One native-view node in a server-driven paywall tree.
public struct PaywallNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let props: [String: JSONValue]
    public let modifiers: PaywallModifiers?
    public let children: [PaywallNode]?

    /// Filled by the server for `ProductList` nodes.
    public let products: [PaywallProduct]?
    public let highlightedProductID: String?

    /// The period switcher a `ProductList` offers, already resolved to the
    /// products each choice reveals. Absent or empty when the list has none.
    public let periodOptions: [PaywallPeriodOption]?

    enum CodingKeys: String, CodingKey {
        case id, type, props, modifiers, children, products, periodOptions
        case highlightedProductID = "highlightedProductId"
    }

    /// The tabs a `TabView` node declares: tab *n* opens child *n*.
    ///
    /// A design can carry more pages than titles, so this pads the list rather
    /// than dropping the extra pages — an unnamed page is still content the
    /// buyer is meant to reach.
    public var tabs: [PaywallTab] {
        var entries: [PaywallTab] = []
        if case .array(let values) = props["tabs"] {
            entries = values.map { value in
                guard case .object(let fields) = value else { return PaywallTab(title: "") }
                return PaywallTab(
                    title: fields.string("title") ?? "",
                    icon: fields.string("icon"),
                    badge: fields.string("badge")
                )
            }
        }
        let pages = children?.count ?? 0
        while entries.count < pages {
            entries.append(PaywallTab(title: ""))
        }
        return entries
    }

    /// The typed action declared by a Button node, if it is supported and valid.
    public var action: PaywallAction? {
        guard case .object(let value) = props["action"],
              case .string(let type) = value["type"]
        else { return nil }

        switch type {
        case "purchase":
            return .purchase(productID: value.string("productId"))
        case "restorePurchases":
            return .restorePurchases
        case "dismiss":
            return .dismiss
        case "openUrl":
            guard let urlString = value.string("url"), let url = URL(string: urlString) else {
                return nil
            }
            return .openURL(url)
        case "selectProduct":
            guard let productID = value.string("productId") else { return nil }
            return .selectProduct(productID: productID)
        default:
            return nil
        }
    }
}

/// One tab of a `TabView` node, titling the child at the same index.
public struct PaywallTab: Hashable, Sendable {
    public let title: String
    public let icon: String?
    public let badge: String?

    public init(title: String, icon: String? = nil, badge: String? = nil) {
        self.title = title
        self.icon = icon
        self.badge = badge
    }
}

/// One choice in a product list's period switcher — monthly, yearly, one-time.
///
/// The server resolves these, so the app never groups plans itself: an option
/// names exactly the products it reveals and the one to preselect while it is
/// in play, which is not the same plan from one period to the next.
public struct PaywallPeriodOption: Codable, Hashable, Sendable, Identifiable {
    /// A billing interval, or `all` for the choice that clears the filter.
    public let key: String
    public let label: String
    public let productIDs: [String]
    public let highlightedProductID: String?
    /// Exactly one option is selected: the one the paywall opens on.
    public let selected: Bool

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, selected
        case productIDs = "productIds"
        case highlightedProductID = "highlightedProductId"
    }
}

public struct PaywallModifiers: Codable, Hashable, Sendable {
    public let padding: PaywallPadding?
    public let frame: PaywallFrame?
    public let background: String?
    public let cornerRadius: Double?
    public let border: PaywallBorder?
    public let opacity: Double?
    public let hidden: Bool?
}

public enum PaywallPadding: Codable, Hashable, Sendable {
    case all(Double)
    case edges(PaywallEdges)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .all(value)
        } else {
            self = .edges(try container.decode(PaywallEdges.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all(let value): try container.encode(value)
        case .edges(let value): try container.encode(value)
        }
    }
}

public struct PaywallEdges: Codable, Hashable, Sendable {
    public let top: Double?
    public let leading: Double?
    public let bottom: Double?
    public let trailing: Double?
}

public struct PaywallFrame: Codable, Hashable, Sendable {
    public let width: Double?
    public let height: Double?
    public let maxWidth: Double?
    public let maxHeight: Double?
}

public struct PaywallBorder: Codable, Hashable, Sendable {
    public let color: String
    public let width: Double
}

/// A plan already resolved for display by the paywall endpoint.
public struct PaywallProduct: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let description: String?
    public let planGroup: String
    public let billingInterval: String
    public let intervalCount: Int
    public let priceAmountCents: Int
    public let currency: String
    public let trialDays: Int
    public let purchaseOptions: [PurchaseOption]
    public let priceLabel: String
    public let periodLabel: String
    public let savingsLabel: String?
    public let badge: String?
}

/// An interaction declared by a server-driven paywall control.
public enum PaywallAction: Hashable, Sendable {
    case purchase(productID: String?)
    case restorePurchases
    case dismiss
    case openURL(URL)
    case selectProduct(productID: String)
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }
}
