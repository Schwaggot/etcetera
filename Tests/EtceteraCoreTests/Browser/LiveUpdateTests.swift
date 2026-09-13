import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

/// Yields until `condition` holds, a bounded number of times. No sleeps.
@MainActor
func eventually(_ condition: () -> Bool, iterations: Int = 10_000) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

// SPEC 4.2: live updates through one watch on the connection root, applied
// to the loaded tree incrementally.

@MainActor
@Suite("Live tree updates", .tags(.unit))
struct LiveUpdateTests {
    let transport = MockTransport()

    private func event(_ kind: WatchEvent.Kind, _ key: String) -> WatchEvent {
        WatchEvent(kind: kind, kv: KeyValue(key: Data(key.utf8), modRevision: 10), revision: 10)
    }

    private func child(_ node: KeyNode, _ name: String) throws -> KeyNode {
        try #require(node.children?.first { $0.name == name })
    }

    @Test("A put for a new key joins the loaded tree in key order")
    func putInOrder() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a", "c"])
        model.apply(event(.put, "b"))
        #expect(model.root.children?.map(\.name) == ["a", "b", "c"])
    }

    @Test("A put below a loaded leaf makes it a branch as well")
    func putBelowLeaf() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a"])
        model.apply(event(.put, "a/x"))
        let a = try child(model.root, "a")
        #expect(a.isLeaf && a.hasChildren)
        #expect(a.children == nil)
    }

    @Test("A put inside an expanded branch adds the child there")
    func putInsideExpanded() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await model.loadChildren(of: a)
        model.apply(event(.put, "a/w"))
        #expect(a.children?.map(\.name) == ["w", "x"])
    }

    @Test("A delete removes a leaf and the branches it empties")
    func deleteCascades() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x", "b"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await model.loadChildren(of: a)
        model.apply(event(.delete, "a/x"))
        #expect(model.root.children?.map(\.name) == ["b"])
    }

    @Test("Deleting a key that also has children keeps the node as a branch")
    func deleteKeepsBranch() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a", "a/x"])
        model.apply(event(.delete, "a"))
        let a = try child(model.root, "a")
        #expect(!a.isLeaf)
        #expect(a.hasChildren)
    }

    @Test("A branch whose children are not all loaded stays after a delete")
    func partialBranchStays() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a/x"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"], more: true))
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.permissionDenied)
        await model.loadChildren(of: a)
        model.apply(event(.delete, "a/x"))
        #expect(model.root.children?.map(\.name) == ["a"])
    }

    @Test("Deleting a key whose loaded children are all gone removes its node")
    func deleteAfterChildrenGone() async throws {
        let model = try await connectedModel(transport, rootKeys: ["a", "a/x", "b"])
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await model.loadChildren(of: a)
        model.apply(event(.delete, "a/x"))
        #expect(model.root.children?.map(\.name) == ["a", "b"])
        model.apply(event(.delete, "a"))
        #expect(model.root.children?.map(\.name) == ["b"])
    }

    @Test("With live updates on, one watch covers the whole keyspace and its events reach the tree")
    func watchStream() async throws {
        let line = """
            {"result": {"header": {"revision": "10"}, "events": [{"kv": \
            {"key": "\(Gateway.base64("b"))", "mod_revision": "10"}}]}}
            """
        transport.enqueueStream(path: "/v3/watch", lines: [line], staysOpen: true)
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        let model = ConnectionModel(transport: transport)
        await model.connect(to: ConnectionProfile(id: "p", name: "t", endpoint: "http://127.0.0.1:2379", watchEnabled: true))

        #expect(await eventually { model.liveRevision == 10 })
        #expect(model.root.children?.map(\.name) == ["a", "b"])
        #expect(model.changeCount > 0)
        let watches = transport.requests(for: "/v3/watch")
        #expect(watches.count == 1)
        let create = try #require(watches.first?.json?["create_request"] as? [String: Any])
        #expect(create["key"] as? String == Data([0]).base64EncodedString())
        #expect(create["range_end"] as? String == Data([0]).base64EncodedString())
        model.disconnect()
    }

    private func profile() -> ConnectionProfile {
        ConnectionProfile(id: "p", name: "t", endpoint: "http://127.0.0.1:2379", watchEnabled: false)
    }

    @Test("After a compaction the tree reloads and the watch starts over")
    func compactionReloads() async throws {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        let model = ConnectionModel(transport: transport)
        await model.connect(to: profile())
        transport.enqueueStream(
            path: "/v3/watch", lines: [#"{"result": {"header": {"revision": "20"}, "compact_revision": "15"}}"#])
        transport.enqueueStream(path: "/v3/watch", lines: [], staysOpen: true)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["b"]))
        model.startWatching()

        #expect(await eventually { model.root.children?.map(\.name) == ["b"] })
        #expect(model.lastError == nil)
        #expect(transport.requests(for: "/v3/watch").count == 2)
        model.disconnect()
    }

    @Test("Events for a node whose page is still loading apply once the page arrives")
    func eventsDuringLoad() async throws {
        let gate = GatedTransport(transport)
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        let model = ConnectionModel(transport: gate)
        await model.connect(to: profile())
        let a = try child(model.root, "a")
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/y"]))
        gate.close()
        let load = Task { await model.loadChildren(of: a) }
        #expect(await eventually { gate.heldCount == 1 })

        model.apply(event(.put, "a/w"))
        model.apply(event(.delete, "a/y"))
        gate.open()
        await load.value
        #expect(a.children?.map(\.name) == ["w", "x"])
    }

    @Test("With live updates off, no watch is opened")
    func watchOff() async throws {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        let model = ConnectionModel(transport: transport)
        await model.connect(to: ConnectionProfile(id: "p", name: "t", endpoint: "http://127.0.0.1:2379", watchEnabled: false))
        _ = await eventually({ false }, iterations: 200)
        #expect(transport.requests(for: "/v3/watch").isEmpty)
    }
}
