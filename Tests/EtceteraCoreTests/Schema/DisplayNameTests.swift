import EtcdKit
import EtcdSchema
import Foundation
import Testing

@testable import EtceteraCore

// SPEC 5.5: a mapping with a name field labels its keys in the tree, the
// table, and the tabs.

@MainActor
@Suite("Key names from mappings", .tags(.unit))
struct DisplayNameTests {
    let transport = MockTransport()

    private func profile(nameField: String? = "name") -> ConnectionProfile {
        var profile = ConnectionProfile(id: "p1", name: "test", endpoint: "http://127.0.0.1:2379", watchEnabled: false)
        profile.schema = SchemaSettings(
            source: FileReference(bookmark: Data("protos".utf8), displayName: "protos"),
            mappings: [SchemaMappingRule(.prefix("items/"), message: "t.Item", nameField: nameField)])
        return profile
    }

    private func connected(rootKeys: [String] = [], nameField: String? = "name") async throws -> ConnectionModel {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: rootKeys))
        let connection = ConnectionModel(
            transport: transport, schemaLoader: try FakeSchemaLoader(.success(TestSchema.registry())))
        await connection.connect(to: profile(nameField: nameField))
        try #require(connection.phase == .connected)
        return connection
    }

    private func key(_ text: String) -> Data { Data(text.utf8) }

    private func kv(_ key: String, _ json: String) -> String {
        Gateway.kv(Data(key.utf8), value: Data(json.utf8))
    }

    private func put(_ key: String, _ json: String) -> WatchEvent {
        WatchEvent(kind: .put, kv: KeyValue(key: Data(key.utf8), value: Data(json.utf8)), revision: 2)
    }

    @Test("Table rows carry the name the value gives the key")
    func tableNames() async throws {
        let connection = try await connected(rootKeys: ["items/1"])
        let table = KeyTableModel()
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([kv("items/1", #"{"name": "Front door"}"#), kv("items/2", #"{"count": 1}"#)]))
        await table.load(path: "items", from: connection)
        #expect(table.rows.map(\.displayName) == ["Front door", nil])
        #expect(KeyColumn.name.text(for: table.rows[0]) == "Front door")
        #expect(connection.displayNames == [key("items/1"): "Front door"])
        #expect(connection.namesKeys)
    }

    @Test("A search of every key matches names as well as keys, ignoring case")
    func searchByName() async throws {
        let connection = try await connected(rootKeys: ["items/1"])
        let table = KeyTableModel()
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([
                kv("front", ""), kv("items/1", #"{"name": "Front door"}"#), kv("items/2", #"{"name": "Back door"}"#),
            ]))
        await table.search("FRONT", from: connection)
        #expect(table.rows.map(\.displayKey) == ["front", "items/1"])
        #expect(table.rows.map(\.displayName) == [nil, "Front door"])
    }

    @Test("The sidebar search reads named values, then every key, and finds keys by name")
    func serverSearchByName() async throws {
        let connection = try await connected()
        let search = ServerKeySearch()
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([kv("items/1", #"{"name": "Garden Shed"}"#)]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["items/1", "other/shed", "x"]))
        await search.search("SHED", in: connection)
        #expect(search.hits.map(\.path) == ["items/1", "other/shed"])
        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.count == 3)
        #expect(bodies[1]["key"] as? String == Gateway.base64("items/"))
        #expect(bodies[2]["keys_only"] as? Bool == true)
    }

    @Test("A tree level whose keys get names lists with values; other levels stay keys-only")
    func treeNames() async throws {
        let connection = try await connected(rootKeys: ["items/1"])
        let items = try #require(connection.root.children?.first)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([kv("items/1", #"{"name": "Front door"}"#)]))
        await connection.loadChildren(of: items)
        await connection.namingQueue?.value
        let bodies = Gateway.rangeBodies(transport)
        #expect(bodies.first?["keys_only"] as? Bool == true)
        #expect(bodies.last?["keys_only"] as? Bool != true)
        #expect(items.children?.map(\.name) == ["1"])
        #expect(connection.displayNames[key("items/1")] == "Front door")
    }

    @Test("Without a name field the tree stays keys-only and nothing is named")
    func noNameField() async throws {
        let connection = try await connected(rootKeys: ["items/1"], nameField: nil)
        let items = try #require(connection.root.children?.first)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["items/1"]))
        await connection.loadChildren(of: items)
        #expect(Gateway.rangeBodies(transport).last?["keys_only"] as? Bool == true)
        #expect(!connection.namesKeys)
        #expect(connection.displayNames.isEmpty)
    }

    @Test("A binary value is decoded with its message to find the name; the matching rule decides")
    func binaryAndRuleChoice() throws {
        let naming = SchemaMappingConfiguration(
            schemaSource: "",
            mappings: [
                SchemaMappingRule(.prefix("items/"), message: "t.Item", nameField: "name"),
                SchemaMappingRule(.prefix("items/plain/"), message: "t.Item"),
            ])
        let codec = ProtobufValueCodec(registry: try TestSchema.registry())
        let names = ConnectionModel.names(
            of: [
                KeyValue(key: key("items/1"), value: TestSchema.item),
                KeyValue(key: key("items/plain/1"), value: Data(#"{"name": "b"}"#.utf8)),
                KeyValue(key: key("other/1"), value: Data(#"{"name": "c"}"#.utf8)),
            ], naming: naming, codec: codec)
        #expect(names == [key("items/1"): "a"])
    }

    @Test("The tree lists named keys first, by name, then the rest in key order")
    func treeOrder() async throws {
        let connection = try await connected(rootKeys: ["items/1"])
        let items = try #require(connection.root.children?.first)
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([
                kv("items/1", #"{"name": "item 10"}"#), kv("items/2", #"{"count": 1}"#),
                kv("items/3", #"{"name": "Item 9"}"#), kv("items/4", "{}"), kv("items/5", #"{"name": "apple"}"#),
            ]))
        await connection.loadChildren(of: items)
        await connection.namingQueue?.value
        #expect(connection.displayedChildren(of: items).map(\.name) == ["5", "3", "1", "2", "4"])
        #expect(connection.displayedChildren(of: connection.root).map(\.name) == ["items"])
    }

    @Test("Live updates name keys, and a delete drops the name")
    func liveUpdates() async throws {
        let connection = try await connected()
        connection.apply(put("items/1", #"{"name": "A"}"#))
        await connection.namingQueue?.value
        #expect(connection.displayNames[key("items/1")] == "A")
        connection.apply(WatchEvent(kind: .delete, kv: KeyValue(key: key("items/1")), revision: 3))
        await connection.namingQueue?.value
        #expect(connection.displayNames.isEmpty)
    }

    @Test("An event arriving while its level loads keeps its name over the older page's")
    func eventDuringLoad() async throws {
        let connection = try await connected(rootKeys: ["items/1"])
        let items = try #require(connection.root.children?.first)
        items.isLoading = true
        connection.apply(put("items/1", #"{"name": "B"}"#))
        items.isLoading = false
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([kv("items/1", #"{"name": "A"}"#)]))
        await connection.loadChildren(of: items)
        await connection.namingQueue?.value
        #expect(connection.displayNames[key("items/1")] == "B")
    }

    @Test("Names read before a reconnect never land in the new session")
    func staleSession() async throws {
        let connection = try await connected()
        connection.apply(put("items/1", #"{"name": "A"}"#))
        let stale = connection.namingQueue
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: []))
        await connection.connect(to: profile())
        await stale?.value
        #expect(connection.displayNames.isEmpty)
    }

    @Test("Removing the name field drops the names and has listings reload")
    func nameFieldRemoved() async throws {
        let connection = try await connected()
        connection.apply(put("items/1", #"{"name": "A"}"#))
        await connection.namingQueue?.value
        let count = connection.namingChangeCount
        await connection.profileChanged(profile(nameField: nil))
        #expect(connection.displayNames.isEmpty)
        #expect(!connection.namesKeys)
        #expect(connection.namingChangeCount == count + 1)
    }

    @Test("Adding a name field names the loaded tree at once")
    func nameFieldAdded() async throws {
        let connection = try await connected(rootKeys: ["items/1"], nameField: nil)
        let items = try #require(connection.root.children?.first)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["items/1"]))
        await connection.loadChildren(of: items)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([kv("items/1", #"{"name": "B"}"#)]))
        await connection.profileChanged(profile())
        await connection.namingQueue?.value
        #expect(connection.displayNames[key("items/1")] == "B")
    }
}
