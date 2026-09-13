import Foundation

// Request and response types mirror the messages in etcd's rpc.proto, which
// is the authoritative schema. The gateway emits the original proto field
// names (snake_case, except where the proto itself says otherwise, such as
// LeaseGrantRequest.TTL), so every type spells its keys explicitly.

// MARK: - Common

public struct ResponseHeader: Codable, Hashable, Sendable {
    @StringUInt64 public var clusterID: UInt64
    @StringUInt64 public var memberID: UInt64
    @StringInt64 public var revision: Int64
    @StringUInt64 public var raftTerm: UInt64

    public init(clusterID: UInt64 = 0, memberID: UInt64 = 0, revision: Int64 = 0, raftTerm: UInt64 = 0) {
        self.clusterID = clusterID
        self.memberID = memberID
        self.revision = revision
        self.raftTerm = raftTerm
    }

    enum CodingKeys: String, CodingKey {
        case clusterID = "cluster_id"
        case memberID = "member_id"
        case revision = "revision"
        case raftTerm = "raft_term"
    }
}

public struct KeyValue: Codable, Hashable, Sendable {
    @Base64Data public var key: Data
    @StringInt64 public var createRevision: Int64
    @StringInt64 public var modRevision: Int64
    @StringInt64 public var version: Int64
    @Base64Data public var value: Data
    @StringInt64 public var lease: Int64

    public init(
        key: Data = Data(), createRevision: Int64 = 0, modRevision: Int64 = 0,
        version: Int64 = 0, value: Data = Data(), lease: Int64 = 0
    ) {
        self.key = key
        self.createRevision = createRevision
        self.modRevision = modRevision
        self.version = version
        self.value = value
        self.lease = lease
    }

    enum CodingKeys: String, CodingKey {
        case key = "key"
        case createRevision = "create_revision"
        case modRevision = "mod_revision"
        case version = "version"
        case value = "value"
        case lease = "lease"
    }

    /// The key as text, or nil when it is not valid UTF-8.
    public var keyString: String? { String(data: key, encoding: .utf8) }
}

// MARK: - Range

public struct RangeRequest: Codable, Sendable {
    public enum SortOrder: String, Codable, Sendable {
        case none = "NONE"
        case ascend = "ASCEND"
        case descend = "DESCEND"
    }

    public enum SortTarget: String, Codable, Sendable {
        case key = "KEY"
        case version = "VERSION"
        case create = "CREATE"
        case mod = "MOD"
        case value = "VALUE"
    }

    @Base64Data public var key: Data
    @Base64Data public var rangeEnd: Data
    @StringInt64 public var limit: Int64
    @StringInt64 public var revision: Int64
    public var sortOrder: SortOrder?
    public var sortTarget: SortTarget?
    public var serializable: Bool?
    public var keysOnly: Bool?
    public var countOnly: Bool?
    @StringInt64 public var minModRevision: Int64
    @StringInt64 public var maxModRevision: Int64
    @StringInt64 public var minCreateRevision: Int64
    @StringInt64 public var maxCreateRevision: Int64

    public init(
        key: Data, rangeEnd: Data = Data(), limit: Int64 = 0, revision: Int64 = 0,
        sortOrder: SortOrder? = nil, sortTarget: SortTarget? = nil,
        serializable: Bool? = nil, keysOnly: Bool? = nil, countOnly: Bool? = nil,
        minModRevision: Int64 = 0, maxModRevision: Int64 = 0,
        minCreateRevision: Int64 = 0, maxCreateRevision: Int64 = 0
    ) {
        self.key = key
        self.rangeEnd = rangeEnd
        self.limit = limit
        self.revision = revision
        self.sortOrder = sortOrder
        self.sortTarget = sortTarget
        self.serializable = serializable
        self.keysOnly = keysOnly
        self.countOnly = countOnly
        self.minModRevision = minModRevision
        self.maxModRevision = maxModRevision
        self.minCreateRevision = minCreateRevision
        self.maxCreateRevision = maxCreateRevision
    }

    enum CodingKeys: String, CodingKey {
        case key = "key"
        case rangeEnd = "range_end"
        case limit = "limit"
        case revision = "revision"
        case sortOrder = "sort_order"
        case sortTarget = "sort_target"
        case serializable
        case keysOnly = "keys_only"
        case countOnly = "count_only"
        case minModRevision = "min_mod_revision"
        case maxModRevision = "max_mod_revision"
        case minCreateRevision = "min_create_revision"
        case maxCreateRevision = "max_create_revision"
    }
}

public struct RangeResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var kvs: [KeyValue]
    public var more: Bool
    public var count: Int64

    public init(header: ResponseHeader = ResponseHeader(), kvs: [KeyValue] = [], more: Bool = false, count: Int64 = 0) {
        self.header = header
        self.kvs = kvs
        self.more = more
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case header, kvs, more, count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        kvs = try container.decodeIfPresent([KeyValue].self, forKey: .kvs) ?? []
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ?? false
        count = try container.decodeIfPresent(StringInt64.self, forKey: .count)?.wrappedValue ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(kvs, forKey: .kvs)
        try container.encode(more, forKey: .more)
        try container.encode(StringInt64(wrappedValue: count), forKey: .count)
    }
}

// MARK: - Put

public struct PutRequest: Codable, Sendable {
    @Base64Data public var key: Data
    @Base64Data public var value: Data
    @StringInt64 public var lease: Int64
    public var prevKv: Bool?
    public var ignoreValue: Bool?
    public var ignoreLease: Bool?

    public init(
        key: Data, value: Data, lease: Int64 = 0,
        prevKv: Bool? = nil, ignoreValue: Bool? = nil, ignoreLease: Bool? = nil
    ) {
        self.key = key
        self.value = value
        self.lease = lease
        self.prevKv = prevKv
        self.ignoreValue = ignoreValue
        self.ignoreLease = ignoreLease
    }

    enum CodingKeys: String, CodingKey {
        case key = "key"
        case value = "value"
        case lease = "lease"
        case prevKv = "prev_kv"
        case ignoreValue = "ignore_value"
        case ignoreLease = "ignore_lease"
    }
}

public struct PutResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var prevKv: KeyValue?

    public init(header: ResponseHeader = ResponseHeader(), prevKv: KeyValue? = nil) {
        self.header = header
        self.prevKv = prevKv
    }

    enum CodingKeys: String, CodingKey {
        case header
        case prevKv = "prev_kv"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        prevKv = try container.decodeIfPresent(KeyValue.self, forKey: .prevKv)
    }
}

// MARK: - Delete

public struct DeleteRangeRequest: Codable, Sendable {
    @Base64Data public var key: Data
    @Base64Data public var rangeEnd: Data
    public var prevKv: Bool?

    public init(key: Data, rangeEnd: Data = Data(), prevKv: Bool? = nil) {
        self.key = key
        self.rangeEnd = rangeEnd
        self.prevKv = prevKv
    }

    enum CodingKeys: String, CodingKey {
        case key = "key"
        case rangeEnd = "range_end"
        case prevKv = "prev_kv"
    }
}

public struct DeleteRangeResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var deleted: Int64
    public var prevKvs: [KeyValue]

    public init(header: ResponseHeader = ResponseHeader(), deleted: Int64 = 0, prevKvs: [KeyValue] = []) {
        self.header = header
        self.deleted = deleted
        self.prevKvs = prevKvs
    }

    enum CodingKeys: String, CodingKey {
        case header, deleted
        case prevKvs = "prev_kvs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        deleted = try container.decodeIfPresent(StringInt64.self, forKey: .deleted)?.wrappedValue ?? 0
        prevKvs = try container.decodeIfPresent([KeyValue].self, forKey: .prevKvs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(StringInt64(wrappedValue: deleted), forKey: .deleted)
        try container.encode(prevKvs, forKey: .prevKvs)
    }
}

// MARK: - Txn

public struct Compare: Codable, Sendable {
    public enum Result: String, Codable, Sendable {
        case equal = "EQUAL"
        case greater = "GREATER"
        case less = "LESS"
        case notEqual = "NOT_EQUAL"
    }

    public enum Target: String, Codable, Sendable {
        case version = "VERSION"
        case create = "CREATE"
        case mod = "MOD"
        case value = "VALUE"
        case lease = "LEASE"
    }

    public var result: Result
    public var target: Target
    @Base64Data public var key: Data
    // Exactly one of the union fields is set, matching `target`.
    public var version: StringInt64?
    public var createRevision: StringInt64?
    public var modRevision: StringInt64?
    public var value: Base64Data?
    public var lease: StringInt64?
    @Base64Data public var rangeEnd: Data

    enum CodingKeys: String, CodingKey {
        case result, target
        case key = "key"
        case version
        case createRevision = "create_revision"
        case modRevision = "mod_revision"
        case value
        case lease
        case rangeEnd = "range_end"
    }

    public static func modRevision(_ key: Data, _ result: Result, _ revision: Int64) -> Compare {
        var compare = Compare(result: result, target: .mod, key: key)
        compare.modRevision = StringInt64(wrappedValue: revision)
        return compare
    }

    public static func createRevision(_ key: Data, _ result: Result, _ revision: Int64) -> Compare {
        var compare = Compare(result: result, target: .create, key: key)
        compare.createRevision = StringInt64(wrappedValue: revision)
        return compare
    }

    public static func value(_ key: Data, _ result: Result, _ value: Data) -> Compare {
        var compare = Compare(result: result, target: .value, key: key)
        compare.value = Base64Data(wrappedValue: value)
        return compare
    }

    public init(result: Result, target: Target, key: Data, rangeEnd: Data = Data()) {
        self.result = result
        self.target = target
        self.key = key
        self.rangeEnd = rangeEnd
    }
}

public indirect enum RequestOp: Codable, Sendable {
    case range(RangeRequest)
    case put(PutRequest)
    case deleteRange(DeleteRangeRequest)
    case txn(TxnRequest)

    enum CodingKeys: String, CodingKey {
        case range = "request_range"
        case put = "request_put"
        case deleteRange = "request_delete_range"
        case txn = "request_txn"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .range(let request): try container.encode(request, forKey: .range)
        case .put(let request): try container.encode(request, forKey: .put)
        case .deleteRange(let request): try container.encode(request, forKey: .deleteRange)
        case .txn(let request): try container.encode(request, forKey: .txn)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let request = try container.decodeIfPresent(RangeRequest.self, forKey: .range) {
            self = .range(request)
        } else if let request = try container.decodeIfPresent(PutRequest.self, forKey: .put) {
            self = .put(request)
        } else if let request = try container.decodeIfPresent(DeleteRangeRequest.self, forKey: .deleteRange) {
            self = .deleteRange(request)
        } else if let request = try container.decodeIfPresent(TxnRequest.self, forKey: .txn) {
            self = .txn(request)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "empty RequestOp"))
        }
    }
}

public indirect enum ResponseOp: Codable, Sendable {
    case range(RangeResponse)
    case put(PutResponse)
    case deleteRange(DeleteRangeResponse)
    case txn(TxnResponse)

    enum CodingKeys: String, CodingKey {
        case range = "response_range"
        case put = "response_put"
        case deleteRange = "response_delete_range"
        case txn = "response_txn"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let response = try container.decodeIfPresent(RangeResponse.self, forKey: .range) {
            self = .range(response)
        } else if let response = try container.decodeIfPresent(PutResponse.self, forKey: .put) {
            self = .put(response)
        } else if let response = try container.decodeIfPresent(DeleteRangeResponse.self, forKey: .deleteRange) {
            self = .deleteRange(response)
        } else if let response = try container.decodeIfPresent(TxnResponse.self, forKey: .txn) {
            self = .txn(response)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "empty ResponseOp"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .range(let response): try container.encode(response, forKey: .range)
        case .put(let response): try container.encode(response, forKey: .put)
        case .deleteRange(let response): try container.encode(response, forKey: .deleteRange)
        case .txn(let response): try container.encode(response, forKey: .txn)
        }
    }
}

public struct TxnRequest: Codable, Sendable {
    public var compare: [Compare]
    public var success: [RequestOp]
    public var failure: [RequestOp]

    public init(compare: [Compare] = [], success: [RequestOp] = [], failure: [RequestOp] = []) {
        self.compare = compare
        self.success = success
        self.failure = failure
    }
}

public struct TxnResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var succeeded: Bool
    public var responses: [ResponseOp]

    public init(header: ResponseHeader = ResponseHeader(), succeeded: Bool = false, responses: [ResponseOp] = []) {
        self.header = header
        self.succeeded = succeeded
        self.responses = responses
    }

    enum CodingKeys: String, CodingKey {
        case header, succeeded, responses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        // Absent means false, which is exactly the failed-compare case.
        succeeded = try container.decodeIfPresent(Bool.self, forKey: .succeeded) ?? false
        responses = try container.decodeIfPresent([ResponseOp].self, forKey: .responses) ?? []
    }
}

// MARK: - Compaction

public struct CompactionRequest: Codable, Sendable {
    @StringInt64 public var revision: Int64
    public var physical: Bool?

    public init(revision: Int64, physical: Bool? = nil) {
        self.revision = revision
        self.physical = physical
    }

    enum CodingKeys: String, CodingKey {
        case revision = "revision"
        case physical
    }
}

// MARK: - Watch

public struct WatchCreateRequest: Codable, Sendable {
    @Base64Data public var key: Data
    @Base64Data public var rangeEnd: Data
    @StringInt64 public var startRevision: Int64
    public var progressNotify: Bool?
    public var prevKv: Bool?

    public init(
        key: Data, rangeEnd: Data = Data(), startRevision: Int64 = 0,
        progressNotify: Bool? = nil, prevKv: Bool? = nil
    ) {
        self.key = key
        self.rangeEnd = rangeEnd
        self.startRevision = startRevision
        self.progressNotify = progressNotify
        self.prevKv = prevKv
    }

    enum CodingKeys: String, CodingKey {
        case key = "key"
        case rangeEnd = "range_end"
        case startRevision = "start_revision"
        case progressNotify = "progress_notify"
        case prevKv = "prev_kv"
    }
}

/// One decoded event from a watch stream.
public struct WatchEvent: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case put = "PUT"
        case delete = "DELETE"
    }

    public var kind: Kind
    public var kv: KeyValue
    public var prevKv: KeyValue?
    /// Revision of the batch header this event arrived in.
    public var revision: Int64

    public init(kind: Kind, kv: KeyValue, prevKv: KeyValue? = nil, revision: Int64 = 0) {
        self.kind = kind
        self.kv = kv
        self.prevKv = prevKv
        self.revision = revision
    }
}

/// Wire shape of one line in the watch stream: a `result` envelope around a
/// WatchResponse, or an `error` object when the stream fails server-side.
struct WatchStreamLine: Decodable {
    var result: WatchResponseBody?
    var error: GatewayErrorMapper.ErrorBody?
}

struct WatchResponseBody: Decodable {
    struct Event: Decodable {
        var type: WatchEvent.Kind?
        var kv: KeyValue?
        var prevKv: KeyValue?

        enum CodingKeys: String, CodingKey {
            case type, kv
            case prevKv = "prev_kv"
        }
    }

    var header: ResponseHeader?
    var created: Bool?
    var canceled: Bool?
    var compactRevision: StringInt64?
    var cancelReason: String?
    var events: [Event]?

    enum CodingKeys: String, CodingKey {
        case header, created, canceled, events
        case compactRevision = "compact_revision"
        case cancelReason = "cancel_reason"
    }
}

// MARK: - Lease

public struct LeaseGrantRequest: Codable, Sendable {
    // The proto declares TTL and ID, so those are the JSON keys.
    @StringInt64 public var ttl: Int64
    @StringInt64 public var id: Int64

    public init(ttl: Int64, id: Int64 = 0) {
        self.ttl = ttl
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case ttl = "TTL"
        case id = "ID"
    }
}

public struct LeaseGrantResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var id: Int64
    public var ttl: Int64
    public var error: String

    enum CodingKeys: String, CodingKey {
        case header
        case id = "ID"
        case ttl = "TTL"
        case error
    }

    public init(header: ResponseHeader = ResponseHeader(), id: Int64 = 0, ttl: Int64 = 0, error: String = "") {
        self.header = header
        self.id = id
        self.ttl = ttl
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        id = try container.decodeIfPresent(StringInt64.self, forKey: .id)?.wrappedValue ?? 0
        ttl = try container.decodeIfPresent(StringInt64.self, forKey: .ttl)?.wrappedValue ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(StringInt64(wrappedValue: id), forKey: .id)
        try container.encode(StringInt64(wrappedValue: ttl), forKey: .ttl)
        try container.encode(error, forKey: .error)
    }
}

public struct LeaseRevokeRequest: Codable, Sendable {
    @StringInt64 public var id: Int64

    public init(id: Int64) {
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
    }
}

public struct LeaseTimeToLiveRequest: Codable, Sendable {
    @StringInt64 public var id: Int64
    public var keys: Bool?

    public init(id: Int64, keys: Bool? = nil) {
        self.id = id
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case keys
    }
}

public struct LeaseTimeToLiveResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var id: Int64
    /// Remaining TTL in seconds. -1 means the lease has expired.
    public var ttl: Int64
    public var grantedTTL: Int64
    public var keys: [Data]

    enum CodingKeys: String, CodingKey {
        case header
        case id = "ID"
        case ttl = "TTL"
        case grantedTTL = "grantedTTL"
        case keys
    }

    public init(header: ResponseHeader = ResponseHeader(), id: Int64 = 0, ttl: Int64 = 0, grantedTTL: Int64 = 0, keys: [Data] = []) {
        self.header = header
        self.id = id
        self.ttl = ttl
        self.grantedTTL = grantedTTL
        self.keys = keys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        id = try container.decodeIfPresent(StringInt64.self, forKey: .id)?.wrappedValue ?? 0
        ttl = try container.decodeIfPresent(StringInt64.self, forKey: .ttl)?.wrappedValue ?? 0
        grantedTTL = try container.decodeIfPresent(StringInt64.self, forKey: .grantedTTL)?.wrappedValue ?? 0
        keys = try container.decodeIfPresent([Base64Data].self, forKey: .keys)?.map(\.wrappedValue) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(StringInt64(wrappedValue: id), forKey: .id)
        try container.encode(StringInt64(wrappedValue: ttl), forKey: .ttl)
        try container.encode(StringInt64(wrappedValue: grantedTTL), forKey: .grantedTTL)
        try container.encode(keys.map { Base64Data(wrappedValue: $0) }, forKey: .keys)
    }
}

struct LeaseLeasesResponse: Decodable {
    struct LeaseStatus: Decodable {
        var id: StringInt64?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
        }
    }

    var header: ResponseHeader?
    var leases: [LeaseStatus]?
}

// MARK: - Maintenance and cluster

public struct StatusResponse: Codable, Sendable {
    public var header: ResponseHeader
    public var version: String
    public var dbSize: Int64
    /// Only reported by etcd 3.4 and later; nil before that.
    public var dbSizeInUse: Int64?
    public var leader: UInt64
    public var raftIndex: UInt64
    public var raftTerm: UInt64
    public var raftAppliedIndex: UInt64
    public var errors: [String]
    public var isLearner: Bool

    enum CodingKeys: String, CodingKey {
        case header, version, leader, errors
        case dbSize
        case dbSizeInUse
        case raftIndex
        case raftTerm
        case raftAppliedIndex
        case isLearner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(ResponseHeader.self, forKey: .header) ?? ResponseHeader()
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        dbSize = try container.decodeIfPresent(StringInt64.self, forKey: .dbSize)?.wrappedValue ?? 0
        dbSizeInUse = try container.decodeIfPresent(StringInt64.self, forKey: .dbSizeInUse)?.wrappedValue
        leader = try container.decodeIfPresent(StringUInt64.self, forKey: .leader)?.wrappedValue ?? 0
        raftIndex = try container.decodeIfPresent(StringUInt64.self, forKey: .raftIndex)?.wrappedValue ?? 0
        raftTerm = try container.decodeIfPresent(StringUInt64.self, forKey: .raftTerm)?.wrappedValue ?? 0
        raftAppliedIndex = try container.decodeIfPresent(StringUInt64.self, forKey: .raftAppliedIndex)?.wrappedValue ?? 0
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        isLearner = try container.decodeIfPresent(Bool.self, forKey: .isLearner) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(version, forKey: .version)
        try container.encode(StringInt64(wrappedValue: dbSize), forKey: .dbSize)
        try container.encodeIfPresent(dbSizeInUse.map { StringInt64(wrappedValue: $0) }, forKey: .dbSizeInUse)
        try container.encode(StringUInt64(wrappedValue: leader), forKey: .leader)
        try container.encode(StringUInt64(wrappedValue: raftIndex), forKey: .raftIndex)
        try container.encode(StringUInt64(wrappedValue: raftTerm), forKey: .raftTerm)
        try container.encode(StringUInt64(wrappedValue: raftAppliedIndex), forKey: .raftAppliedIndex)
        try container.encode(errors, forKey: .errors)
        try container.encode(isLearner, forKey: .isLearner)
    }
}

public struct Member: Codable, Hashable, Sendable {
    @StringUInt64 public var id: UInt64
    public var name: String
    public var peerURLs: [String]
    public var clientURLs: [String]
    public var isLearner: Bool

    // The proto spells these ID, peerURLs, clientURLs.
    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name
        case peerURLs
        case clientURLs
        case isLearner
    }

    public init(id: UInt64 = 0, name: String = "", peerURLs: [String] = [], clientURLs: [String] = [], isLearner: Bool = false) {
        self.id = id
        self.name = name
        self.peerURLs = peerURLs
        self.clientURLs = clientURLs
        self.isLearner = isLearner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(StringUInt64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        peerURLs = try container.decodeIfPresent([String].self, forKey: .peerURLs) ?? []
        clientURLs = try container.decodeIfPresent([String].self, forKey: .clientURLs) ?? []
        isLearner = try container.decodeIfPresent(Bool.self, forKey: .isLearner) ?? false
    }
}

struct MemberListResponse: Decodable {
    var header: ResponseHeader?
    var members: [Member]?
}

// MARK: - Auth

struct AuthenticateRequest: Encodable {
    var name: String
    var password: String
}

struct AuthenticateResponse: Decodable {
    var token: String?
}

/// The `GET /version` endpoint, which predates the gateway.
public struct VersionInfo: Codable, Sendable {
    public var etcdserver: String
    public var etcdcluster: String?

    public init(etcdserver: String, etcdcluster: String? = nil) {
        self.etcdserver = etcdserver
        self.etcdcluster = etcdcluster
    }
}

/// An empty request or response body.
struct EmptyMessage: Codable {}
