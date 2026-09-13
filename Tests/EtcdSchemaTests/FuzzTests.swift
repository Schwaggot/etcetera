import Foundation
import Testing

@testable import EtcdSchema

// The decoder is fed malformed and truncated input. It must throw, never
// crash, never hang. See SPEC 6.5.

@Suite("Wire decoder under hostile input", .tags(.fuzz))
struct FuzzTests {
    let registry: SchemaRegistry
    let codec: WireCodec
    static let types = [
        "fixtures.v1.Scalars", "fixtures.v1.Nested", "fixtures.v1.Maps", "fixtures.v1.Repeated",
        "fixtures.v1.Oneofs", "fixtures.v1.WellKnown", "fixtures.v1.Legacy",
    ]

    init() throws {
        registry = try Fixtures.registry()
        codec = WireCodec(registry: registry)
    }

    /// Anything that decodes must re-encode stably.
    private func check(_ bytes: Data, as type: String) {
        guard let message = try? codec.decode(bytes, as: type) else { return }
        let once = codec.encode(message)
        guard let again = try? codec.decode(once, as: type) else {
            Issue.record("re-encoded bytes failed to decode for \(type)")
            return
        }
        #expect(codec.encode(again) == once)
        _ = try? ProtobufValueCodec(registry: registry).decodeToJSON(bytes, messageName: type)
    }

    @Test("Random bytes throw or decode, never crash", arguments: types)
    func randomBytes(type: String) {
        var generator = SeededGenerator(seed: UInt64(type.utf8.count) &* 7919)
        for _ in 0..<1500 {
            let length = Int.random(in: 0...64, using: &generator)
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            check(bytes, as: type)
        }
    }

    @Test("Every truncation and bit flip of every fixture is handled", arguments: Fixtures.messageNames)
    func mutations(name: String) throws {
        let bytes = try Fixtures.bytes(name)
        let type = try Fixtures.messageType(name)
        for length in 0..<bytes.count {
            check(bytes.prefix(length), as: type)
        }
        for index in bytes.indices {
            for bit in 0..<8 {
                var flipped = bytes
                flipped[index] ^= UInt8(1 << bit)
                check(flipped, as: type)
            }
        }
    }

    @Test("Hostile length prefixes throw before allocating")
    func hostileLength() {
        // Field 1 (string) claiming about 2^63 bytes; three follow.
        let bytes = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x61, 0x62, 0x63])
        #expect {
            _ = try codec.decode(bytes, as: "fixtures.v1.Nested")
        } throws: { error in
            guard let error = error as? MessageDecodingError, case .hostileLength = error.reason else { return false }
            return true
        }
        // The same for a packed field.
        let packed = Data([0x0A, 0xFE, 0xFF, 0xFF, 0xFF, 0x0F, 0x01])
        #expect(throws: MessageDecodingError.self) {
            _ = try codec.decode(packed, as: "fixtures.v1.Repeated")
        }
    }

    /// SPEC 6.5 asks for no more than the input length, which a decoded tree
    /// cannot meet literally; this pins a linear bound on what a decode keeps.
    /// The worst inputs measure about 44 bytes per byte, a heap box per
    /// two-byte message plus array growth; 64 leaves room for that growth.
    static let retainedBytesPerInputByte = 64
    static let retainedSlack = 16 << 10

    @Test("Decoding retains at most a small multiple of the input length")
    func retainedMemoryIsLinear() async {
        // A child process, since malloc statistics are process-wide and
        // other tests run in parallel. It reports on stderr so the numbers
        // reach the failure message.
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            if let violation = try FuzzTests.retainedMemoryViolation() {
                FileHandle.standardError.write(Data("violation: \(violation)".utf8))
            }
        }
        let report = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(!report.contains("violation:"), Comment(rawValue: report))
    }

    /// The costliest inputs per byte: packed one-byte varints, and repeated
    /// two-byte elements that each become a value.
    static func denseInputs(count: Int) -> [(Data, String)] {
        func repeated(_ tag: UInt8, _ element: [UInt8]) -> Data {
            Data((0..<count).flatMap { _ in [tag, UInt8(element.count)] + element })
        }
        var packed = WireWriter()
        packed.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
        packed.writeLengthDelimited([UInt8](repeating: 1, count: count))
        return [
            (packed.data, "fixtures.v1.Repeated"),
            (repeated(0x1A, []), "fixtures.v1.Nested"),  // items {}
            (repeated(0x1A, [0x0A, 0x00]), "fixtures.v1.Nested"),  // items { name: "" }
            (repeated(0x2A, []), "fixtures.v1.Repeated"),  // names: ""
            (repeated(0x0A, []), "fixtures.v1.Maps"),  // labels {}
            (Data((0..<count).flatMap { _ in [UInt8(0x48), 0x00] }), "fixtures.v1.Nested"),  // unknown field 9
        ]
    }

    static func retainedMemoryViolation() throws -> String? {
        let codec = WireCodec(registry: try Fixtures.registry())
        var inputs = denseInputs(count: 20_000)
        for name in Fixtures.messageNames {
            let bytes = try Fixtures.bytes(name)
            let type = try Fixtures.messageType(name)
            inputs += (0...bytes.count).map { (bytes.prefix($0), type) }
        }
        var generator = SeededGenerator(seed: 65)
        for type in types {
            for _ in 0..<200 {
                let length = Int.random(in: 0...512, using: &generator)
                inputs.append((Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }), type))
            }
        }
        func inUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }
        for (bytes, type) in inputs { _ = try? codec.decode(bytes, as: type) }  // warm the runtime's caches
        for (bytes, type) in inputs {
            // The least of three, so a stray runtime allocation is not blamed on the decoder.
            var retained = Int.max
            for _ in 0..<3 {
                let before = inUse()
                let message = try? codec.decode(bytes, as: type)
                retained = min(retained, inUse() - before)
                withExtendedLifetime(message) {}
            }
            if retained > retainedBytesPerInputByte * bytes.count + retainedSlack {
                return "decoding \(bytes.count) bytes as \(type) retained \(retained) bytes"
            }
        }
        return nil
    }

    private func innerChain(depth: Int) -> Data {
        var payload: [UInt8] = [0x0A, 0x01, 0x63]  // name: "c"
        for _ in 0..<depth {
            var writer = WireWriter()
            writer.writeTag(fieldNumber: 2, wireType: .lengthDelimited)
            writer.writeLengthDelimited(payload)
            payload = writer.bytes
        }
        return Data(payload)
    }

    @Test("Nesting beyond the depth limit throws, within it decodes")
    func depthLimit() throws {
        #expect(throws: MessageDecodingError.self) {
            _ = try codec.decode(innerChain(depth: 150), as: "fixtures.v1.Nested.Inner")
        }
        _ = try codec.decode(innerChain(depth: 50), as: "fixtures.v1.Nested.Inner")
    }

    @Test("A message nested just within the depth limit decodes and renders")
    func renderAtDepthLimit() throws {
        let decoded = try ProtobufValueCodec(registry: registry)
            .decodeToJSON(innerChain(depth: 99), messageName: "fixtures.v1.Nested.Inner")
        #expect(decoded.roundTrip.isFaithful)
    }

    @Test("Deeply nested groups throw instead of overflowing the stack")
    func deepGroups() {
        let bytes = Data([UInt8](repeating: 0x4B, count: 10_000))  // field 9 start group, repeated
        #expect(throws: MessageDecodingError.self) {
            _ = try codec.decode(bytes, as: "fixtures.v1.Nested")
        }
    }

    @Test("A duration of Int64.min seconds is a projection error, not a trap")
    func durationAtInt64Min() {
        // WellKnown.dur { seconds: Int64.min }
        let seconds: [UInt8] = [0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        let bytes = Data([0x12, UInt8(seconds.count)] + seconds)
        #expect(throws: ProtoJSONError.self) {
            _ = try ProtobufValueCodec(registry: registry).decodeToJSON(bytes, messageName: "fixtures.v1.WellKnown")
        }
    }

    @Test("Deeply nested Any payloads throw instead of overflowing the stack")
    func deepAny() {
        // WellKnown.any holding an Any holding an Any, 5000 deep. Built
        // outside in from precomputed sizes to stay linear.
        let typeURL = Array("/google.protobuf.Any".utf8)
        func header(payloadSize: Int) -> [UInt8] {
            var writer = WireWriter()
            writer.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
            writer.writeLengthDelimited(typeURL)
            writer.writeTag(fieldNumber: 2, wireType: .lengthDelimited)
            writer.writeVarint(UInt64(payloadSize))
            return writer.bytes
        }
        var sizes = [0]
        for _ in 0..<5000 {
            sizes.append(header(payloadSize: sizes.last!).count + sizes.last!)
        }
        var writer = WireWriter()
        writer.writeTag(fieldNumber: 16, wireType: .lengthDelimited)
        writer.writeVarint(UInt64(sizes.last!))
        for size in sizes.dropLast().reversed() {
            writer.writeRaw(header(payloadSize: size))
        }
        let bytes = writer.data
        #expect {
            _ = try ProtobufValueCodec(registry: registry).decodeToJSON(bytes, messageName: "fixtures.v1.WellKnown")
        } throws: { error in
            (error as? MessageDecodingError)?.reason == .tooDeep
        }
    }

    @Test("JSON Values nested to the parser's limit convert, and encoding refuses them, without overflowing the stack")
    func deepJSONValue() throws {
        let json = #"{"val": "# + String(repeating: "[", count: 199) + String(repeating: "]", count: 199) + "}"
        let proto = ProtobufValueCodec(registry: registry)
        _ = try proto.message(fromJSON: json, messageName: "fixtures.v1.WellKnown")
        #expect(throws: ProtoJSONError.self) {
            _ = try proto.encodeFromJSON(json, messageName: "fixtures.v1.WellKnown", originalBytes: nil)
        }
    }

    @Test("An edit nested past the decode limit is refused, so no value is saved that cannot be opened")
    func encodeRefusesBeyondDecodeLimit() throws {
        let proto = ProtobufValueCodec(registry: registry, maxDepth: 8)
        let bytes = try proto.encodeFromJSON(#"{"val": [[1]]}"#, messageName: "fixtures.v1.WellKnown", originalBytes: nil)
        _ = try proto.decodeToJSON(bytes, messageName: "fixtures.v1.WellKnown")
        let deep = #"{"val": "# + String(repeating: "[", count: 10) + String(repeating: "]", count: 10) + "}"
        #expect(throws: ProtoJSONError.self) {
            _ = try proto.encodeFromJSON(deep, messageName: "fixtures.v1.WellKnown", originalBytes: nil)
        }
    }

    @Test("A stray end-group tag is an error")
    func strayEndGroup() {
        #expect(throws: MessageDecodingError.self) {
            _ = try codec.decode(Data([0x4C]), as: "fixtures.v1.Nested")
        }
    }

    @Test("Deeply nested JSON throws instead of overflowing the stack")
    func deepJSON() {
        #expect(throws: JSONSyntaxError.self) {
            _ = try JSONValue.parse(String(repeating: "[", count: 100_000))
        }
    }

    @Test("Random JSON-ish text never crashes the parser or the mapper")
    func randomJSON() throws {
        let alphabet = Array(#"{}[]",:0123456789.-eE"tfnrul \"fInt32" "fEnum" "COLOR_RED" "#)
        let proto = ProtobufValueCodec(registry: registry)
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<3000 {
            let length = Int.random(in: 0...40, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            _ = try? JSONValue.parse(text)
            _ = try? proto.message(fromJSON: text, messageName: "fixtures.v1.Scalars")
        }
    }

    @Test("A sub-reader outside its buffer is a precondition failure, not a bad read")
    func subReaderPrecondition() async {
        await #expect(processExitsWith: .failure) {
            _ = WireReader(sharing: [1, 2], range: 0..<5)
        }
    }
}
