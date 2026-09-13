import EtcdKit
import EtceteraCore
import Foundation
import Testing

/// Gateway JSON for arranging a MockTransport.
enum Gateway {
    static func kv(_ key: String, value: String = "", modRevision: Int64 = 1) -> String {
        kv(Data(key.utf8), value: Data(value.utf8), modRevision: modRevision)
    }

    static func kv(_ key: Data, value: Data = Data(), modRevision: Int64 = 1, lease: Int64 = 0) -> String {
        """
        {"key": "\(key.base64EncodedString())", "value": "\(value.base64EncodedString())", \
        "create_revision": "1", "mod_revision": "\(modRevision)", "version": "1", "lease": "\(lease)"}
        """
    }

    static func txnWritten(revision: Int64) -> String {
        #"{"header": {"revision": "\#(revision)"}, "succeeded": true, "responses": [{"response_put": {"header": {"revision": "\#(revision)"}}}]}"#
    }

    /// A failed compare; the failure branch read back `current`, or nothing
    /// when the key was deleted.
    static func txnConflict(current: String?) -> String {
        #"{"header": {"revision": "12"}, "responses": [{"response_range": \#(range(current.map { [$0] } ?? []))}]}"#
    }

    static func txnBodies(_ transport: MockTransport) -> [[String: Any]] {
        transport.requests(for: "/v3/kv/txn").compactMap(\.json)
    }

    static func range(_ kvs: [String], more: Bool = false) -> String {
        #"{"kvs": [\#(kvs.joined(separator: ", "))], "count": "\#(kvs.count)", "more": \#(more)}"#
    }

    static func range(keys: [String], more: Bool = false) -> String {
        range(keys.map { kv($0) }, more: more)
    }

    static func rangeBodies(_ transport: MockTransport) -> [[String: Any]] {
        transport.requests(for: "/v3/kv/range").compactMap(\.json)
    }

    static func base64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }
}

/// A model connected through `transport`, with the root's first page loaded.
@MainActor
func connectedModel(_ transport: MockTransport, rootKeys: [String] = []) async throws -> ConnectionModel {
    transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
    transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: rootKeys))
    let model = ConnectionModel(transport: transport)
    await model.connect()
    try #require(model.phase == .connected)
    return model
}
