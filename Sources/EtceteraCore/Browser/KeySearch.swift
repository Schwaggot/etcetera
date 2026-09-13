import Foundation

/// A key or folder the sidebar search found; a path can be both.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let path: String
    /// Holds a value of its own.
    public internal(set) var isKey = false
    /// Has keys below it.
    public internal(set) var isFolder = false

    public var id: String { path }
}

/// The sidebar search: matching over the server's keys and over table rows,
/// and a test for queries worth a server-side prefix scan. See SPEC 4.2.
public enum KeySearch {
    /// The keys and folders matching `query`, ignoring case, in key order:
    /// every key whose path or name contains it, and the shallowest folder
    /// whose path does. The first `limit` hits, and how many there are.
    public static func hits(
        keys: [String], query: String, names: [Data: String], separator: Character, limit: Int
    ) -> (hits: [SearchHit], total: Int) {
        guard !query.isEmpty else { return ([], 0) }
        var found: [String: SearchHit] = [:]
        for key in keys {
            var start = key.startIndex
            while let index = key[start...].firstIndex(of: separator) {
                let folder = String(key[..<index])
                if folder.localizedCaseInsensitiveContains(query) {
                    found[folder, default: SearchHit(path: folder)].isFolder = true
                    break
                }
                start = key.index(after: index)
            }
            if key.localizedCaseInsensitiveContains(query)
                || names[Data(key.utf8)]?.localizedCaseInsensitiveContains(query) == true
            {
                found[key, default: SearchHit(path: key)].isKey = true
            }
        }
        let sorted = found.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return (Array(sorted.prefix(limit)), sorted.count)
    }

    /// Whether a table row's key or name contains `query`, ignoring case.
    public static func matches(_ row: KeyRow, query: String) -> Bool {
        row.displayKey.localizedCaseInsensitiveContains(query)
            || row.displayName?.localizedCaseInsensitiveContains(query) == true
    }

    public static func looksLikeKeyPath(_ query: String, separator: Character) -> Bool {
        query.contains(separator)
    }
}
