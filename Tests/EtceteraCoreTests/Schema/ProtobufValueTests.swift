import EtcdKit
import EtcdSchema
import Foundation
import Testing

@testable import EtceteraCore

// SPEC 5.5 and 5.6: mapped values decode to JSON, edits encode back behind
// the safeguards, and problems show on the key. Values stored as JSON stay
// as typed and are only checked.

@MainActor
@Suite("Protobuf values in the editor", .tags(.unit))
struct ProtobufValueTests {
    let transport = MockTransport()
    let value = ValueModel()
    let key = Data("/items/1".utf8)

    private func profile(message: String = "t.Item") -> ConnectionProfile {
        var profile = ConnectionProfile(id: "p1", name: "test", endpoint: "http://127.0.0.1:2379", watchEnabled: false)
        profile.schema = SchemaSettings(
            source: FileReference(bookmark: Data("protos".utf8), displayName: "protos"),
            mappings: [SchemaMappingRule(.prefix("/items/"), message: message)])
        return profile
    }

    private func connected(
        _ loader: FakeSchemaLoader? = nil, message: String = "t.Item"
    ) async throws -> ConnectionModel {
        let loader = try loader ?? FakeSchemaLoader(.success(TestSchema.registry()))
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        let connection = ConnectionModel(transport: transport, schemaLoader: loader)
        await connection.connect(to: profile(message: message))
        try #require(connection.phase == .connected)
        return connection
    }

    private func load(_ bytes: Data, key: Data? = nil, from connection: ConnectionModel) async {
        let key = key ?? self.key
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: bytes, modRevision: 7)]))
        await value.load(key: key, from: connection)
    }

    private func savedValue() throws -> Data? {
        let body = try #require(Gateway.txnBodies(transport).last)
        let success = try #require(body["success"] as? [[String: Any]])
        let put = try #require(success.first?["request_put"] as? [String: Any])
        return (put["value"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    @Test("A key mapped to a message decodes to JSON in the protobuf format")
    func decodesMapped() async throws {
        let connection = try await connected()
        await load(TestSchema.item, from: connection)
        #expect(value.format == .protobuf)
        #expect(value.text.contains(#""name": "a""#))
        #expect(value.text.contains(#""count": 2"#))
        #expect(value.isEditable)
        #expect(value.protobuf?.roundTrip.originalLength == 5)
        #expect(value.protobuf?.roundTrip.reencodedLength == 5)
    }

    @Test("Protobuf is offered only when a mapping matches")
    func protobufOnlyWhenMapped() async throws {
        let connection = try await connected()
        await load(Data("plain".utf8), key: Data("/other".utf8), from: connection)
        #expect(value.format == .text)
        #expect(!value.availableFormats.contains(.protobuf))
        await load(TestSchema.item, from: connection)
        #expect(value.availableFormats.contains(.protobuf))
    }

    @Test("An edited protobuf value is encoded back to bytes through the guarded transaction")
    func savesEncodedBytes() async throws {
        let connection = try await connected()
        await load(TestSchema.item, from: connection)
        value.text = value.text.replacingOccurrences(of: #""a""#, with: #""b""#)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        await value.save(to: connection)
        #expect(try savedValue() == Data([0x0A, 0x01, 0x62, 0x10, 0x02]))
        let compare = try #require((Gateway.txnBodies(transport).last?["compare"] as? [[String: Any]])?.first)
        #expect(compare["mod_revision"] as? String == "7")
        #expect(value.loaded?.value == Data([0x0A, 0x01, 0x62, 0x10, 0x02]))
        #expect(!value.isDirty)
    }

    @Test("Unknown fields in the stored bytes survive an edit")
    func keepsUnknownFields() async throws {
        let connection = try await connected()
        await load(TestSchema.item + Data([0x48, 0x05]), from: connection)
        #expect(value.isEditable)
        value.text = value.text.replacingOccurrences(of: #""a""#, with: #""b""#)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        await value.save(to: connection)
        #expect(try savedValue() == Data([0x0A, 0x01, 0x62, 0x10, 0x02, 0x48, 0x05]))
    }

    @Test("A value whose unchanged re-encoding differs is read-only with an explanation")
    func unfaithfulIsReadOnly() async throws {
        let connection = try await connected()
        // count before name: valid, but re-encoded in field order.
        await load(Data([0x10, 0x02, 0x0A, 0x01, 0x61]), from: connection)
        #expect(value.protobuf != nil)
        #expect(!value.isEditable)
        #expect(value.readOnlyReason != nil)
        value.text = "{}"
        await value.save(to: connection)
        #expect(Gateway.txnBodies(transport).isEmpty)
    }

    @Test("A value that fails to decode shows the error, never a partial message")
    func decodeFailure() async throws {
        let connection = try await connected()
        await load(Data([0x0A, 0x05, 0x61]), from: connection)
        #expect(value.format == .protobuf)
        #expect(value.protobuf == nil)
        #expect(value.protobufError != nil)
        #expect(value.text.isEmpty)
        #expect(!value.isEditable)
    }

    @Test("A mapping to a message missing from the schema is shown on the key")
    func missingMessage() async throws {
        let connection = try await connected(message: "t.Missing")
        await load(Data("{}".utf8), from: connection)
        #expect(value.schemaProblem?.contains("t.Missing") == true)
        #expect(value.format == .json)
    }

    @Test("A schema that fails to compile keeps protoc's output verbatim and marks mapped keys")
    func compileFailure() async throws {
        let stderr = "t.proto:3:1: Expected \"message\".\n"
        let connection = try await connected(
            FakeSchemaLoader(.failure(ProtocError.compilationFailed(exitCode: 1, stderr: stderr))))
        guard case .failed(let message) = connection.schemaState else {
            Issue.record("expected a failed schema, got \(connection.schemaState)")
            return
        }
        #expect(message == stderr)
        await load(TestSchema.item, from: connection)
        #expect(value.schemaProblem?.contains(stderr) == true)
    }

    @Test("A mapped key whose schema did not compile is read-only, never written as raw text")
    func misconfiguredIsReadOnly() async throws {
        let connection = try await connected(
            FakeSchemaLoader(.failure(ProtocError.compilationFailed(exitCode: 1, stderr: "bad\n"))))
        await load(TestSchema.item, from: connection)
        #expect(!value.isEditable)
        value.openInEditor()
        #expect(!value.isEditable)
        value.text = "edited"
        await value.save(to: connection)
        #expect(Gateway.txnBodies(transport).isEmpty)
    }

    @Test("A new key under a mapped prefix is stored as typed")
    func createMapped() async throws {
        let connection = try await connected()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        try await connection.createKey(key, text: #"{"name": "a", "count": 2}"#)
        #expect(try savedValue() == Data(#"{"name": "a", "count": 2}"#.utf8))
    }

    @Test("A new key outside any mapping is stored as the text's UTF-8")
    func createUnmapped() async throws {
        let connection = try await connected()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        try await connection.createKey(Data("/other".utf8), text: "plain")
        #expect(try savedValue() == Data("plain".utf8))
    }

    @Test("A new key under a mapping that cannot be honored is still stored as typed")
    func createMisconfigured() async throws {
        let connection = try await connected(message: "t.Missing")
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        try await connection.createKey(key, text: "{}")
        #expect(try savedValue() == Data("{}".utf8))
    }

    @Test("A new value is checked against the message mapped at its key")
    func checkNewValue() async throws {
        let connection = try await connected()
        #expect(await connection.checkValue(#"{"name": "a"}"#, forKey: key) == .matches)
        guard case .mismatch(let reason)? = await connection.checkValue(#"{"nope": 1}"#, forKey: key) else {
            Issue.record("expected a mismatch")
            return
        }
        #expect(reason.contains("nope"))
        #expect(await connection.checkValue("{}", forKey: Data("/other".utf8)) == nil)
    }

    @Test("Invalid JSON in a protobuf edit fails the save without writing")
    func invalidJSON() async throws {
        let connection = try await connected()
        await load(TestSchema.item, from: connection)
        value.text = "{not json"
        await value.save(to: connection)
        guard case .failed = value.saveState else {
            Issue.record("expected a failed save, got \(value.saveState)")
            return
        }
        #expect(Gateway.txnBodies(transport).isEmpty)
    }

    @Test("A mapped value stored as JSON shows and saves as typed, checked against the message")
    func jsonStored() async throws {
        let connection = try await connected()
        let stored = #"{"name":"a","count":2}"#
        await load(Data(stored.utf8), from: connection)
        #expect(value.isStoredAsJSON)
        #expect(value.format == .json)
        #expect(value.text == stored)
        #expect(value.isEditable)
        #expect(value.protobufError == nil)
        #expect(!value.availableFormats.contains(.protobuf))
        #expect(value.schemaCheck == .matches)
        let edited = #"{"name":"b","extra":1}"#
        value.text = edited
        await value.schemaCheckTask?.value
        guard case .mismatch(let reason)? = value.schemaCheck else {
            Issue.record("expected a mismatch, got \(String(describing: value.schemaCheck))")
            return
        }
        #expect(reason.contains("extra"))
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 8))
        await value.save(to: connection)
        #expect(try savedValue() == Data(edited.utf8))
        #expect(value.isStoredAsJSON)
        #expect(!value.isDirty)
    }

    @Test("A stored JSON value that does not fit the message loads with the mismatch and stays editable")
    func jsonStoredMismatch() async throws {
        let connection = try await connected()
        await load(Data(#"{"nmae": "a"}"#.utf8), from: connection)
        guard case .mismatch(let reason)? = value.schemaCheck else {
            Issue.record("expected a mismatch")
            return
        }
        #expect(reason.contains("nmae"))
        #expect(value.isEditable)
    }

    @Test("A JSON value under a mapping that cannot be honored stays editable")
    func misconfiguredJSONEditable() async throws {
        let connection = try await connected(message: "t.Missing")
        await load(Data("{}".utf8), from: connection)
        #expect(value.schemaProblem != nil)
        #expect(value.isEditable)
        #expect(value.schemaCheck == nil)
    }

    @Test("The mapping Test checks a value stored as JSON against the message")
    func mappingTestJSON() async throws {
        let connection = try await connected()
        let rules = [SchemaMappingRule(.prefix("/items/"), message: "t.Item")]
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: Data(#"{"name":"a"}"#.utf8))]))
        guard case .decoded(_, let json) = await connection.testMapping(key: "/items/1", rules: rules) else {
            Issue.record("expected a match")
            return
        }
        #expect(json.contains(#""name""#))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: Data(#"{"nope":1}"#.utf8))]))
        guard case .failed(_, let reason) = await connection.testMapping(key: "/items/1", rules: rules) else {
            Issue.record("expected a mismatch")
            return
        }
        #expect(reason.contains("nope"))
    }

    @Test("Refresh recompiles the schema with force and re-decodes clean values")
    func refresh() async throws {
        let loader = try FakeSchemaLoader(.success(TestSchema.registry()))
        let connection = try await connected(loader)
        await connection.loadSchema(force: true)
        #expect(loader.forces == [false, true])
    }

    @Test("Files the compile left out are reported until a compile leaves none out")
    func skippedFiles() async throws {
        let loader = try FakeSchemaLoader(.success(TestSchema.registry()))
        let left = SkippedProtoFile(path: "vendor/api.proto", reason: "3:1: Import \"missing.proto\" was not found.")
        loader.skipped = [left]
        let connection = try await connected(loader)
        #expect(connection.skippedSchemaFiles == [left])
        #expect(connection.schemaRegistry != nil)
        loader.skipped = []
        await connection.loadSchema(force: true)
        #expect(connection.skippedSchemaFiles.isEmpty)
    }

    @Test("Changing the live profile's mappings applies without reconnecting")
    func liveMappingChange() async throws {
        let connection = try await connected(message: "t.Missing")
        await connection.profileChanged(profile())
        await load(TestSchema.item, from: connection)
        #expect(value.format == .protobuf)
        #expect(connection.phase == .connected)
    }

    @Test("The mapping Test finds the rule a key uses and decodes its live value with it")
    func mappingTest() async throws {
        let connection = try await connected()
        let rules = [
            SchemaMappingRule(.prefix("/"), message: "t.Nope"),
            SchemaMappingRule(.prefix("/items/"), message: "t.Item"),
            SchemaMappingRule(.key("/other"), message: "t.Nope"),
        ]
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: TestSchema.item)]))
        guard case .decoded(let rule, let json) = await connection.testMapping(key: "/items/1", rules: rules) else {
            Issue.record("expected a decoded value")
            return
        }
        #expect(rule == rules[1])
        #expect(json.contains(#""name": "a""#))
        #expect(await connection.testMapping(key: "elsewhere", rules: rules) == .unmapped)
        guard case .failed(let missing, let reason) = await connection.testMapping(key: "/other", rules: rules) else {
            Issue.record("expected a failure")
            return
        }
        #expect(missing == rules[2])
        #expect(reason.contains("t.Nope"))
    }

    @Test("Message name completion matches registry names by substring")
    func completion() throws {
        let registry = try TestSchema.registry()
        #expect(MessageCompletion.suggestions(for: "ite", in: registry) == ["t.Item"])
        #expect(MessageCompletion.suggestions(for: "zzz", in: registry).isEmpty)
    }
}
