import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Key table", .tags(.unit))
struct KeyTableModelTests {
    let transport = MockTransport()
    let table = KeyTableModel()

    @Test("Rows start with the node's own value, then the keys below it")
    func ownValueThenPage() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a", value: "12345")]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/y"]))
        await table.load(path: "a", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a", "a/x", "a/y"])
        #expect(table.rows.first?.size == 5)
        #expect(Gateway.rangeBodies(transport).count == 3)
    }

    @Test("Every page is loaded, each continuing from the last listed key, not from the node's own key")
    func loadsAllPages() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/y"]))
        await table.load(path: "a", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a", "a/x", "a/y"])
        #expect(!table.isLoading)
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == (Data("a/x".utf8) + Data([0])).base64EncodedString())
        #expect(body["range_end"] as? String == Gateway.base64("a0"))
    }

    @Test("All Keys lists the whole keyspace without a lookup of its own")
    func allKeys() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a", "b"]))
        await table.loadAll(from: connection)
        #expect(table.rows.map(\.displayKey) == ["a", "b"])
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == Data([0]).base64EncodedString())
        #expect(Gateway.rangeBodies(transport).count == 2)
    }

    @Test("A search reads every page of the keyspace and keeps keys containing the query, ignoring case")
    func search() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/Event/1", "b"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["c/events"]))
        await table.search("event", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a/Event/1", "c/events"])
        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.count == 3)
        #expect(bodies[1]["key"] as? String == Data([0]).base64EncodedString())
    }

    @Test("The unnamed top node of a leading separator lists keys under the bare separator")
    func unnamedTopNode() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["/a"]))
        await table.load(path: "", from: connection)
        #expect(table.rows.map(\.displayKey) == ["/a"])
        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.count == 2)
        #expect(bodies.last?["key"] as? String == Gateway.base64("/"))
    }

    @Test("Reload repeats the current listing and keeps the rows until the new ones arrive")
    func reload() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await table.load(path: "a", from: connection)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x", "a/y"]))
        await table.reload(from: connection)
        #expect(table.rows.map(\.displayKey) == ["a/x", "a/y"])
        #expect(Gateway.rangeBodies(transport).last?["key"] as? String == Gateway.base64("a/"))
    }

    @Test("Keys that are not valid UTF-8 appear with \\xNN escapes instead of being hidden")
    func nonUTF8Keys() async throws {
        let connection = try await connectedModel(transport)
        let raw = Data([0x61, 0x2F, 0xFF])
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(raw)]))
        await table.load(path: "a", from: connection)
        let row = try #require(table.rows.first)
        #expect(row.displayKey == "a/\\xFF")
        #expect(row.id == raw)
    }

    @Test("A failed load shows the error and no rows")
    func failedLoad() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.permissionDenied)
        await table.load(path: "a", from: connection)
        #expect(table.rows.isEmpty)
        #expect(table.errorMessage?.contains("permission") == true)
        #expect(!table.isLoading)
    }

    @Test("No path clears the table without a request")
    func noPath() async throws {
        let connection = try await connectedModel(transport)
        await table.load(path: nil, from: connection)
        #expect(table.rows.isEmpty)
        #expect(Gateway.rangeBodies(transport).count == 1)
    }

    @Test("Clearing the table while a load is in flight stops the spinner")
    func clearDuringLoad() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a", value: "1")]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        let loading = Task { await table.load(path: "a", from: connection) }
        _ = await eventually { table.isLoading }
        await table.load(path: nil, from: connection)
        await loading.value
        #expect(!table.isLoading)
        #expect(table.rows.isEmpty)
    }

    @Test("A first load is filling until its last page; a reload is not")
    func fillingOnlyOnFirstLoad() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        let firstRequest = transport.hold(path: "/v3/kv/range")
        let loading = Task { await table.load(path: "a", from: connection) }
        await firstRequest.arrived()
        #expect(table.isFilling)
        firstRequest.release()
        await loading.value
        #expect(!table.isFilling)

        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        let reloadRequest = transport.hold(path: "/v3/kv/range")
        let reloading = Task { await table.reload(from: connection) }
        await reloadRequest.arrived()
        #expect(table.isLoading)
        #expect(!table.isFilling)
        reloadRequest.release()
        await reloading.value
        #expect(table.rows.map(\.displayKey) == ["a", "a/x"])
    }

    // The gateway relays gRPC's message limit, 4 MB on etcd 3.3, as resource exhausted.
    private let tooLarge = EtcdError.status(
        code: .resourceExhausted, message: "grpc: received message larger than max (69274661 vs. 4194304)")

    @Test("A page the gateway refuses as too large is retried with fewer keys")
    func tooLargePageRetriesSmaller() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(path: "/v3/kv/range", error: tooLarge)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/x", value: "12")]))
        await table.load(path: "a", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a/x"])
        #expect(table.rows.first?.size == 2)
        #expect(Gateway.rangeBodies(transport).suffix(2).map { $0["limit"] as? String } == ["1000", "250"])
    }

    @Test("A value too large to fetch on its own is listed by key with an unknown size")
    func valueTooLargeAlone() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        for _ in ["1000", "250", "62", "15", "3", "1"] {
            transport.enqueue(path: "/v3/kv/range", error: tooLarge)
        }
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/big"], more: true))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a/small", value: "1")]))
        await table.load(path: "a", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a/big", "a/small"])
        #expect(table.rows.map(\.size) == [nil, 1])
        // Too large for the gateway means larger than any listed size.
        #expect(table.rows.map(\.sizeForSorting) == [.max, 1])
        #expect(table.rows.map { KeyColumn.size.text(for: $0) } == ["too large", "1 B"])
        let bodies = Gateway.rangeBodies(transport)
        let keysOnly = bodies[bodies.count - 2]
        #expect(keysOnly["keys_only"] as? Bool == true)
        #expect(keysOnly["limit"] as? String == "1")
        // The page after the oversized value starts small again, not at the full limit.
        #expect(bodies.last?["limit"] as? String == "1")
        #expect(bodies.last?["keys_only"] == nil)
    }

    @Test("Rows sort by any column, ties keep key order, and a reload keeps the sort")
    func sortByColumns() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([
                Gateway.kv("a/x", value: "22", modRevision: 5),
                Gateway.kv("a/y", value: "1", modRevision: 9),
                Gateway.kv("a/z", value: "22", modRevision: 7),
            ]))
        await table.load(path: "a", from: connection)
        #expect(table.sortOrder == [KeyTableModel.keyOrder])
        #expect(table.rows.map(\.displayKey) == ["a/x", "a/y", "a/z"])

        table.sortOrder = [KeyPathComparator(\.sizeForSorting, order: .reverse)]
        #expect(table.rows.map(\.displayKey) == ["a/x", "a/z", "a/y"])
        table.sortOrder = [KeyPathComparator(\.modRevision)]
        #expect(table.rows.map(\.displayKey) == ["a/x", "a/z", "a/y"])
        var reversedKeys = KeyTableModel.keyOrder
        reversedKeys.order = .reverse
        table.sortOrder = [reversedKeys]
        #expect(table.rows.map(\.displayKey) == ["a/z", "a/y", "a/x"])

        table.sortOrder = [KeyPathComparator(\.modRevision)]
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([Gateway.kv("a/x", modRevision: 12), Gateway.kv("a/y", modRevision: 3)]))
        await table.reload(from: connection)
        #expect(table.rows.map(\.displayKey) == ["a/y", "a/x"])
    }

    @Test("Each column sorts both ways and is recognized again from its comparator")
    func columnComparators() throws {
        for column in KeyColumn.allCases {
            for ascending in [true, false] {
                let sorting = try #require(KeyColumn.sorting(column.comparator(ascending: ascending)))
                #expect(sorting.column == column)
                #expect(sorting.ascending == ascending)
            }
        }
        #expect(KeyColumn.sorting(KeyTableModel.keyOrder)?.column == .key)
    }

    @Test("Cells show the key, a readable size, the revision, and the lease in hex or none")
    func columnText() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([
                Gateway.kv(Data("a/x".utf8), value: Data(count: 1200), modRevision: 7),
                Gateway.kv(Data("a/y".utf8), modRevision: 8, lease: 42),
            ]))
        await table.load(path: "a", from: connection)
        let texts = table.rows.map { row in KeyColumn.allCases.map { $0.text(for: row) } }
        #expect(texts == [["a/x", "", formatByteSize(1200), "7", "none"], ["a/y", "", "0 B", "8", "2a"]])
    }

    @Test("Keys sort by their bytes, as etcd orders them, not by locale")
    func keyByteOrder() {
        let order = KeyByteOrder()
        #expect(order.compare(Data("B".utf8), Data("a".utf8)) == .orderedAscending)
        #expect(order.compare(Data("a/10".utf8), Data("a/9".utf8)) == .orderedAscending)
        #expect(order.compare(Data([0xFF]), Data("z".utf8)) == .orderedDescending)
        #expect(order.compare(Data("a".utf8), Data("a".utf8)) == .orderedSame)
    }

    @Test("A node whose own value is too large still lists its key")
    func ownValueTooLarge() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", error: tooLarge)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a"]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/x"]))
        await table.load(path: "a", from: connection)
        #expect(table.rows.map(\.displayKey) == ["a", "a/x"])
        #expect(table.rows.first?.size == nil)
        #expect(ConnectionModel.message(for: tooLarge).contains("larger than the gateway's limit"))
    }
}
