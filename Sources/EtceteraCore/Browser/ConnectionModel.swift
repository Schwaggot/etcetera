import EtcdKit
import EtcdSchema
import Foundation
import Observation

/// The application's single connection. Owns the client and the key tree;
/// views never call the client directly. See SPEC 4.1.
@MainActor
@Observable
public final class ConnectionModel {
    public enum Phase: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public static let pageLimit: Int64 = 1000
    /// Keys per page with values: cut while the gateway refuses pages as too
    /// large, grown back after pages that pass.
    private var valuePageLimit = pageLimit

    public var endpoint = "http://127.0.0.1:2379"
    public var separator = "/"
    public private(set) var phase: Phase = .disconnected
    public private(set) var serverVersion: String?
    /// Synthetic root; its children are the top of the tree.
    public private(set) var root = KeyNode.root()

    /// The node whose children the tree shows first: the unnamed node when
    /// every key starts with the separator, since a nameless row says nothing.
    public var topNode: KeyNode {
        guard let children = root.children, children.count == 1, children[0].name.isEmpty,
            children[0].hasChildren, !root.moreAvailable
        else { return root }
        return children[0]
    }
    /// The most recent tree loading failure, shown in the sidebar.
    public private(set) var lastError: String?
    /// Bumped after every successful write, so listings know to reload.
    public private(set) var writeCount = 0
    /// Bumped for every live update, so listings know to refresh.
    public private(set) var changeCount = 0
    /// The revision of the last live update applied.
    public private(set) var liveRevision: Int64 = 0
    /// Names that mappings with a name field give keys, by raw key. See SPEC 5.5.
    public private(set) var displayNames: [Data: String] = [:]
    /// Bumped when the mappings change, so listings fetch names again.
    public private(set) var namingChangeCount = 0
    /// Names being worked out, in the order their values arrived.
    private(set) var namingQueue: Task<Void, Never>?
    /// The search's list of keys and when its names were read; kept while
    /// the watch keeps them current.
    private var searchKeys: (stamp: [Int], keys: [String])?
    private var searchNamesStamp: [Int]?
    private var watchTask: Task<Void, Never>?
    /// Events for nodes whose page is loading, applied once it arrives.
    private var heldEvents: [ObjectIdentifier: [WatchEvent]] = [:]
    /// Changes on every disconnect, so values loaded earlier can refuse to
    /// save into a different cluster.
    public private(set) var session = 0
    /// The profile of the current or last attempted connection.
    public private(set) var profile: ConnectionProfile?
    public private(set) var schemaState: SchemaState = .notConfigured
    /// .proto files the last compile left out, with protoc's reasons.
    public private(set) var skippedSchemaFiles: [SkippedProtoFile] = []
    private var client: EtcdClient?
    private let transport: (any EtcdTransport)?
    private let secrets: any SecretStore
    private let files: any FileAccess
    private let schemaLoader: (any SchemaLoading)?

    /// `transport` replaces HTTP, for tests.
    public init(
        transport: (any EtcdTransport)? = nil, secrets: any SecretStore = InMemorySecretStore(),
        files: any FileAccess = NoFileAccess(), schemaLoader: (any SchemaLoading)? = nil
    ) {
        self.transport = transport
        self.secrets = secrets
        self.files = files
        self.schemaLoader = schemaLoader
    }

    public var isConnected: Bool { phase == .connected }
    public var separatorCharacter: Character { separator.first ?? "/" }
    /// Drives the persistent warning while verification is off. See SPEC 3.10.
    public var skipsServerVerification: Bool { profile?.tls.skipServerVerification ?? false }
    public var watchEnabled: Bool { profile?.watchEnabled ?? false }

    /// A one-off connection to `endpoint`, without a saved profile.
    public func connect() async {
        await connect(to: ConnectionProfile(id: "", name: endpoint, endpoint: endpoint, separator: separator))
    }

    /// Tears down any current client, then connects and authenticates.
    public func connect(to profile: ConnectionProfile) async {
        disconnect()
        self.profile = profile
        endpoint = profile.endpoint
        separator = profile.separator.isEmpty ? "/" : profile.separator
        phase = .connecting
        do {
            let client = try await ConnectionSetup.open(profile, secrets: secrets, files: files, transport: transport)
            self.client = client
            serverVersion = client.serverVersion?.description
            // Before reporting connected, so restored tabs decode.
            await loadSchema()
            phase = .connected
            // Watching before the first page means no event falls between;
            // events arriving while it loads apply after it.
            if profile.watchEnabled { startWatching() }
            await loadChildren(of: root)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    public func disconnect() {
        watchTask?.cancel()
        watchTask = nil
        heldEvents = [:]
        liveRevision = 0
        session += 1
        client = nil
        profile = nil
        schemaState = .notConfigured
        skippedSchemaFiles = []
        namingQueue?.cancel()
        namingQueue = nil
        displayNames = [:]
        searchKeys = nil
        searchNamesStamp = nil
        root = KeyNode.root()
        serverVersion = nil
        lastError = nil
        phase = .disconnected
    }

    // MARK: Schema

    /// Compiles the profile's schema when one is configured; `force` is the
    /// Refresh command. See SPEC 5.2.
    public func loadSchema(force: Bool = false) async {
        skippedSchemaFiles = []
        guard let profile, profile.schema.source != nil, let schemaLoader else {
            schemaState = .notConfigured
            return
        }
        schemaState = .compiling
        do {
            let schema = try await schemaLoader.schema(for: profile.schema, profileID: profile.id, force: force)
            skippedSchemaFiles = schema.skipped
            schemaState = .ready(schema.registry)
        } catch {
            schemaState = .failed(Self.message(for: error))
        }
    }

    /// Applies edited schema settings of the live profile without
    /// reconnecting; other settings take effect on the next connect.
    public func profileChanged(_ updated: ConnectionProfile) async {
        guard isConnected, profile?.id == updated.id, profile?.schema != updated.schema else { return }
        profile?.schema = updated.schema
        await loadSchema()
        await refreshNames()
    }

    public var schemaRegistry: SchemaRegistry? {
        if case .ready(let registry) = schemaState { return registry }
        return nil
    }

    /// How a key's mapping resolves against the compiled schema. A mapping
    /// that cannot be honored is reported, never ignored. See SPEC 5.5.
    public func mapping(forKey key: Data) -> MappingResolution {
        guard let profile, let text = String(data: key, encoding: .utf8) else { return .unmapped }
        let configuration = profile.schema.configuration
        if case .failed(let message) = schemaState, let rule = configuration.rule(forKey: text) {
            return .misconfigured(rule: rule, reason: String(localized: "The schema did not compile:\n\(message)", bundle: .module))
        }
        return configuration.resolve(key: text, in: schemaRegistry)
    }

    /// The mapping editor's Test: which of `rules` matches `key`, and the
    /// key's live value decoded with that rule's message.
    public func testMapping(key: String, rules: [SchemaMappingRule]) async -> MappingTestResult {
        guard let rule = SchemaMappingConfiguration(schemaSource: "", mappings: rules).rule(forKey: key) else {
            return .unmapped
        }
        guard let registry = schemaRegistry else {
            return .failed(rule: rule, reason: String(localized: "The schema has not been compiled.", bundle: .module))
        }
        let message = rule.message
        guard registry.message(named: message) != nil else {
            return .failed(
                rule: rule, reason: String(localized: "The message type \(message) is not in the schema.", bundle: .module))
        }
        do {
            guard let kv = try await value(forKey: Data(key.utf8)) else {
                return .failed(rule: rule, reason: String(localized: "\(key) does not exist.", bundle: .module))
            }
            let codec = ProtobufValueCodec(registry: registry)
            let bytes = kv.value
            return await Task.detached { () -> MappingTestResult in
                // A message stored as JSON is checked, never decoded. See SPEC 5.5.
                if MessageCheck.isJSONObject(bytes) {
                    let text = String(decoding: bytes, as: UTF8.self)
                    switch MessageCheck.check(text, message: message, codec: codec) {
                    case .matches: return .decoded(rule: rule, json: JSONFormatter().prettyPrint(text))
                    case .mismatch(let reason): return .failed(rule: rule, reason: reason)
                    }
                }
                do {
                    return .decoded(rule: rule, json: try codec.decodeToJSON(bytes, messageName: message).json)
                } catch {
                    return .failed(rule: rule, reason: ConnectionModel.message(for: error))
                }
            }.value
        } catch {
            return .failed(rule: rule, reason: Self.message(for: error))
        }
    }

    /// How `text` compares with the message mapped at `key`; nil when no
    /// usable mapping matches or the text is empty.
    public func checkValue(_ text: String, forKey key: Data) async -> SchemaCheck? {
        guard case .mapped(let message, _) = mapping(forKey: key), let registry = schemaRegistry,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let codec = ProtobufValueCodec(registry: registry)
        return await Task.detached { MessageCheck.check(text, message: message, codec: codec) }.value
    }

    // MARK: Names

    /// The mappings, when any of them names keys.
    private var naming: SchemaMappingConfiguration? {
        guard let configuration = profile?.schema.configuration,
            configuration.mappings.contains(where: { $0.nameField != nil })
        else { return nil }
        return configuration
    }

    /// Whether some mapping gives the keys names, so the table has a name column.
    public var namesKeys: Bool { naming != nil }

    /// Whether a mapping with a name field can match keys directly below `prefix`.
    func namesLeaves(under prefix: String) -> Bool {
        guard let naming else { return false }
        let separator = separatorCharacter
        return naming.mappings.contains { rule in
            guard rule.nameField != nil else { return false }
            switch rule.pattern {
            case .prefix(let pattern):
                return prefix.hasPrefix(pattern)
                    || (pattern.hasPrefix(prefix) && !pattern.dropFirst(prefix.count).contains(separator))
            case .key(let key):
                return key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains(separator)
            }
        }
    }

    /// The names values give their keys; a binary value is decoded with its
    /// message first.
    nonisolated static func names(
        of kvs: [KeyValue], naming: SchemaMappingConfiguration, codec: ProtobufValueCodec?
    ) -> [Data: String] {
        var names: [Data: String] = [:]
        for kv in kvs {
            guard let key = kv.keyString, let rule = naming.rule(forKey: key), rule.nameField != nil, !kv.value.isEmpty
            else { continue }
            if let name = rule.displayName(forValue: kv.value) {
                names[kv.key] = name
            } else if !MessageCheck.isJSONObject(kv.value), let codec,
                let json = try? codec.decodeToJSON(kv.value, messageName: rule.message).json
            {
                names[kv.key] = rule.displayName(forValue: Data(json.utf8))
            }
        }
        return names
    }

    /// Works out the names of `kvs`, read in session `readSession`, off the
    /// main actor and records them; a key whose value gives no name loses
    /// the one it had.
    @discardableResult
    func recordNames(of kvs: [KeyValue], readIn readSession: Int) async -> [Data: String] {
        guard readSession == session, let naming, !kvs.isEmpty else { return [:] }
        let codec = schemaRegistry.map { ProtobufValueCodec(registry: $0) }
        let current = (session, namingChangeCount)
        let names = await Task.detached { Self.names(of: kvs, naming: naming, codec: codec) }.value
        guard current == (session, namingChangeCount) else { return names }
        var updated = displayNames
        for kv in kvs { updated[kv.key] = names[kv.key] }
        if updated != displayNames { displayNames = updated }
        return names
    }

    /// A node's children as the tree shows them: keys with a name first,
    /// ordered by name, then the rest in key order. See SPEC 5.5.
    public func displayedChildren(of node: KeyNode) -> [KeyNode] {
        let children = node.children ?? []
        guard !displayNames.isEmpty else { return children }
        let named = children.compactMap { child in
            child.isLeaf ? displayNames[Data(child.path.utf8)].map { (child, $0) } : nil
        }
        guard !named.isEmpty else { return children }
        let sorted = named.sorted { lhs, rhs in
            switch lhs.1.localizedStandardCompare(rhs.1) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.0.path.utf8.lexicographicallyPrecedes(rhs.0.path.utf8)
            }
        }.map(\.0)
        let namedPaths = Set(sorted.map(\.path))
        return sorted + children.filter { !namedPaths.contains($0.path) }
    }

    /// Records names without holding up the caller, keeping arrival order;
    /// `readSession` defaults to the current session.
    func queueNames(of kvs: [KeyValue], readIn readSession: Int? = nil) {
        guard naming != nil else { return }
        let readSession = readSession ?? session
        let previous = namingQueue
        namingQueue = Task {
            await previous?.value
            await self.recordNames(of: kvs, readIn: readSession)
        }
    }

    /// Names follow the mappings: the loaded tree levels that get names list
    /// again with values, and listings reload on the bumped count.
    private func refreshNames() async {
        displayNames = [:]
        namingChangeCount += 1
        guard naming != nil else { return }
        let current = session
        var queue = [root]
        while !queue.isEmpty, session == current {
            let node = queue.removeFirst()
            guard let children = node.children else { continue }
            if namesLeaves(under: node === root ? "" : childPrefix(for: node.path)) { await loadChildren(of: node) }
            queue += children
        }
    }

    // MARK: Live updates

    /// One watch on the whole keyspace. After a compaction the tree reloads
    /// and the watch starts over. See SPEC 3.8 and 4.2.
    func startWatching() {
        guard let client else { return }
        watchTask?.cancel()
        let stream = client.watch(WatchCreateRequest(key: Data([0]), rangeEnd: Data([0])))
        watchTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.apply(event)
                }
                // The search caches only trust a running watch.
                if !Task.isCancelled { self?.watchTask = nil }
            } catch is CancellationError {
            } catch EtcdError.compacted {
                guard let self, !Task.isCancelled else { return }
                // Otherwise startWatching cancels this task and the reload with it.
                self.watchTask = nil
                self.startWatching()
                await self.reload(path: nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.watchTask = nil
                self.lastError = String(localized: "Live updates stopped: \(Self.message(for: error))", bundle: .module)
            }
        }
    }

    /// Applies one watch event to the loaded parts of the tree; unloaded
    /// branches load fresh when expanded.
    func apply(_ event: WatchEvent) {
        liveRevision = max(liveRevision, event.revision)
        changeCount += 1
        // A delete carries no value, so the key loses its name.
        queueNames(of: [event.kv])
        route(event)
    }

    private func route(_ event: WatchEvent) {
        guard let key = event.kv.keyString else { return }
        switch event.kind {
        case .put: insert(key, event)
        case .delete: remove(key, event)
        }
    }

    /// Holds `event` when `node` is loading; its page may predate the event.
    private func holdIfLoading(_ node: KeyNode, _ event: WatchEvent) -> Bool {
        guard node.isLoading else { return false }
        heldEvents[ObjectIdentifier(node), default: []].append(event)
        return true
    }

    private func insert(_ key: String, _ event: WatchEvent) {
        let separator = separatorCharacter
        var node = root
        var prefix = ""
        while key.hasPrefix(prefix), key.count > prefix.count {
            if holdIfLoading(node, event) { return }
            guard node.children != nil else { return }
            let remainder = key.dropFirst(prefix.count)
            guard let index = remainder.firstIndex(of: separator) else {
                let segment = String(remainder)
                node.merge([TreeNode(name: segment, path: prefix + segment, isLeaf: true, hasChildren: false)])
                return
            }
            let segment = String(remainder[..<index])
            let path = prefix + segment
            node.merge([TreeNode(name: segment, path: path, isLeaf: false, hasChildren: true)])
            guard let child = node.children?.first(where: { $0.path == path }) else { return }
            node = child
            prefix = path + String(separator)
        }
    }

    private func remove(_ key: String, _ event: WatchEvent) {
        let separator = separatorCharacter
        var chain = [root]
        var prefix = ""
        while let node = chain.last, key.hasPrefix(prefix), key.count > prefix.count {
            if holdIfLoading(node, event) { return }
            guard node.children != nil else { return }
            let remainder = key.dropFirst(prefix.count)
            guard let index = remainder.firstIndex(of: separator) else {
                let path = prefix + String(remainder)
                guard let leaf = node.children?.first(where: { $0.path == path }) else { return }
                leaf.isLeaf = false
                // Children deleted earlier leave a fully loaded empty list behind.
                if !leaf.hasChildren || (leaf.children?.isEmpty == true && !leaf.moreAvailable) {
                    node.children?.removeAll { $0 === leaf }
                }
                pruneEmptyBranches(chain)
                return
            }
            let path = prefix + String(remainder[..<index])
            guard let child = node.children?.first(where: { $0.path == path }) else { return }
            chain.append(child)
            prefix = path + String(separator)
        }
    }

    /// Drops branches left empty, but only when all their children were
    /// loaded; otherwise more keys may remain below.
    private func pruneEmptyBranches(_ chain: [KeyNode]) {
        var index = chain.count - 1
        while index > 0 {
            let node = chain[index]
            guard node.children?.isEmpty == true, !node.moreAvailable, !node.isLeaf else { return }
            chain[index - 1].children?.removeAll { $0 === node }
            index -= 1
        }
    }

    // MARK: Tree

    /// Loads all children of a node, page by page. A page skips past the
    /// subtree its last key lies in, so every page adds a child and a node
    /// with few children but many keys below takes few pages. See SPEC 4.2.
    public func loadChildren(of node: KeyNode) async {
        guard client != nil, !node.isLoading else { return }
        node.isLoading = true
        let current = session
        // By identity: a leading separator gives a top node whose path is
        // also empty, and it lists under the separator, not everything.
        let prefix = node === root ? "" : childPrefix(for: node.path)
        let named = namesLeaves(under: prefix)
        do {
            var start: Data?
            node.moreAvailable = true
            while node.moreAvailable, session == current {
                let (kvs, more, hasValues) = try await treePage(under: prefix, from: start, withValues: named)
                guard session == current else { break }
                if hasValues { queueNames(of: kvs, readIn: current) }
                if let last = kvs.last?.key { start = resumeKey(after: last, prefix: prefix) }
                // Non-UTF-8 keys cannot be addressed as tree paths; the table
                // shows them with escapes.
                let keys = kvs.compactMap(\.keyString)
                node.merge(buildChildren(keys: keys, prefix: prefix, separator: separatorCharacter))
                node.moreAvailable = more && !kvs.isEmpty
            }
            if session == current { lastError = nil }
        } catch {
            if node.children == nil { node.children = [] }
            if session == current { lastError = Self.message(for: error) }
        }
        node.isLoading = false
        // In order, so a later event wins over an earlier one.
        let held = heldEvents.removeValue(forKey: ObjectIdentifier(node)) ?? []
        for event in held {
            route(event)
        }
        // The page's names were queued after these events' names.
        if !held.isEmpty { queueNames(of: held.map(\.kv), readIn: current) }
        if node === root, topNode !== root, topNode.children == nil {
            await loadChildren(of: topNode)
        }
    }

    /// Drops a loaded node's children and fetches them again; nil
    /// is the root. Unloaded nodes are left to load when expanded.
    public func reload(path: String?) async {
        let node: KeyNode? = if let path { loadedNode(at: path) } else { root }
        guard let node, node.children != nil else { return }
        node.children = nil
        node.moreAvailable = false
        await loadChildren(of: node)
    }

    func loadedNode(at path: String) -> KeyNode? {
        var queue = root.children ?? []
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.path == path { return node }
            if path.hasPrefix(node.path) { queue += node.children ?? [] }
        }
        return nil
    }

    /// The path of the tree node that lists `key`; nil for the root.
    public func parentPath(of key: String) -> String? {
        guard let index = key.lastIndex(of: separatorCharacter) else { return nil }
        return String(key[..<index])
    }

    /// The prefix that lists everything below a tree node.
    public func childPrefix(for path: String) -> String {
        path + String(separatorCharacter)
    }

    // MARK: Reads

    /// Where the next page of a node's children starts. A last key inside a
    /// child's subtree skips the rest of it, which the child lists when
    /// expanded; otherwise paging continues right after the key.
    private func resumeKey(after last: Data, prefix: String) -> Data {
        let separator = Data(String(separatorCharacter).utf8)
        let rest = last.dropFirst(Data(prefix.utf8).count)
        guard let found = rest.range(of: separator) else { return last + Data([0]) }
        var end = Data(last[..<found.upperBound])
        // UTF-8 has no 0xFF byte, so the separator's last byte can be incremented.
        end[end.index(before: end.endIndex)] += 1
        return end
    }

    /// One page of keys under `prefix`, starting at `start` itself.
    public func page(
        under prefix: String, from start: Data?, keysOnly: Bool
    ) async throws -> (kvs: [KeyValue], more: Bool) {
        guard let client else { return ([], false) }
        return try await client.listPage(prefix: prefix, from: start, limit: Self.pageLimit, keysOnly: keysOnly)
    }

    /// A tree page, with values when its leaves get names; keys alone when
    /// a value is too large to fetch.
    private func treePage(
        under prefix: String, from start: Data?, withValues: Bool
    ) async throws -> (kvs: [KeyValue], more: Bool, hasValues: Bool) {
        if withValues, let client,
            let listed = try await listingValues({ limit in
                try await client.listPage(prefix: prefix, from: start, limit: limit, keysOnly: false)
            })
        {
            return (listed.kvs, listed.more, true)
        }
        let (kvs, more) = try await page(under: prefix, from: start, keysOnly: true)
        return (kvs, more, false)
    }

    public struct ValuePage: Sendable {
        public let kvs: [KeyValue]
        /// Keys listed without their value, which was too large to fetch.
        public let withoutValues: Set<Data>
        public let more: Bool
        public let names: [Data: String]

        var rows: [KeyRow] {
            kvs.map { KeyRow($0, valueFetched: !withoutValues.contains($0.key), displayName: names[$0.key]) }
        }
    }

    /// One page of keys with values under `prefix`, continuing after
    /// `lastKey`; a value too large on its own is listed by key alone.
    public func valuePage(under prefix: String, after lastKey: Data?) async throws -> ValuePage {
        guard let client else { return ValuePage(kvs: [], withoutValues: [], more: false, names: [:]) }
        let current = session
        if let listed = try await listingValues({ limit in
            try await client.listPage(prefix: prefix, after: lastKey, limit: limit, keysOnly: false)
        }) {
            let names = await recordNames(of: listed.kvs, readIn: current)
            return ValuePage(kvs: listed.kvs, withoutValues: [], more: listed.more, names: names)
        }
        let (kvs, more) = try await client.listPage(prefix: prefix, after: lastKey, limit: 1, keysOnly: true)
        return ValuePage(kvs: kvs, withoutValues: Set(kvs.map(\.key)), more: more, names: [:])
    }

    /// Lists with values. The gateway refuses responses over its message
    /// limit (4 MB on etcd 3.3), so a refused page is retried smaller; nil
    /// when even a single value is too large.
    private func listingValues(
        _ list: (Int64) async throws -> (kvs: [KeyValue], more: Bool)
    ) async throws -> (kvs: [KeyValue], more: Bool)? {
        var limit = valuePageLimit
        while true {
            do {
                let listed = try await list(limit)
                valuePageLimit = min(Self.pageLimit, limit * 2)
                return listed
            } catch where Self.isTooLarge(error) && limit > 1 {
                limit = max(1, limit / 4)
                valuePageLimit = limit
            } catch where Self.isTooLarge(error) {
                return nil
            }
        }
    }

    /// A table row for one key; a value too large for the gateway is left out.
    public func row(forKey key: Data) async throws -> KeyRow? {
        guard let client else { return nil }
        let current = session
        do {
            guard let kv = try await client.range(RangeRequest(key: key)).kvs.first else { return nil }
            return KeyRow(kv, displayName: await recordNames(of: [kv], readIn: current)[kv.key])
        } catch where Self.isTooLarge(error) {
            return try await client.range(RangeRequest(key: key, keysOnly: true)).kvs.first
                .map { KeyRow($0, valueFetched: false) }
        }
    }

    // MARK: Search

    /// Every UTF-8 key on the server, keys only, in key order.
    func allKeyPaths() async throws -> [String] {
        let stamp = [session, changeCount, writeCount]
        if watchTask != nil, let searchKeys, searchKeys.stamp == stamp { return searchKeys.keys }
        guard let client else { return [] }
        var keys: [String] = []
        var cursor: Data?
        var more = true
        while more {
            try Task.checkCancellation()
            let page = try await client.listPage(prefix: "", after: cursor, limit: Self.pageLimit, keysOnly: true)
            keys += page.kvs.compactMap(\.keyString)
            cursor = page.kvs.last?.key
            more = page.more && cursor != nil
        }
        if stamp == [session, changeCount, writeCount] { searchKeys = (stamp, keys) }
        return keys
    }

    /// Reads the value of every key a mapping names, so the search finds keys
    /// by name. The watch keeps names current, so with it on this runs once
    /// per session and set of mappings.
    func loadAllNames() async throws {
        guard let naming else { return }
        let stamp = [session, namingChangeCount]
        if watchTask != nil, searchNamesStamp == stamp { return }
        for pattern in Self.namedPatterns(naming) {
            switch pattern {
            case .prefix(let prefix):
                var cursor: Data?
                var more = true
                while more {
                    try Task.checkCancellation()
                    let page = try await valuePage(under: prefix, after: cursor)
                    cursor = page.kvs.last?.key
                    more = page.more && cursor != nil
                }
            case .key(let key):
                _ = try await row(forKey: Data(key.utf8))
            }
        }
        if stamp == [session, namingChangeCount] { searchNamesStamp = stamp }
    }

    /// The patterns of mappings with a name field, less those another
    /// prefix already covers.
    nonisolated static func namedPatterns(_ naming: SchemaMappingConfiguration) -> [SchemaMappingRule.Pattern] {
        let patterns = naming.mappings.filter { $0.nameField != nil }.map(\.pattern)
        let prefixes = patterns.compactMap { pattern -> String? in
            if case .prefix(let prefix) = pattern { prefix } else { nil }
        }
        var seen = Set<SchemaMappingRule.Pattern>()
        return patterns.filter { pattern in
            guard seen.insert(pattern).inserted else { return false }
            switch pattern {
            case .prefix(let prefix): return !prefixes.contains { $0 != prefix && prefix.hasPrefix($0) }
            case .key(let key): return !prefixes.contains { key.hasPrefix($0) }
            }
        }
    }

    /// The gateway relays gRPC's refusal of an oversized response.
    nonisolated static func isTooLarge(_ error: any Error) -> Bool {
        guard case EtcdError.status(.resourceExhausted, let message) = error else { return false }
        return message.contains("larger than max")
    }

    /// Reads one key by its raw bytes. Nil when it does not exist.
    public func value(forKey key: Data) async throws -> KeyValue? {
        guard let client else { return nil }
        return try await client.range(RangeRequest(key: key)).kvs.first
    }

    /// Reads one key as of an earlier revision.
    public func value(forKey key: Data, revision: Int64) async throws -> KeyValue? {
        guard let client else { return nil }
        return try await client.range(RangeRequest(key: key, revision: revision)).kvs.first
    }

    // MARK: Writes

    /// A guarded save; see `EtcdClient.save`.
    public func save(
        key: Data, value: Data, expectedModRevision: Int64, lease: Int64
    ) async throws -> EtcdClient.SaveOutcome {
        let outcome = try await requireClient().save(
            key: key, value: value, expectedModRevision: expectedModRevision, lease: lease)
        if case .written = outcome {
            writeCount += 1
            queueNames(of: [KeyValue(key: key, value: value)])
        }
        return outcome
    }

    /// Writes a new key, failing rather than overwriting when it exists.
    public func createKey(_ key: Data, value: Data) async throws {
        if case .conflict = try await save(key: key, value: value, expectedModRevision: 0, lease: 0) {
            throw KeyExistsError(key: key)
        }
    }

    /// Creates a key from editor text, stored as typed; a mapping only
    /// advises on it. See SPEC 5.5.
    public func createKey(_ key: Data, text: String) async throws {
        try await createKey(key, value: Data(text.utf8))
    }

    /// Renames a key: its value and lease move to `newKey` in one transaction.
    /// An existing `newKey` is overwritten only when `replacing` names its mod
    /// revision. Keys below the key stay.
    public func renameKey(_ key: Data, to newKey: Data, replacing: Int64 = 0) async throws -> KeyCopyOutcome {
        guard newKey != key, !newKey.isEmpty else { return .done }
        let client = try requireClient()
        var replacing = replacing
        // A change to either key between the read and the write fails a
        // compare; the next attempt starts from what is there now.
        for _ in 0..<3 {
            guard let source = try await client.range(RangeRequest(key: key)).kvs.first else {
                throw KeyNotFoundError(key: key)
            }
            switch try await client.rename(source, to: newKey, replacing: replacing) {
            case .renamed:
                writeCount += 1
                queueNames(of: [KeyValue(key: key), KeyValue(key: newKey, value: source.value)])
                return .done
            case .targetChanged(let current?):
                return .targetExists(modRevision: current.modRevision)
            case .targetChanged(nil):
                // The key to overwrite is gone, so a plain rename fits now.
                replacing = 0
            case .sourceChanged(nil):
                throw KeyNotFoundError(key: key)
            case .sourceChanged:
                continue
            }
        }
        throw KeyKeptChangingError(key: key)
    }

    /// Copies a key's value and lease to `newKey`. An existing `newKey` is
    /// overwritten only when `replacing` names its mod revision.
    public func duplicateKey(_ key: Data, to newKey: Data, replacing: Int64 = 0) async throws -> KeyCopyOutcome {
        guard newKey != key, !newKey.isEmpty else { return .done }
        let client = try requireClient()
        var replacing = replacing
        for _ in 0..<3 {
            guard let source = try await client.range(RangeRequest(key: key)).kvs.first else {
                throw KeyNotFoundError(key: key)
            }
            switch try await client.save(
                key: newKey, value: source.value, expectedModRevision: replacing, lease: source.lease)
            {
            case .written:
                writeCount += 1
                queueNames(of: [KeyValue(key: newKey, value: source.value)])
                return .done
            case .conflict(let current?):
                return .targetExists(modRevision: current.modRevision)
            case .conflict(nil):
                // The key to overwrite is gone, so a plain create fits now.
                replacing = 0
            }
        }
        throw KeyKeptChangingError(key: key)
    }

    /// Counts what a delete would remove, for the confirmation. With a
    /// `subtreePrefix` everything below the key goes too.
    public func planDelete(key: Data, subtreePrefix: String?) async throws -> DeletePlan {
        let client = try requireClient()
        var affected: Int64 = 0
        if !key.isEmpty {
            affected += try await client.range(RangeRequest(key: key, countOnly: true)).count
        }
        if let subtreePrefix {
            affected += try await client.count(prefix: Data(subtreePrefix.utf8))
        }
        return DeletePlan(key: key, subtreePrefix: subtreePrefix, affected: affected)
    }

    /// The key and its subtree in one transaction. The subtree range starts
    /// at the prefix, so siblings that merely share the key's name survive.
    public func delete(_ plan: DeletePlan) async throws {
        var ops: [RequestOp] = []
        if !plan.key.isEmpty {
            ops.append(.deleteRange(DeleteRangeRequest(key: plan.key)))
        }
        if let subtreePrefix = plan.subtreePrefix {
            let prefix = Data(subtreePrefix.utf8)
            ops.append(.deleteRange(DeleteRangeRequest(key: prefix, rangeEnd: prefixEnd(prefix))))
        }
        _ = try await requireClient().txn(TxnRequest(success: ops))
        writeCount += 1
    }

    // MARK: Leases

    /// Lease listing needs etcd 3.3; the control is hidden below that.
    public var canListLeases: Bool { client?.capabilities.canListLeases ?? false }

    public func leaseIDs() async throws -> [Int64] {
        try await requireClient().leases()
    }

    public func leaseTimeToLive(_ id: Int64) async throws -> LeaseTimeToLiveResponse {
        try await requireClient().leaseTimeToLive(id: id, keys: true)
    }

    /// Revoking deletes every key attached to the lease.
    public func revokeLease(_ id: Int64) async throws {
        try await requireClient().leaseRevoke(id: id)
        writeCount += 1
    }

    private func requireClient() throws -> EtcdClient {
        guard let client else { throw NotConnectedError() }
        return client
    }

    public nonisolated static func message(for error: any Error) -> String {
        if isTooLarge(error), case EtcdError.status(_, let detail) = error {
            return String(
                localized: "The etcd HTTP gateway refused the response because it is larger than the gateway's limit (\(detail)).",
                bundle: .module)
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }
}

/// What a rename or duplicate found at the new key.
public enum KeyCopyOutcome: Equatable, Sendable {
    case done
    /// The new key exists; pass its mod revision as `replacing` to overwrite it.
    case targetExists(modRevision: Int64)
}

/// The keys kept changing during a rename or duplicate.
public struct KeyKeptChangingError: LocalizedError, Sendable {
    public let key: Data
    public var errorDescription: String? {
        String(localized: "\(displayString(for: key)) kept changing while it was being copied. Try again.", bundle: .module)
    }
}
