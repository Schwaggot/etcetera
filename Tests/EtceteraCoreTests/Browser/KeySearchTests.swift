import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Key search", .tags(.unit))
struct KeySearchTests {
    private func hits(
        _ keys: [String], _ query: String, names: [Data: String] = [:], limit: Int = 500
    ) -> (hits: [SearchHit], total: Int) {
        KeySearch.hits(keys: keys, query: query, names: names, separator: "/", limit: limit)
    }

    @Test("Finds keys by path and the shallowest folder whose path matches, ignoring case, in key order")
    func pathsAndFolders() {
        let found = hits(["/app/event/set/1", "/app/event/set/2", "/app/other", "/app/events-log"], "EVENT").hits
        #expect(found.map(\.path) == ["/app/event", "/app/event/set/1", "/app/event/set/2", "/app/events-log"])
        #expect(found[0].isFolder && !found[0].isKey)
        #expect(found[1].isKey && !found[1].isFolder)
    }

    @Test("A key with keys below it is one hit that is both")
    func keyAndFolder() {
        let found = hits(["a/event", "a/event/x"], "event").hits
        #expect(found.map(\.path) == ["a/event", "a/event/x"])
        #expect(found[0].isKey && found[0].isFolder)
    }

    @Test("Also finds keys by the name their mapping gives them")
    func byName() {
        let names = [Data("items/1".utf8): "Front door"]
        #expect(hits(["items/1", "items/2"], "FRONT", names: names).hits.map(\.path) == ["items/1"])
        #expect(hits(["items/1", "items/2"], "front").hits.isEmpty)
    }

    @Test("Lists the first hits and counts them all")
    func limit() {
        let found = hits((0..<5).map { "k\($0)" }, "k", limit: 2)
        #expect(found.hits.map(\.path) == ["k0", "k1"])
        #expect(found.total == 5)
    }

    @Test("An empty query matches nothing, so the plain tree shows")
    func emptyQuery() {
        #expect(hits(["a"], "").total == 0)
    }

    @Test("A query containing the separator reads as a key path",
        arguments: [("/config/", true), ("config/app", true), ("config", false), ("", false)])
    func keyPathDetection(query: String, expected: Bool) {
        #expect(KeySearch.looksLikeKeyPath(query, separator: "/") == expected)
    }

    @Test("A server-side prefix scan lists keys starting with the query, not only whole segments")
    func prefixScan() async throws {
        let transport = MockTransport()
        let connection = try await connectedModel(transport)
        let table = KeyTableModel()
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/conf", "/config/app"]))
        await table.scan(prefix: "/conf", from: connection)
        #expect(table.rows.map(\.displayKey) == ["/conf", "/config/app"])
        let bodies = Gateway.rangeBodies(transport)
        // No lookup of the query as a key of its own: the scan covers it.
        #expect(bodies.count == 2)
        #expect(bodies.last?["key"] as? String == Gateway.base64("/conf"))
        #expect(bodies.last?["range_end"] as? String == Gateway.base64("/cong"))
    }
}
