import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Connection and key tree", .tags(.unit))
struct ConnectionModelTests {
    let transport = MockTransport()

    private func child(_ node: KeyNode, _ name: String) throws -> KeyNode {
        try #require(node.children?.first { $0.name == name })
    }

    @Test("Connecting runs detection and loads the first page of the tree root")
    func connectLoadsRoot() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a", "a/x", "b"])
        #expect(model.serverVersion == "3.5.21")
        let children = try #require(model.root.children)
        #expect(children.map(\.name) == ["a", "b"])
        // "a" holds a value and has children at the same time.
        #expect(children[0].isLeaf && children[0].hasChildren)
        #expect(children[1].isLeaf && !children[1].hasChildren)
    }

    @Test("Expanding a node issues a keys-only range for its prefix with the page limit")
    func expandIssuesOnePage() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        try await model.loadChildren(of: child(model.root, "a"))

        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.count == 2)
        let body = try #require(bodies.last)
        #expect(body["key"] as? String == Gateway.base64("a/"))
        #expect(body["range_end"] as? String == Gateway.base64("a0"))
        #expect(body["keys_only"] as? Bool == true)
        #expect(body["limit"] as? String == "1000")
        #expect(try child(model.root, "a").children?.map(\.name) == ["x"])
    }

    @Test("Expanding loads every page, continuing right after a last key that is a child's own")
    func loadsAllPages() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/w"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/y"]))
        await model.loadChildren(of: a)
        #expect(a.children?.map(\.name) == ["w", "x", "y"])
        #expect(!a.isLoading)
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == (Data("a/w".utf8) + Data([0])).base64EncodedString())
        #expect(body["range_end"] as? String == Gateway.base64("a0"))
    }

    @Test("A page ending inside a child's subtree continues after that whole subtree")
    func pagingSkipsSubtree() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x/1"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/x/1"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/y"]))
        await model.loadChildren(of: a)
        #expect(a.children?.map(\.name) == ["x", "y"])
        let x = try child(a, "x")
        #expect(x.isLeaf && x.hasChildren)
        let body = try #require(Gateway.rangeBodies(transport).last)
        // "a/x0" is the first key after everything starting with "a/x/".
        #expect(body["key"] as? String == Gateway.base64("a/x0"))
    }

    @Test("Keys all below a leading separator skip the unnamed node even when they fill many pages")
    func leadingSeparatorManyPages() async throws {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/app/a"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: []))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/app/a"]))
        let model = ConnectionModel(transport: transport)
        await model.connect()
        #expect(model.root.children?.map(\.name) == [""])
        #expect(try model.topNode === child(model.root, ""))
        #expect(model.topNode.children?.map(\.name) == ["app"])
        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.count == 3)
        #expect(bodies[1]["key"] as? String == Gateway.base64("0"))
    }

    @Test("A failed later page keeps the children loaded so far and reports the error")
    func failedLaterPage() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"], more: true))
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.permissionDenied)
        await model.loadChildren(of: a)
        #expect(a.children?.map(\.name) == ["x"])
        #expect(model.lastError?.contains("permission") == true)
        #expect(!a.isLoading)
    }

    private func connectedWithLeadingSeparator(_ keys: [String]) async throws -> ConnectionModel {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: keys))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: keys))
        let model = ConnectionModel(transport: transport)
        await model.connect()
        try #require(model.phase == .connected)
        return model
    }

    @Test("When every key starts with the separator, the unnamed top node is skipped and loads on connect")
    func leadingSeparator() async throws {
        let model = try await connectedWithLeadingSeparator(["/a", "/b/c"])
        #expect(model.root.children?.map(\.name) == [""])
        #expect(try model.topNode === child(model.root, ""))
        #expect(model.topNode.children?.map(\.name) == ["a", "b"])
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == Gateway.base64("/"))
        #expect(body["range_end"] as? String == Gateway.base64("0"))
    }

    @Test("Reloading the root loads the skipped top node again")
    func reloadRootLoadsTopNode() async throws {
        let model = try await connectedWithLeadingSeparator(["/a", "/b/c"])
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/a"]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/a"]))
        await model.reload(path: nil)
        #expect(model.topNode.children?.map(\.name) == ["a"])
    }

    @Test("Keys with and without a leading separator keep the unnamed node as a row")
    func mixedLeadingSeparator() async throws {
        let model = try await connectedModel(transport, rootKeys: ["/a", "b"])
        #expect(model.topNode === model.root)
        #expect(model.root.children?.map(\.name) == ["", "b"])
    }

    @Test("Reloading a node refetches its first page and drops stale children")
    func reloadNode() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/y"]))
        await model.loadChildren(of: a)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await model.reload(path: "a")
        #expect(a.children?.map(\.name) == ["x"])
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == Gateway.base64("a/"))
    }

    @Test("The parent of a key is the tree node that lists it",
        arguments: [("a/x", "a"), ("a/b/c", "a/b"), ("/a", ""), ("a//b", "a/")])
    func parentPath(key: String, expected: String) {
        #expect(ConnectionModel().parentPath(of: key) == expected)
    }

    @Test("A top-level key is listed by the root")
    func rootParent() {
        #expect(ConnectionModel().parentPath(of: "a") == nil)
    }

    @Test("A failed expansion stops the spinner and reports the error")
    func failedExpansion() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.permissionDenied)
        await model.loadChildren(of: a)
        #expect(a.children?.isEmpty == true)
        #expect(!a.isLoading)
        #expect(model.lastError?.contains("permission") == true)
    }

    @Test("An invalid endpoint fails without contacting the server")
    func invalidEndpoint() async {
        let model = ConnectionModel(transport: transport)
        model.endpoint = "not a url"
        await model.connect()
        guard case .failed = model.phase else {
            Issue.record("expected failure, got \(model.phase)")
            return
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("A cluster without the gateway fails with the plain-words message")
    func gatewayOff() async {
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        for prefix in ["/v3", "/v3beta", "/v3alpha"] {
            transport.enqueue(path: "\(prefix)/maintenance/status", error: HTTPStatusError(status: 404, body: Data()))
        }
        let model = ConnectionModel(transport: transport)
        await model.connect()
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failure, got \(model.phase)")
            return
        }
        #expect(message.contains("JSON gateway"))
    }

    @Test("Disconnecting drops the client and the tree")
    func disconnect() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a"])
        model.disconnect()
        #expect(model.phase == .disconnected)
        #expect(model.root.children == nil)
        #expect(model.serverVersion == nil)
    }
}
