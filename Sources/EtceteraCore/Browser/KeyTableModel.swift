import EtcdKit
import Foundation
import Observation

/// One table row, identified by the raw key so non-UTF-8 keys stay
/// addressable.
public struct KeyRow: Identifiable, Hashable, Sendable {
    public let id: Data
    /// The key with non-UTF-8 bytes as \xNN escapes.
    public let displayKey: String
    /// Nil when the value was too large to fetch through the gateway.
    public let size: Int?
    public let modRevision: Int64
    public let lease: Int64
    /// The name the key's mapping takes from its value. See SPEC 5.5.
    public let displayName: String?

    init(_ kv: KeyValue, valueFetched: Bool = true, displayName: String? = nil) {
        id = kv.key
        displayKey = displayString(for: kv.key)
        size = valueFetched ? kv.value.count : nil
        modRevision = kv.modRevision
        lease = kv.lease
        self.displayName = displayName
    }

    /// A value too large for the gateway sorts above every listed size.
    public var sizeForSorting: Int { size ?? .max }
    public var nameForSorting: String { displayName ?? "" }
}

/// Orders raw keys by their bytes, as etcd does.
public struct KeyByteOrder: SortComparator, Hashable, Sendable {
    public var order: Foundation.SortOrder

    public init(order: Foundation.SortOrder = .forward) {
        self.order = order
    }

    public func compare(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        let ascending: ComparisonResult =
            lhs == rhs ? .orderedSame : lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
        guard order == .reverse, ascending != .orderedSame else { return ascending }
        return ascending == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}

/// The key table's columns: their titles, cell text, and sorting.
public enum KeyColumn: String, CaseIterable, Sendable {
    case key, name, size, revision, lease

    public var title: String {
        switch self {
        case .key: String(localized: "Key", bundle: .module, comment: "Key table column title")
        case .name: String(localized: "Name", bundle: .module, comment: "Key table column title: the name a mapping takes from the value")
        case .size: String(localized: "Size", bundle: .module, comment: "Key table column title")
        case .revision: String(localized: "Revision", bundle: .module, comment: "Key table column title")
        case .lease: String(localized: "Lease", bundle: .module, comment: "Key table column title")
        }
    }

    public func text(for row: KeyRow) -> String {
        switch self {
        case .key: row.displayKey
        case .name: row.displayName ?? ""
        case .size: row.size.map { formatByteSize($0) } ?? String(localized: "too large", bundle: .module, comment: "Size cell of a value too large to fetch")
        case .revision: String(row.modRevision)
        case .lease: row.lease == 0 ? String(localized: "none", bundle: .module, comment: "Lease cell of a key without a lease") : String(row.lease, radix: 16)
        }
    }

    public func comparator(ascending: Bool) -> KeyPathComparator<KeyRow> {
        let order: Foundation.SortOrder = ascending ? .forward : .reverse
        return switch self {
        case .key: KeyPathComparator(\.id, comparator: KeyByteOrder(order: order))
        case .name: KeyPathComparator(\.nameForSorting, comparator: String.StandardComparator(.localizedStandard, order: order))
        case .size: KeyPathComparator(\.sizeForSorting, order: order)
        case .revision: KeyPathComparator(\.modRevision, order: order)
        case .lease: KeyPathComparator(\.lease, order: order)
        }
    }

    /// The column and direction a comparator sorts by; nil for other sorts.
    public static func sorting(_ comparator: KeyPathComparator<KeyRow>) -> (column: KeyColumn, ascending: Bool)? {
        allCases.first { $0.comparator(ascending: true).keyPath == comparator.keyPath }
            .map { ($0, comparator.order == .forward) }
    }
}

/// The keys under the selected tree node: the node's own value when it has
/// one, then everything below it, loaded page by page. See SPEC 4.1.
@MainActor
@Observable
public final class KeyTableModel {
    /// Ascending by key: the order etcd returns, so it needs no sorting.
    public static let keyOrder = KeyColumn.key.comparator(ascending: true)

    /// The loaded rows in `sortOrder`.
    public private(set) var rows: [KeyRow] = []
    public var sortOrder = [KeyTableModel.keyOrder] {
        didSet { rows = sorted(ordered) }
    }
    /// The loaded rows in key order; ties in other sorts keep this order.
    private var ordered: [KeyRow] = []
    public private(set) var isLoading = false
    /// A first load is running and the rows are still incomplete; reloads
    /// keep the old rows and never set it.
    public private(set) var isFilling = false
    public private(set) var errorMessage: String?
    /// What is listed: an optional key of its own, then a prefix range,
    /// optionally kept to rows matching a search.
    private var listing: (ownKey: Data?, prefix: String, query: String?)?
    /// Drops results of a load that a newer load superseded.
    private var generation = 0

    public init() {}

    /// A tree node: its own value, then everything below it. Nil clears.
    public func load(path: String?, from connection: ConnectionModel) async {
        listing = path.map { ($0.isEmpty ? nil : Data($0.utf8), connection.childPrefix(for: $0), nil) }
        await start(from: connection, clearing: true)
    }

    /// The whole keyspace.
    public func loadAll(from connection: ConnectionModel) async {
        listing = (nil, "", nil)
        await start(from: connection, clearing: true)
    }

    /// A server-side prefix scan: every key starting with `prefix`, not only
    /// whole segments.
    public func scan(prefix: String, from connection: ConnectionModel) async {
        listing = (nil, prefix, nil)
        await start(from: connection, clearing: true)
    }

    /// Every key on the server whose path or name contains `query`, ignoring
    /// case. etcd has no substring search, so the whole keyspace is read.
    public func search(_ query: String, from connection: ConnectionModel) async {
        listing = (nil, "", query)
        await start(from: connection, clearing: true)
    }

    /// Repeats the current listing, keeping the rows until new ones arrive.
    public func reload(from connection: ConnectionModel) async {
        guard listing != nil else { return }
        await start(from: connection, clearing: false)
    }

    private func show(_ loaded: [KeyRow]) {
        ordered = loaded
        rows = sorted(loaded)
    }

    private func sorted(_ loaded: [KeyRow]) -> [KeyRow] {
        sortOrder == [Self.keyOrder] ? loaded : loaded.sorted(using: sortOrder)
    }

    private func start(from connection: ConnectionModel, clearing: Bool) async {
        generation += 1
        let current = generation
        if clearing { show([]) }
        errorMessage = nil
        guard let listing, connection.isConnected else {
            show([])
            // A superseded load no longer resets it.
            isLoading = false
            isFilling = false
            return
        }
        isLoading = true
        isFilling = clearing
        defer {
            if current == generation {
                isLoading = false
                isFilling = false
            }
        }
        do {
            var loaded: [KeyRow] = []
            if let ownKey = listing.ownKey, let row = try await connection.row(forKey: ownKey) {
                loaded = [row]
            }
            // The cursor is never the own key, which sorts before the prefix range.
            var cursor: Data?
            var more = true
            while more {
                let page = try await connection.valuePage(under: listing.prefix, after: cursor)
                guard current == generation else { return }
                loaded += listing.query.map { query in page.rows.filter { KeySearch.matches($0, query: query) } } ?? page.rows
                // A first load shows rows as they arrive; a reload swaps them at the end.
                if clearing { show(loaded) }
                cursor = page.kvs.last?.key
                more = page.more && cursor != nil
            }
            show(loaded)
        } catch {
            guard current == generation else { return }
            show([])
            errorMessage = ConnectionModel.message(for: error)
        }
    }
}
