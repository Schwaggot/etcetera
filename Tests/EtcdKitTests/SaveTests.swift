import Foundation
import Testing

@testable import EtcdKit

private func makeClient(_ transport: MockTransport) async throws -> EtcdClient {
    transport.enqueue(path: "/version", json: "{\"etcdserver\": \"3.5.21\"}")
    return try await EtcdClient(
        configuration: .init(
            endpoint: URL(string: "http://localhost:2379")!, transport: transport))
}

@Suite("Guarded saves", .tags(.unit))
struct SaveTests {
    @Test("A save is a transaction comparing mod revision, never a bare put")
    func saveIsATransaction() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/txn",
            json: "{\"header\": {\"revision\": \"10\"}, \"succeeded\": true, \"responses\": [{\"response_put\": {\"header\": {\"revision\": \"10\"}}}]}")

        let outcome = try await client.save(
            key: Data("/config/app".utf8), value: Data("v2".utf8), expectedModRevision: 7)

        guard case .written = outcome else {
            Issue.record("expected written, got \(outcome)")
            return
        }
        #expect(transport.requests(for: "/v3/kv/put").isEmpty)
        let body = try #require(transport.requests(for: "/v3/kv/txn").first?.json)
        let compares = try #require(body["compare"] as? [[String: Any]])
        #expect(compares.count == 1)
        #expect(compares[0]["target"] as? String == "MOD")
        #expect(compares[0]["result"] as? String == "EQUAL")
        #expect(compares[0]["mod_revision"] as? String == "7")
        // The failure branch reads the current value back.
        let failure = try #require(body["failure"] as? [[String: Any]])
        #expect(failure.count == 1)
        #expect(failure[0]["request_range"] != nil)
    }

    @Test("Rejects a write when the mod revision changed and returns the current value")
    func rejectsAWriteWhenModRevisionChanged() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        let currentValue = Data("someone else was here".utf8).base64EncodedString()
        transport.enqueue(
            path: "/v3/kv/txn",
            json: """
                {"header": {"revision": "12"}, "responses": [{"response_range":
                {"kvs": [{"key": "\(Data("/config/app".utf8).base64EncodedString())",
                "value": "\(currentValue)", "mod_revision": "11"}], "count": "1"}}]}
                """)

        let outcome = try await client.save(
            key: Data("/config/app".utf8), value: Data("mine".utf8), expectedModRevision: 7)

        guard case .conflict(let current) = outcome else {
            Issue.record("expected conflict, got \(outcome)")
            return
        }
        let kv = try #require(current)
        #expect(kv.modRevision == 11)
        #expect(kv.value == Data("someone else was here".utf8))
    }

    @Test("A conflict on a key deleted meanwhile carries no current value")
    func conflictOnDeletedKey() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/txn",
            json: "{\"header\": {}, \"responses\": [{\"response_range\": {\"count\": \"0\"}}]}")
        let outcome = try await client.save(
            key: Data("/gone".utf8), value: Data("v".utf8), expectedModRevision: 3)
        guard case .conflict(let current) = outcome else {
            Issue.record("expected conflict, got \(outcome)")
            return
        }
        #expect(current == nil)
    }

    @Test("A save keeps the key's lease instead of detaching it")
    func saveKeepsLease() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/txn",
            json: "{\"header\": {}, \"succeeded\": true, \"responses\": [{\"response_put\": {\"header\": {}}}]}")
        _ = try await client.save(
            key: Data("/leased".utf8), value: Data("v".utf8), expectedModRevision: 7, lease: 99)
        let body = try #require(transport.requests(for: "/v3/kv/txn").first?.json)
        let success = try #require(body["success"] as? [[String: Any]])
        let put = try #require(success.first?["request_put"] as? [String: Any])
        #expect(put["lease"] as? String == "99")
    }

    @Test("Creating a key compares createRevision == 0 so an existing key fails")
    func createComparesCreateRevisionZero() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/txn",
            json: "{\"header\": {}, \"succeeded\": true, \"responses\": [{\"response_put\": {\"header\": {}}}]}")

        _ = try await client.save(
            key: Data("/new".utf8), value: Data("v".utf8), expectedModRevision: 0)

        let body = try #require(transport.requests(for: "/v3/kv/txn").first?.json)
        let compares = try #require(body["compare"] as? [[String: Any]])
        #expect(compares[0]["target"] as? String == "CREATE")
        #expect(compares[0]["create_revision"] as? String == "0")
    }
}
