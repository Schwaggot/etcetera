import Foundation
import Testing

@testable import EtcdSchema

@Suite("JSON projection follows the proto3 JSON mapping", .tags(.unit))
struct JSONProjectionTests {
    let codec: ProtobufValueCodec

    init() throws {
        codec = try Fixtures.codec()
    }

    private func json(_ bytes: Data, _ type: String) throws -> JSONValue {
        try JSONValue.parse(codec.decodeToJSON(bytes, messageName: type).json)
    }

    @Test("Each fixture projects to its golden JSON", arguments: Fixtures.messageNames)
    func goldenFiles(name: String) throws {
        let projected = try json(Fixtures.bytes(name), Fixtures.messageType(name))
        let golden = try JSONValue.parse(Fixtures.text("golden/\(name).json"))
        #expect(projected == golden)
    }

    @Test("Output is two-space indented, in declaration order")
    func prettyPrinting() throws {
        let text = try codec.decodeToJSON(Fixtures.bytes("oneof_text"), messageName: "fixtures.v1.Oneofs").json
        #expect(text == "{\n  \"text\": \"\",\n  \"other\": \"o\"\n}")
    }

    @Test("An implicit-presence default on the wire is omitted and flagged")
    func explicitZeroOnWire() throws {
        // f_int32 = 0, which protoc never writes.
        let decoded = try codec.decodeToJSON(Data([0x18, 0x00]), messageName: "fixtures.v1.Scalars")
        #expect(decoded.json == "{}")
        #expect(!decoded.roundTrip.isFaithful)
        #expect(decoded.roundTrip.originalLength == 2)
        #expect(decoded.roundTrip.reencodedLength == 0)
    }

    @Test("Non-finite floats render as the mapping's strings")
    func nonFinite() throws {
        var writer = WireWriter()
        writer.writeTag(fieldNumber: 1, wireType: .fixed64)
        writer.writeFixed64(Double.nan.bitPattern)
        writer.writeTag(fieldNumber: 2, wireType: .fixed32)
        writer.writeFixed32((-Float.infinity).bitPattern)
        let decoded = try codec.decodeToJSON(writer.data, messageName: "fixtures.v1.Scalars")
        #expect(try JSONValue.parse(decoded.json) == .object([
            JSONMember("fDouble", .string("NaN")), JSONMember("fFloat", .string("-Infinity")),
        ]))
        #expect(decoded.roundTrip.isFaithful)
    }

    @Test("An enum number without a name renders as the number")
    func unknownEnumNumber() throws {
        let projected = try json(Data([0x80, 0x01, 0x07]), "fixtures.v1.Scalars")
        #expect(projected == .object([JSONMember("fEnum", .number("7"))]))
    }

    @Test("Timestamps format as RFC 3339 with 0, 3, 6, or 9 fraction digits",
        arguments: [
            (Int64(0), Int64(0), "1970-01-01T00:00:00Z"),
            (-1, 0, "1969-12-31T23:59:59Z"),
            (1_700_000_000, 123_000_000, "2023-11-14T22:13:20.123Z"),
            (0, 1_000, "1970-01-01T00:00:00.000001Z"),
            (0, 1, "1970-01-01T00:00:00.000000001Z"),
            (951_782_400, 0, "2000-02-29T00:00:00Z"),
            (-62_135_596_800, 0, "0001-01-01T00:00:00Z"),
            (253_402_300_799, 999_999_999, "9999-12-31T23:59:59.999999999Z"),
        ])
    func timestamps(seconds: Int64, nanos: Int64, expected: String) throws {
        #expect(try WellKnownFormats.formatTimestamp(seconds: seconds, nanos: nanos, path: "") == expected)
        let parsed = try WellKnownFormats.parseTimestamp(expected, path: "")
        #expect(parsed.0 == seconds && Int64(parsed.1) == nanos)
    }

    @Test("A timestamp outside year 1 to 9999 is an error, not a wrong date")
    func timestampRange() {
        #expect(throws: ProtoJSONError.self) {
            _ = try WellKnownFormats.formatTimestamp(seconds: 253_402_300_800, nanos: 0, path: "ts")
        }
    }

    @Test("Durations carry the sign once and use an s suffix",
        arguments: [
            (Int64(0), Int64(0), "0s"),
            (90, 500_000_000, "90.500s"),
            (-1, -500_000_000, "-1.500s"),
            (0, -500_000_000, "-0.500s"),
            (1, 340_012, "1.000340012s"),
        ])
    func durations(seconds: Int64, nanos: Int64, expected: String) throws {
        #expect(try WellKnownFormats.formatDuration(seconds: seconds, nanos: nanos, path: "") == expected)
        let parsed = try WellKnownFormats.parseDuration(expected, path: "")
        #expect(parsed.0 == seconds && Int64(parsed.1) == nanos)
    }

    @Test("A duration with mixed signs is an error")
    func mixedSignDuration() {
        #expect(throws: ProtoJSONError.self) {
            _ = try WellKnownFormats.formatDuration(seconds: 1, nanos: -1, path: "")
        }
    }

    @Test("Field mask paths convert between snake_case and lowerCamelCase")
    func fieldMaskPaths() throws {
        #expect(try WellKnownFormats.camelPath("user.display_name", path: "") == "user.displayName")
        #expect(try WellKnownFormats.snakePath("user.displayName", path: "") == "user.display_name")
        #expect(throws: ProtoJSONError.self) {
            _ = try WellKnownFormats.camelPath("user.Display", path: "")
        }
    }

    @Test("Floating point values print shortest round-trip text")
    func floatFormatting() {
        #expect(ProtoJSONMapper.format(Double(1)) == "1")
        #expect(ProtoJSONMapper.format(0.1) == "0.1")
        #expect(ProtoJSONMapper.format(Float(0.1)) == "0.1")
        #expect(ProtoJSONMapper.format(-0.0) == "-0")
        #expect(ProtoJSONMapper.format(1e300) == "1e+300")
    }
}
