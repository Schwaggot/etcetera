import Foundation
import Observation

/// The sidebar search over the whole server: keys and folders by path, and
/// keys by the names mappings give them. See SPEC 4.2.
@MainActor
@Observable
public final class ServerKeySearch {
    public static let hitLimit = 500

    /// The first `hitLimit` matches of `query`.
    public private(set) var hits: [SearchHit] = []
    /// Matches in all.
    public private(set) var total = 0
    /// The query `hits` answers.
    public private(set) var query = ""
    public private(set) var isSearching = false
    public private(set) var errorMessage: String?
    /// Drops results of a search that a newer one superseded.
    private var generation = 0

    public init() {}

    /// Searches the server for `query`; an empty query clears.
    public func search(_ query: String, in connection: ConnectionModel) async {
        generation += 1
        let current = generation
        // A reconnect mid-search must not show the old cluster's keys.
        let session = connection.session
        guard !query.isEmpty, connection.isConnected else {
            show([], total: 0, for: query)
            isSearching = false
            return
        }
        isSearching = true
        defer { if current == generation { isSearching = false } }
        do {
            try await connection.loadAllNames()
            let keys = try await connection.allKeyPaths()
            let names = connection.displayNames
            let separator = connection.separatorCharacter
            let limit = Self.hitLimit
            let found = await Task.detached {
                KeySearch.hits(keys: keys, query: query, names: names, separator: separator, limit: limit)
            }.value
            guard current == generation, !Task.isCancelled, session == connection.session else { return }
            show(found.hits, total: found.total, for: query)
        } catch {
            guard current == generation, !Task.isCancelled, session == connection.session else { return }
            show([], total: 0, for: query)
            errorMessage = ConnectionModel.message(for: error)
        }
    }

    private func show(_ hits: [SearchHit], total: Int, for query: String) {
        self.hits = hits
        self.total = total
        self.query = query
        errorMessage = nil
    }
}
