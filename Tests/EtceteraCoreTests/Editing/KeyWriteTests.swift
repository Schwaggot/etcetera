import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Creating and deleting keys", .tags(.unit))
struct KeyWriteTests {
    let transport = MockTransport()

    private func txnOps(_ index: Int = 0) throws -> [[String: Any]] {
        let body = try #require(Gateway.txnBodies(transport).dropFirst(index).first)
        return try #require(body["success"] as? [[String: Any]])
    }

    @Test("Creating a key compares createRevision == 0 and fails when the key exists")
    func createExisting() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnConflict(current: Gateway.kv("a")))
        await #expect(throws: KeyExistsError.self) {
            try await connection.createKey(Data("a".utf8), value: Data("v".utf8))
        }
        let body = try #require(Gateway.txnBodies(transport).first)
        let compare = try #require((body["compare"] as? [[String: Any]])?.first)
        #expect(compare["target"] as? String == "CREATE")
    }

    @Test("Creating an absent key writes it")
    func createNew() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 5))
        try await connection.createKey(Data("a".utf8), value: Data("v".utf8))
        let put = try #require(try txnOps().first?["request_put"] as? [String: Any])
        #expect(put["value"] as? String == Gateway.base64("v"))
    }

    @Test("A subtree delete counts the node's own key and everything below it")
    func subtreeCount() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: #"{"count": "1"}"#)
        transport.enqueue(path: "/v3/kv/range", json: #"{"count": "3"}"#)
        let plan = try await connection.planDelete(key: Data("a".utf8), subtreePrefix: "a/")
        #expect(plan.affected == 4)
        let bodies = Gateway.rangeBodies(transport).suffix(2)
        #expect(bodies.first?["key"] as? String == Gateway.base64("a"))
        #expect((bodies.first?["range_end"] as? String ?? "").isEmpty)
        #expect(bodies.first?["count_only"] as? Bool == true)
        #expect(bodies.last?["key"] as? String == Gateway.base64("a/"))
        #expect(bodies.last?["range_end"] as? String == Gateway.base64("a0"))
    }

    @Test("A subtree delete removes the key and its subtree in one transaction, never keys that only share its name")
    func subtreeDelete() async throws {
        let connection = try await connectedModel(transport)
        let plan = DeletePlan(key: Data("a".utf8), subtreePrefix: "a/", affected: 4)
        transport.enqueue(path: "/v3/kv/txn", json: #"{"header": {}, "succeeded": true}"#)
        try await connection.delete(plan)
        let ops = try txnOps().compactMap { $0["request_delete_range"] as? [String: Any] }
        #expect(ops.count == 2)
        #expect(ops[0]["key"] as? String == Gateway.base64("a"))
        #expect((ops[0]["range_end"] as? String ?? "").isEmpty)
        // "a/" to "a0", which excludes siblings such as "a-b" and "ab".
        #expect(ops[1]["key"] as? String == Gateway.base64("a/"))
        #expect(ops[1]["range_end"] as? String == Gateway.base64("a0"))
        #expect(transport.requests(for: "/v3/kv/deleterange").isEmpty)
    }

    @Test("Successful writes bump the write counter; a refused create does not")
    func writeCount() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 5))
        try await connection.createKey(Data("a".utf8), value: Data())
        #expect(connection.writeCount == 1)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnConflict(current: Gateway.kv("a")))
        _ = try? await connection.createKey(Data("a".utf8), value: Data())
        #expect(connection.writeCount == 1)
        transport.enqueue(path: "/v3/kv/txn", json: #"{"header": {}, "succeeded": true}"#)
        try await connection.delete(DeletePlan(key: Data("a".utf8), subtreePrefix: nil, affected: 1))
        #expect(connection.writeCount == 2)
    }

    @Test("Deleting the unnamed top node removes the subtree under the separator and no empty key")
    func unnamedNodeDelete() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: #"{"count": "2"}"#)
        let plan = try await connection.planDelete(key: Data(), subtreePrefix: "/")
        #expect(plan.affected == 2)
        transport.enqueue(path: "/v3/kv/txn", json: #"{"header": {}, "succeeded": true}"#)
        try await connection.delete(plan)
        let ops = try txnOps().compactMap { $0["request_delete_range"] as? [String: Any] }
        #expect(ops.count == 1)
        #expect(ops[0]["key"] as? String == Gateway.base64("/"))
    }

    @Test("A single-key delete counts one key and removes exactly that key")
    func singleDelete() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: #"{"count": "1"}"#)
        let plan = try await connection.planDelete(key: Data("a".utf8), subtreePrefix: nil)
        #expect(plan.affected == 1)
        transport.enqueue(path: "/v3/kv/txn", json: #"{"header": {}, "succeeded": true}"#)
        try await connection.delete(plan)
        let ops = try txnOps().compactMap { $0["request_delete_range"] as? [String: Any] }
        #expect(ops.count == 1)
        #expect((ops[0]["range_end"] as? String ?? "").isEmpty)
    }
}
