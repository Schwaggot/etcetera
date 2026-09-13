import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Renaming and duplicating keys", .tags(.unit))
struct RenameTests {
    let transport = MockTransport()
    private let old = Data("a/old".utf8)
    private let new = Data("a/new".utf8)

    /// A failed rename; the failure branch read back both keys.
    private func renameFailed(source: String?, target: String?) -> String {
        let source = Gateway.range(source.map { [$0] } ?? [])
        let target = Gateway.range(target.map { [$0] } ?? [])
        return #"{"header": {"revision": "12"}, "responses": [{"response_range": \#(source)}, {"response_range": \#(target)}]}"#
    }

    private func compares(_ body: [String: Any]?) throws -> [[String: Any]] {
        try #require(body?["compare"] as? [[String: Any]])
    }

    private func success(_ body: [String: Any]?) throws -> [[String: Any]] {
        try #require(body?["success"] as? [[String: Any]])
    }

    // MARK: Rename

    @Test("A rename moves value and lease in one transaction guarded on both keys")
    func renames() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(old, value: Data("v".utf8), modRevision: 7, lease: 42)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        #expect(try await connection.renameKey(old, to: new) == .done)
        #expect(connection.writeCount == 1)

        let body = Gateway.txnBodies(transport).first
        let compares = try compares(body)
        #expect(compares.map { $0["key"] as? String } == [old.base64EncodedString(), new.base64EncodedString()])
        #expect(compares[0]["target"] as? String == "MOD")
        #expect(compares[0]["mod_revision"] as? String == "7")
        #expect(compares[1]["target"] as? String == "CREATE")
        let success = try success(body)
        let put = try #require(success.first?["request_put"] as? [String: Any])
        #expect(put["key"] as? String == new.base64EncodedString())
        #expect(put["value"] as? String == Gateway.base64("v"))
        #expect(put["lease"] as? String == "42")
        let delete = try #require(success.last?["request_delete_range"] as? [String: Any])
        #expect(delete["key"] as? String == old.base64EncodedString())
    }

    @Test("Renaming onto an existing key asks first, naming its revision")
    func renameTargetExists() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(
            path: "/v3/kv/txn",
            json: renameFailed(source: Gateway.kv("a/old", modRevision: 7), target: Gateway.kv("a/new", modRevision: 5)))
        #expect(try await connection.renameKey(old, to: new) == .targetExists(modRevision: 5))
        #expect(connection.writeCount == 0)
    }

    @Test("Overwriting on rename is guarded on the revision the user agreed to replace")
    func renameOverwrites() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        #expect(try await connection.renameKey(old, to: new, replacing: 5) == .done)
        let compares = try compares(Gateway.txnBodies(transport).first)
        #expect(compares[1]["target"] as? String == "MOD")
        #expect(compares[1]["mod_revision"] as? String == "5")
    }

    @Test("A key to overwrite that is gone meanwhile makes it a plain rename")
    func renameOverwriteTargetGone() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: renameFailed(source: Gateway.kv("a/old", modRevision: 7), target: nil))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        #expect(try await connection.renameKey(old, to: new, replacing: 5) == .done)
        let compares = try compares(Gateway.txnBodies(transport).last)
        #expect(compares[1]["target"] as? String == "CREATE")
    }

    @Test("A change during the rename is retried with the new value")
    func renameRetriesAfterChange() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", value: "v1", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: renameFailed(source: Gateway.kv("a/old", modRevision: 9), target: nil))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", value: "v2", modRevision: 9)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        #expect(try await connection.renameKey(old, to: new) == .done)
        let bodies = Gateway.txnBodies(transport)
        #expect(bodies.count == 2)
        #expect(try compares(bodies.last)[0]["mod_revision"] as? String == "9")
        let put = try #require(try success(bodies.last).first?["request_put"] as? [String: Any])
        #expect(put["value"] as? String == Gateway.base64("v2"))
    }

    @Test("A key deleted before or during the rename says so")
    func renameSourceGone() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await #expect(throws: KeyNotFoundError.self) {
            try await connection.renameKey(old, to: new)
        }
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: renameFailed(source: nil, target: nil))
        await #expect(throws: KeyNotFoundError.self) {
            try await connection.renameKey(old, to: new)
        }
    }

    @Test("Renaming a key to itself sends nothing, since the transaction would delete it")
    func renameSameKey() async throws {
        let connection = try await connectedModel(transport)
        #expect(try await connection.renameKey(old, to: old) == .done)
        #expect(Gateway.txnBodies(transport).isEmpty)
        #expect(Gateway.rangeBodies(transport).count == 1)
    }

    // MARK: Duplicate

    @Test("A duplicate copies value and lease to a new key and leaves the original")
    func duplicates() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(old, value: Data("v".utf8), modRevision: 7, lease: 42)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        #expect(try await connection.duplicateKey(old, to: new) == .done)
        #expect(connection.writeCount == 1)

        let body = Gateway.txnBodies(transport).first
        let compares = try compares(body)
        #expect(compares.count == 1)
        #expect(compares[0]["key"] as? String == new.base64EncodedString())
        #expect(compares[0]["target"] as? String == "CREATE")
        let success = try success(body)
        #expect(success.count == 1)
        let put = try #require(success.first?["request_put"] as? [String: Any])
        #expect(put["key"] as? String == new.base64EncodedString())
        #expect(put["value"] as? String == Gateway.base64("v"))
        #expect(put["lease"] as? String == "42")
    }

    @Test("Duplicating onto an existing key asks first, and overwriting is guarded on its revision")
    func duplicateTargetExists() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnConflict(current: Gateway.kv("a/new", modRevision: 5)))
        #expect(try await connection.duplicateKey(old, to: new) == .targetExists(modRevision: 5))
        #expect(connection.writeCount == 0)

        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/old", modRevision: 7)]))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        #expect(try await connection.duplicateKey(old, to: new, replacing: 5) == .done)
        let compares = try compares(Gateway.txnBodies(transport).last)
        #expect(compares[0]["target"] as? String == "MOD")
        #expect(compares[0]["mod_revision"] as? String == "5")
    }
}
