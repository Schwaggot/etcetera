import Foundation
import Testing

@testable import EtcdKit

private func makeClient(_ transport: MockTransport) async throws -> EtcdClient {
    transport.enqueue(path: "/version", json: "{\"etcdserver\": \"3.5.21\"}")
    return try await EtcdClient(
        configuration: .init(
            endpoint: URL(string: "http://localhost:2379")!, transport: transport))
}

private func kvJSON(key: String, value: String = "", modRevision: Int64 = 1) -> String {
    let keyB64 = Data(key.utf8).base64EncodedString()
    let valueB64 = Data(value.utf8).base64EncodedString()
    return
        "{\"key\": \"\(keyB64)\", \"value\": \"\(valueB64)\", \"mod_revision\": \"\(modRevision)\", \"create_revision\": \"1\", \"version\": \"1\"}"
}

@Suite("Tree building from flat keys", .tags(.unit))
struct BuildChildrenTests {
    @Test("Splits keys at the separator into branches and leaves")
    func splitsIntoBranchesAndLeaves() {
        let nodes = buildChildren(
            keys: ["/config/app/a", "/config/app/b", "/config/db"],
            prefix: "/config/", separator: "/")
        #expect(nodes.count == 2)
        #expect(nodes[0] == TreeNode(name: "app", path: "/config/app", isLeaf: false, hasChildren: true))
        #expect(nodes[1] == TreeNode(name: "db", path: "/config/db", isLeaf: true, hasChildren: false))
    }

    @Test("A key that is both a value and a branch prefix shows both")
    func leafAndBranch() {
        let nodes = buildChildren(
            keys: ["/config/app", "/config/app/nested"],
            prefix: "/config/", separator: "/")
        #expect(nodes.count == 1)
        #expect(nodes[0].isLeaf)
        #expect(nodes[0].hasChildren)
    }

    @Test("The empty prefix groups top-level segments")
    func emptyPrefix() {
        let nodes = buildChildren(
            keys: ["/a/x", "/a/y", "/b"], prefix: "", separator: "/")
        // Keys starting with the separator produce one empty-named root node.
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "")
        #expect(nodes[0].hasChildren)
    }

    @Test("Preserves the sorted arrival order of segments")
    func preservesOrder() {
        let nodes = buildChildren(
            keys: ["/k/a", "/k/b/x", "/k/c"], prefix: "/k/", separator: "/")
        #expect(nodes.map(\.name) == ["a", "b", "c"])
    }

    @Test("Ignores keys outside the prefix")
    func ignoresOutsiders() {
        let nodes = buildChildren(
            keys: ["/other/x", "/k/a"], prefix: "/k/", separator: "/")
        #expect(nodes.map(\.name) == ["a"])
    }

    @Test("Empty segments from doubled separators are preserved as nodes")
    func doubledSeparator() {
        let nodes = buildChildren(keys: ["/k//x"], prefix: "/k/", separator: "/")
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "")
        #expect(nodes[0].hasChildren)
    }

    @Test("A custom separator splits on it")
    func customSeparator() {
        let nodes = buildChildren(
            keys: ["app.db.host", "app.db.port", "app.name"],
            prefix: "app.", separator: ".")
        #expect(nodes.map(\.name) == ["db", "name"])
        #expect(nodes[0].hasChildren)
        #expect(nodes[1].isLeaf)
    }
}

@Suite("Client conveniences", .tags(.unit))
struct ConvenienceTests {
    @Test("get returns nil for a missing key")
    func getMissing() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")
        let result = try await client.get("/nope")
        #expect(result == nil)
    }

    @Test("get returns the key value")
    func getExisting() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json: "{\"kvs\": [\(kvJSON(key: "/config/app", value: "{}"))], \"count\": \"1\"}")
        let result = try #require(try await client.get("/config/app"))
        #expect(result.keyString == "/config/app")
    }

    @Test("The empty prefix lists the whole keyspace, key and end both \\0")
    func listEmptyPrefix() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")
        _ = try await client.list(prefix: "")
        let body = try #require(transport.requests(for: "/v3/kv/range").first?.json)
        #expect(body["key"] as? String == Data([0]).base64EncodedString())
        #expect(body["range_end"] as? String == Data([0]).base64EncodedString())
    }

    @Test("list scans the prefix range in ascending key order")
    func listPrefixRange() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")
        _ = try await client.list(prefix: "/config/")
        let body = try #require(transport.requests(for: "/v3/kv/range").first?.json)
        #expect(body["key"] as? String == Data("/config/".utf8).base64EncodedString())
        #expect(body["range_end"] as? String == Data("/config0".utf8).base64EncodedString())
        #expect(body["sort_order"] as? String == "ASCEND")
        #expect(body["sort_target"] as? String == "KEY")
    }

    @Test("list without a limit follows more across pages and returns every key")
    func listFollowsEveryPage() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json: "{\"kvs\": [\(kvJSON(key: "/k/a")), \(kvJSON(key: "/k/b"))], \"more\": true, \"count\": \"3\"}")
        transport.enqueue(
            path: "/v3/kv/range", json: "{\"kvs\": [\(kvJSON(key: "/k/c"))], \"more\": false, \"count\": \"3\"}")

        let kvs = try await client.list(prefix: "/k/")

        #expect(kvs.map(\.keyString) == ["/k/a", "/k/b", "/k/c"])
        let bodies = transport.requests(for: "/v3/kv/range").compactMap(\.json)
        try #require(bodies.count == 2)
        #expect(bodies.map { $0["limit"] as? String } == ["1000", "1000"])
        #expect(bodies[1]["key"] as? String == (Data("/k/b".utf8) + Data([0])).base64EncodedString())
        #expect(bodies[1]["range_end"] as? String == Data("/k0".utf8).base64EncodedString())
    }

    @Test("list with a limit stops at exactly that many keys even when more remain")
    func listStopsAtTheLimit() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json: "{\"kvs\": [\(kvJSON(key: "/k/a")), \(kvJSON(key: "/k/b"))], \"more\": true, \"count\": \"5\"}")

        let kvs = try await client.list(prefix: "/k/", limit: 2)

        #expect(kvs.count == 2)
        let bodies = transport.requests(for: "/v3/kv/range").compactMap(\.json)
        #expect(bodies.map { $0["limit"] as? String } == ["2"])
    }

    @Test("list with a limit beyond one page asks the next page only for what remains")
    func listLimitSpansPages() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        let firstPage = (0..<1000).map { kvJSON(key: String(format: "/k/%04d", $0)) }.joined(separator: ", ")
        transport.enqueue(path: "/v3/kv/range", json: "{\"kvs\": [\(firstPage)], \"more\": true}")
        transport.enqueue(path: "/v3/kv/range", json: "{\"kvs\": [\(kvJSON(key: "/k/1000"))], \"more\": true}")

        let kvs = try await client.list(prefix: "/k/", limit: 1001)

        #expect(kvs.count == 1001)
        let bodies = transport.requests(for: "/v3/kv/range").compactMap(\.json)
        #expect(bodies.map { $0["limit"] as? String } == ["1000", "1"])
    }

    @Test("Paging: the next page starts after the last returned key")
    func pagingStartsAfterLastKey() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json: "{\"kvs\": [\(kvJSON(key: "/k/a")), \(kvJSON(key: "/k/b"))], \"more\": true, \"count\": \"5\"}")
        let firstPage = try await client.listPage(prefix: "/k/", limit: 2)
        #expect(firstPage.more)
        #expect(firstPage.kvs.count == 2)

        transport.enqueue(
            path: "/v3/kv/range",
            json: "{\"kvs\": [\(kvJSON(key: "/k/c"))], \"more\": false, \"count\": \"5\"}")
        let lastKey = try #require(firstPage.kvs.last?.key)
        let secondPage = try await client.listPage(prefix: "/k/", after: lastKey, limit: 2)
        #expect(!secondPage.more)

        let body = try #require(transport.requests(for: "/v3/kv/range").last?.json)
        // "/k/b" + 0x00 is the smallest key strictly greater than "/k/b".
        #expect(body["key"] as? String == (Data("/k/b".utf8) + Data([0])).base64EncodedString())
    }

    @Test("A final page with an empty result and more=false ends paging")
    func emptyFinalPage() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")
        let page = try await client.listPage(prefix: "/k/", limit: 100)
        #expect(page.kvs.isEmpty)
        #expect(!page.more)
    }

    @Test("listChildren fetches one page with keysOnly and groups it")
    func listChildren() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json:
                "{\"kvs\": [\(kvJSON(key: "/config/app/a")), \(kvJSON(key: "/config/db"))], \"count\": \"2\"}")
        let (nodes, more) = try await client.listChildren(of: "/config")
        #expect(!more)
        #expect(nodes.map(\.name) == ["app", "db"])
        let body = try #require(transport.requests(for: "/v3/kv/range").first?.json)
        #expect(body["keys_only"] as? Bool == true)
        #expect(body["limit"] as? String == "1000")
    }
}
