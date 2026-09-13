import Foundation

/// One child of a tree node, produced by splitting keys on a separator.
/// A node can hold a value and have children at the same time; both flags
/// can be true.
public struct TreeNode: Sendable, Hashable {
    /// The path segment, such as "app" for key "/config/app".
    public var name: String
    /// The full key up to and including this segment, without a trailing
    /// separator: "/config/app".
    public var path: String
    /// A key exists at exactly this path.
    public var isLeaf: Bool
    /// Keys exist below this path.
    public var hasChildren: Bool

    public init(name: String, path: String, isLeaf: Bool, hasChildren: Bool) {
        self.name = name
        self.path = path
        self.isLeaf = isLeaf
        self.hasChildren = hasChildren
    }
}

/// Groups the keys directly under `prefix` into tree nodes by splitting at
/// `separator`. Pure function; the tree browser is built on it.
///
/// `prefix` is expected to end with the separator (or be empty). Keys that
/// do not start with `prefix` are ignored.
public func buildChildren(keys: [String], prefix: String, separator: Character) -> [TreeNode] {
    var order: [String] = []
    var leaves: Set<String> = []
    var branches: Set<String> = []

    for key in keys {
        guard key.hasPrefix(prefix), key.count > prefix.count else { continue }
        let remainder = key.dropFirst(prefix.count)
        if let separatorIndex = remainder.firstIndex(of: separator) {
            let segment = String(remainder[..<separatorIndex])
            // A trailing separator with nothing after it still marks a leaf
            // at "<prefix><segment>/" ... no: the key itself continues, so it
            // is a branch. Keys like "/a//b" produce an empty segment, which
            // is preserved as its own node.
            if !branches.contains(segment) && !leaves.contains(segment) {
                order.append(segment)
            }
            branches.insert(segment)
        } else {
            let segment = String(remainder)
            if !branches.contains(segment) && !leaves.contains(segment) {
                order.append(segment)
            }
            leaves.insert(segment)
        }
    }

    return order.map { segment in
        TreeNode(
            name: segment,
            path: prefix + segment,
            isLeaf: leaves.contains(segment),
            hasChildren: branches.contains(segment))
    }
}

public struct EtcdKeyError: Error, Sendable {
    public let key: Data
    public let reason: String
}

extension EtcdClient {
    /// Reads a single key. Nil when it does not exist.
    public func get(_ key: String) async throws -> KeyValue? {
        let response = try await range(RangeRequest(key: Data(key.utf8)))
        return response.kvs.first
    }

    /// Lists keys under a prefix, ascending by key. The empty prefix lists
    /// the whole keyspace. Without a limit (or with 0, as etcd reads it)
    /// every key is returned, fetched in pages.
    public func list(prefix: String, keysOnly: Bool = false, limit: Int64? = nil) async throws -> [KeyValue] {
        let pageSize: Int64 = 1000
        let limit = limit.flatMap { $0 > 0 ? $0 : nil }
        var kvs: [KeyValue] = []
        var lastKey: Data?
        while true {
            let remaining = limit.map { $0 - Int64(kvs.count) }
            let page = try await listPage(
                prefix: prefix, after: lastKey, limit: min(remaining ?? pageSize, pageSize), keysOnly: keysOnly)
            kvs += page.kvs
            guard page.more, let last = page.kvs.last, remaining.map({ $0 > Int64(page.kvs.count) }) ?? true
            else { return kvs }
            lastKey = last.key
        }
    }

    /// Number of keys under a prefix, without transferring them. Deletes
    /// show this before asking for confirmation.
    public func count(prefix: Data) async throws -> Int64 {
        try await range(
            RangeRequest(key: prefixStart(prefix), rangeEnd: prefixEnd(prefix), countOnly: true)
        ).count
    }

    /// One page of keys under a prefix, for callers that page explicitly.
    /// The next page starts at the last returned key with a zero byte
    /// appended (the smallest key strictly greater than it).
    /// `first` starts the page at that key itself and wins over `lastKey`.
    public func listPage(
        prefix: String, after lastKey: Data? = nil, from first: Data? = nil, limit: Int64, keysOnly: Bool = true
    ) async throws -> (kvs: [KeyValue], more: Bool) {
        let prefixData = Data(prefix.utf8)
        let start: Data
        if let first {
            start = first
        } else if let lastKey {
            start = lastKey + Data([0])
        } else {
            start = prefixStart(prefixData)
        }
        let response = try await range(
            RangeRequest(
                key: start,
                rangeEnd: prefixEnd(prefixData),
                limit: limit,
                sortOrder: .ascend,
                sortTarget: .key,
                keysOnly: keysOnly ? true : nil))
        return (response.kvs, response.more)
    }

    /// The tree browser primitive: the children directly under a prefix.
    /// Issues one range request for one page of keys. See SPEC 4.2.
    public func listChildren(
        of prefix: String, separator: Character = "/", limit: Int64 = 1000
    ) async throws -> (nodes: [TreeNode], more: Bool) {
        let normalized = prefix.isEmpty || prefix.hasSuffix(String(separator))
            ? prefix : prefix + String(separator)
        let (kvs, more) = try await listPage(prefix: normalized, limit: limit, keysOnly: true)
        let keys = try kvs.map { kv in
            guard let key = kv.keyString else {
                throw EtcdKeyError(key: kv.key, reason: "key is not valid UTF-8")
            }
            return key
        }
        return (buildChildren(keys: keys, prefix: normalized, separator: separator), more)
    }

    /// Writes a value, guarded by mod revision when given. A stale revision
    /// throws nothing; inspect the returned outcome. See SPEC 4.5: every
    /// guarded save is a transaction, never a bare put.
    public func put(_ key: String, value: Data, ifModRevision: Int64? = nil) async throws -> PutResponse {
        let keyData = Data(key.utf8)
        guard let expected = ifModRevision else {
            return try await put(PutRequest(key: keyData, value: value))
        }
        let outcome = try await save(key: keyData, value: value, expectedModRevision: expected)
        switch outcome {
        case .written(let response):
            return response
        case .conflict(let current):
            throw EtcdSaveConflict(current: current)
        }
    }

    /// The result of a guarded save.
    public enum SaveOutcome: Sendable {
        case written(PutResponse)
        /// Someone else wrote the key since it was loaded; here is what the
        /// store holds now (nil when the key was deleted).
        case conflict(current: KeyValue?)
    }

    /// Compare-and-swap on mod revision. An expected revision of 0 creates
    /// the key and fails when it already exists (createRevision == 0 only
    /// holds for keys that do not exist). Pass the key's `lease`, since a
    /// put without one detaches it.
    public func save(
        key: Data, value: Data, expectedModRevision: Int64, lease: Int64 = 0
    ) async throws -> SaveOutcome {
        let compare: Compare
        if expectedModRevision == 0 {
            compare = .createRevision(key, .equal, 0)
        } else {
            compare = .modRevision(key, .equal, expectedModRevision)
        }
        let request = TxnRequest(
            compare: [compare],
            success: [.put(PutRequest(key: key, value: value, lease: lease))],
            failure: [.range(RangeRequest(key: key))])
        let response = try await txn(request)
        if response.succeeded {
            if case .put(let putResponse)? = response.responses.first {
                return .written(putResponse)
            }
            return .written(PutResponse(header: response.header))
        }
        if case .range(let rangeResponse)? = response.responses.first {
            return .conflict(current: rangeResponse.kvs.first)
        }
        return .conflict(current: nil)
    }

    public enum RenameOutcome: Sendable {
        case renamed
        /// The source changed after it was read; nil when it was deleted.
        case sourceChanged(current: KeyValue?)
        /// The new key exists, or changed when replacing it; nil when it is gone.
        case targetChanged(current: KeyValue?)
    }

    /// Moves `source`'s value and lease to `newKey` and deletes the source,
    /// in one transaction. It fails rather than move a value that changed
    /// after `source` was read. `replacing` is the mod revision of an
    /// existing `newKey` to overwrite; 0 means `newKey` must not exist.
    public func rename(_ source: KeyValue, to newKey: Data, replacing: Int64 = 0) async throws -> RenameOutcome {
        let target: Compare =
            replacing == 0 ? .createRevision(newKey, .equal, 0) : .modRevision(newKey, .equal, replacing)
        let request = TxnRequest(
            compare: [.modRevision(source.key, .equal, source.modRevision), target],
            success: [
                .put(PutRequest(key: newKey, value: source.value, lease: source.lease)),
                .deleteRange(DeleteRangeRequest(key: source.key)),
            ],
            failure: [
                .range(RangeRequest(key: source.key, keysOnly: true)),
                .range(RangeRequest(key: newKey, keysOnly: true)),
            ])
        let response = try await txn(request)
        if response.succeeded { return .renamed }
        let found = response.responses.map { op -> KeyValue? in
            if case .range(let range) = op { return range.kvs.first }
            return nil
        }
        // Either compare can fail; the source's revision tells which.
        let current = found.first ?? nil
        guard current?.modRevision == source.modRevision else { return .sourceChanged(current: current) }
        return .targetChanged(current: found.count > 1 ? found[1] : nil)
    }
}

/// Thrown by the string-keyed `put(_:value:ifModRevision:)` convenience.
public struct EtcdSaveConflict: Error, Sendable {
    /// What the store holds now; nil when the key was deleted meanwhile.
    public let current: KeyValue?
}
