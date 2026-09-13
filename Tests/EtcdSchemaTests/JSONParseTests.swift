import Foundation
import SwiftProtobuf
import Testing

@testable import EtcdSchema

@Suite("JSON back to protobuf for editing", .tags(.unit))
struct JSONParseTests {
    let codec: ProtobufValueCodec

    init() throws {
        codec = try Fixtures.codec()
    }

    private func parse(_ json: String, _ type: String) throws -> DynamicMessage {
        try codec.message(fromJSON: json, messageName: type)
    }

    private func parseError(_ json: String, _ type: String) -> ProtoJSONError? {
        do {
            _ = try parse(json, type)
            return nil
        } catch let error as ProtoJSONError {
            return error
        } catch {
            return nil
        }
    }

    @Test("Accepts original proto names as well as JSON names")
    func bothNames() throws {
        let message = try parse(#"{"f_int32": 5, "fInt64": "7"}"#, "fixtures.v1.Scalars")
        #expect(message.value(named: "f_int32") == .single(.int32(5)))
        #expect(message.value(named: "f_int64") == .single(.int64(7)))
    }

    @Test("A float field takes the largest finite float and rejects what overflows it")
    func floatLimits() throws {
        let message = try parse(#"{"fFloat": 3.4028235e+38}"#, "fixtures.v1.Scalars")
        #expect(message.value(named: "f_float") == .single(.float(.greatestFiniteMagnitude)))
        #expect(parseError(#"{"fFloat": 3.5e38}"#, "fixtures.v1.Scalars")?.reason.contains("out of range") == true)
    }

    @Test("A save without a proto2 required field is refused, since proto2 readers would reject it")
    func requiredField() throws {
        #expect {
            _ = try codec.encodeFromJSON(#"{"a": 1}"#, messageName: "fixtures.v1.Legacy", originalBytes: nil)
        } throws: { error in
            (error as? ProtoJSONError)?.path == "c"
        }
        _ = try codec.encodeFromJSON(#"{"a": 1, "c": "x"}"#, messageName: "fixtures.v1.Legacy", originalBytes: nil)
    }

    @Test("Rejects an unknown field and names its path")
    func unknownField() throws {
        let error = try #require(parseError(#"{"inner": {"nmae": "x"}}"#, "fixtures.v1.Nested"))
        #expect(error.path == "inner.nmae")
        #expect(error.reason.contains("unknown field"))
    }

    @Test("Rejects two members of one oneof")
    func oneofConflict() throws {
        let error = try #require(parseError(#"{"text": "a", "number": "1"}"#, "fixtures.v1.Oneofs"))
        #expect(error.path == "number")
    }

    @Test("Rejects a field given twice under both names")
    func duplicateField() {
        #expect(parseError(#"{"f_int32": 1, "fInt32": 2}"#, "fixtures.v1.Scalars") != nil)
    }

    @Test("64-bit integers accept strings and numbers")
    func int64Forms() throws {
        let message = try parse(#"{"fInt64": 5, "fUint64": "18446744073709551615"}"#, "fixtures.v1.Scalars")
        #expect(message.value(named: "fInt64") == .single(.int64(5)))
        #expect(message.value(named: "fUint64") == .single(.uint64(.max)))
    }

    @Test("Out of range integers are rejected",
        arguments: [#"{"fInt32": 2147483648}"#, #"{"fUint32": -1}"#, #"{"fInt64": "9223372036854775808"}"#])
    func outOfRange(json: String) {
        #expect(parseError(json, "fixtures.v1.Scalars") != nil)
    }

    @Test("Integral exponent forms are accepted, fractions are not")
    func exponentForms() throws {
        #expect(try parse(#"{"fInt32": 1e3}"#, "fixtures.v1.Scalars").value(named: "fInt32") == .single(.int32(1000)))
        #expect(parseError(#"{"fInt32": 1.5}"#, "fixtures.v1.Scalars") != nil)
    }

    @Test("Enums accept names and numbers and reject unknown names")
    func enums() throws {
        #expect(try parse(#"{"fEnum": "COLOR_RED"}"#, "fixtures.v1.Scalars").value(named: "fEnum") == .single(.enumeration(1)))
        #expect(try parse(#"{"fEnum": 9}"#, "fixtures.v1.Scalars").value(named: "fEnum") == .single(.enumeration(9)))
        #expect(parseError(#"{"fEnum": "COLOR_BLUE"}"#, "fixtures.v1.Scalars")?.path == "fEnum")
    }

    @Test("Bytes accept standard and URL-safe base64, with or without padding")
    func base64Forms() throws {
        #expect(try parse(#"{"fBytes": "AP9hYg"}"#, "fixtures.v1.Scalars").value(named: "fBytes")
            == .single(.bytes(Data([0x00, 0xFF, 0x61, 0x62]))))
        #expect(try parse(#"{"fBytes": "_w"}"#, "fixtures.v1.Scalars").value(named: "fBytes")
            == .single(.bytes(Data([0xFF]))))
        #expect(parseError(#"{"fBytes": "%%%"}"#, "fixtures.v1.Scalars") != nil)
    }

    @Test("Null means absent for an ordinary field")
    func nullIsAbsent() throws {
        #expect(try parse(#"{"title": null}"#, "fixtures.v1.Nested").isEmpty)
    }

    @Test("Implicit-presence defaults are not stored, explicit ones are")
    func presenceOnParse() throws {
        #expect(try parse(#"{"plainInt": 0}"#, "fixtures.v1.Optionals").isEmpty)
        #expect(try parse(#"{"maybeInt": 0}"#, "fixtures.v1.Optionals").value(named: "maybeInt") == .single(.int32(0)))
    }

    @Test("Timestamp offsets normalize to UTC")
    func timestampOffset() throws {
        let parsed = try WellKnownFormats.parseTimestamp("2023-11-14T23:13:20.123+01:00", path: "")
        #expect(parsed.0 == 1_700_000_000)
        #expect(parsed.1 == 123_000_000)
    }

    @Test("Malformed timestamps and durations are rejected",
        arguments: ["2023-13-01T00:00:00Z", "2023-02-30T00:00:00Z", "2023-01-01 00:00:00Z", "2023-01-01T00:00:00"])
    func malformedTimestamps(text: String) {
        #expect(throws: ProtoJSONError.self) { _ = try WellKnownFormats.parseTimestamp(text, path: "") }
    }

    @Test("Malformed durations are rejected", arguments: ["1", "s", "1.0000000001s", "--1s", "1.s"])
    func malformedDurations(text: String) {
        #expect(throws: ProtoJSONError.self) { _ = try WellKnownFormats.parseDuration(text, path: "") }
    }

    @Test("Any with an unresolvable type needs its raw value")
    func unresolvedAny() {
        let json = #"{"any": {"@type": "type.googleapis.com/acme.Missing", "name": "x"}}"#
        #expect(parseError(json, "fixtures.v1.WellKnown")?.path == "any")
    }

    @Test("Any of a resolvable type encodes the embedded message")
    func resolvedAny() throws {
        let json = #"{"any": {"@type": "type.googleapis.com/fixtures.v1.Nested.Inner", "name": "in any"}}"#
        let message = try parse(json, "fixtures.v1.WellKnown")
        let any = try #require(message.value(named: "any")?.values.first?.message)
        #expect(any.value(forField: 2) == .single(.bytes(Data([0x0A, 0x06] + Array("in any".utf8)))))
    }

    @Test("A wrong JSON type names the field")
    func wrongType() {
        #expect(parseError(#"{"fBool": "yes"}"#, "fixtures.v1.Scalars")?.path == "fBool")
        #expect(parseError(#"{"items": {}}"#, "fixtures.v1.Nested")?.path == "items")
        #expect(parseError(#"{"labels": {"a": 1}}"#, "fixtures.v1.Maps")?.path == #"labels["a"]"#)
    }

    @Test("Map keys are parsed by the key type")
    func mapKeys() throws {
        let message = try parse(#"{"flags": {"true": "1"}, "byId": {"-3": {}}}"#, "fixtures.v1.Maps")
        let flag = try #require(message.value(named: "flags")?.values.first?.message)
        #expect(flag.value(forField: 1) == .single(.bool(true)))
        #expect(parseError(#"{"flags": {"yes": "1"}}"#, "fixtures.v1.Maps") != nil)
        #expect(parseError(#"{"byId": {"x": {}}}"#, "fixtures.v1.Maps") != nil)
    }
}

@Suite("Order-preserving JSON", .tags(.unit))
struct JSONValueTests {
    @Test("Keeps key order and number text exactly")
    func keepsOrderAndText() throws {
        let value = try JSONValue.parse(#"{"b": 1.50, "a": 18446744073709551615}"#)
        #expect(value == .object([JSONMember("b", .number("1.50")), JSONMember("a", .number("18446744073709551615"))]))
    }

    @Test("Decodes escapes and surrogate pairs")
    func escapes() throws {
        let value = try JSONValue.parse(#""\u00e9\ud83d\ude00\n\/""#)
        #expect(value == .string("\u{E9}\u{1F600}\n/"))
    }

    @Test("Rejects invalid documents",
        arguments: ["[1,]", "{\"a\":1,}", "01", "\"\u{01}\"", "[1] x", "\"\\ud800\"", "{a: 1}", "-", "1.", ""])
    func rejects(text: String) {
        #expect(throws: JSONSyntaxError.self) { _ = try JSONValue.parse(text) }
    }

    @Test("Syntax errors carry line and column")
    func errorPosition() {
        do {
            _ = try JSONValue.parse("{\n  \"a\": ,\n}")
            Issue.record("expected a syntax error")
        } catch let error as JSONSyntaxError {
            #expect(error.line == 2)
            #expect(error.column == 8)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Renders with two-space indent and escapes control characters")
    func rendering() {
        let value = JSONValue.object([
            JSONMember("a", .array([.number("1"), .null])), JSONMember("b\n", .string("\u{01}\"")),
            JSONMember("c", .object([])),
        ])
        #expect(value.rendered() == "{\n  \"a\": [\n    1,\n    null\n  ],\n  \"b\\n\": \"\\u0001\\\"\",\n  \"c\": {}\n}")
    }

    /// proto2 `optional group G = 1 { optional int32 x = 1; }` inside p.A.
    private func groupRegistry() throws -> SchemaRegistry {
        var x = Google_Protobuf_FieldDescriptorProto()
        x.name = "x"
        x.number = 1
        x.label = .optional
        x.type = .int32
        var group = Google_Protobuf_DescriptorProto()
        group.name = "G"
        group.field = [x]
        var g = Google_Protobuf_FieldDescriptorProto()
        g.name = "g"
        g.number = 1
        g.label = .optional
        g.type = .group
        g.typeName = ".p.A.G"
        var message = Google_Protobuf_DescriptorProto()
        message.name = "A"
        message.field = [g]
        message.nestedType = [group]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "p.proto"
        file.package = "p"
        file.syntax = "proto2"
        file.messageType = [message]
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [file]
        return try SchemaRegistry(fileDescriptorSet: set)
    }

    @Test("A proto2 group field in edited JSON is rejected, since groups are skipped rather than parsed")
    func groupFieldRejected() throws {
        let codec = ProtobufValueCodec(registry: try groupRegistry())
        #expect(throws: ProtoJSONError.self) {
            _ = try codec.encodeFromJSON(#"{"g": {"x": 1}}"#, messageName: "p.A", originalBytes: nil)
        }
    }

    @Test("A user schema that redefines ListValue without field 1 is an error, not a trap")
    func listValueWithoutField() throws {
        var message = Google_Protobuf_DescriptorProto()
        message.name = "ListValue"
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "shadow.proto"
        file.package = "google.protobuf"
        file.syntax = "proto3"
        file.messageType = [message]
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [file]
        let codec = ProtobufValueCodec(registry: try SchemaRegistry(fileDescriptorSet: set))
        #expect(throws: ProtoJSONError.self) {
            _ = try codec.decodeToJSON(Data(), messageName: "google.protobuf.ListValue")
        }
    }

    @Test("A group value built in code is not encoded and does not trap")
    func groupValueNotEncoded() throws {
        let registry = try groupRegistry()
        let a = try #require(registry.message(named: "p.A"))
        let g = try #require(registry.message(named: "p.A.G"))
        var message = DynamicMessage(descriptor: a)
        message.set(.single(.message(DynamicMessage(descriptor: g))), forField: 1)
        #expect(WireCodec(registry: registry).encode(message).isEmpty)
    }
}
