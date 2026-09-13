import Foundation
import Testing

@testable import EtcdSchema

@Suite("Varint coding")
struct VarintTests {
    @Test("Round trips reference values",
        arguments: [
            UInt64(0), 1, 127, 128, 300, 16_383, 16_384,
            UInt64(UInt32.max), UInt64.max,
        ])
    func roundTrips(value: UInt64) throws {
        var writer = WireWriter()
        writer.writeVarint(value)
        var reader = WireReader(writer.bytes)
        #expect(try reader.readVarint() == value)
        #expect(reader.isAtEnd)
    }

    @Test("Decodes the classic 300 example")
    func decodes300() throws {
        var reader = WireReader([0xAC, 0x02])
        #expect(try reader.readVarint() == 300)
    }

    @Test("A truncated varint throws, never hangs")
    func truncated() {
        var reader = WireReader([0x80, 0x80])
        #expect(throws: WireDecodingError.truncated) {
            _ = try reader.readVarint()
        }
    }

    @Test("A varint longer than 10 bytes throws")
    func tooLong() {
        var reader = WireReader([UInt8](repeating: 0x80, count: 11))
        #expect(throws: WireDecodingError.varintTooLong) {
            _ = try reader.readVarint()
        }
    }
}

@Suite("Zigzag coding")
struct ZigzagTests {
    @Test("Matches the reference table",
        arguments: [
            (Int64(0), UInt64(0)),
            (Int64(-1), UInt64(1)),
            (Int64(1), UInt64(2)),
            (Int64(-2), UInt64(3)),
            (Int64(2147483647), UInt64(4294967294)),
            (Int64(-2147483648), UInt64(4294967295)),
            (Int64.max, UInt64.max - 1),
            (Int64.min, UInt64.max),
        ])
    func referenceTable(decoded: Int64, encoded: UInt64) {
        #expect(zigzagEncode(decoded) == encoded)
        #expect(zigzagDecode(encoded) == decoded)
    }
}

@Suite("Tags and wire types")
struct TagTests {
    @Test("Reads field number and wire type from a tag")
    func readsTag() throws {
        // Field 1, wire type 2: (1 << 3) | 2 = 0x0A.
        var reader = WireReader([0x0A, 0x00])
        let tag = try #require(try reader.readTag())
        #expect(tag.fieldNumber == 1)
        #expect(tag.wireType == .lengthDelimited)
    }

    @Test("Returns nil at the end of input")
    func nilAtEnd() throws {
        var reader = WireReader([])
        #expect(try reader.readTag() == nil)
    }

    @Test("Field number zero is invalid")
    func fieldZero() {
        var reader = WireReader([0x00])
        #expect(throws: WireDecodingError.invalidTag) {
            _ = try reader.readTag()
        }
    }

    @Test("The deprecated group wire types are rejected, not parsed")
    func groupsRejected() {
        var startGroup = WireReader([0x0B])  // field 1, wire type 3
        #expect(throws: WireDecodingError.deprecatedGroup) {
            _ = try startGroup.readTag()
        }
        var endGroup = WireReader([0x0C])  // field 1, wire type 4
        #expect(throws: WireDecodingError.deprecatedGroup) {
            _ = try endGroup.readTag()
        }
    }

    @Test("Wire types 6 and 7 are invalid")
    func invalidWireTypes() {
        var reader = WireReader([0x0E])  // field 1, wire type 6
        #expect(throws: WireDecodingError.invalidWireType(6)) {
            _ = try reader.readTag()
        }
    }
}

@Suite("Length-delimited fields")
struct LengthDelimitedTests {
    @Test("Reads the exact slice")
    func readsSlice() throws {
        var reader = WireReader([0x03, 0x61, 0x62, 0x63, 0xFF])
        let slice = try reader.readLengthDelimited()
        #expect(Array(slice) == [0x61, 0x62, 0x63])
        #expect(reader.index == 4)
    }

    @Test("A hostile length prefix throws before allocating")
    func hostileLength() {
        // Claims 2^63 bytes follow; two actually do.
        var reader = WireReader([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x61, 0x62])
        #expect(throws: WireDecodingError.self) {
            _ = try reader.readLengthDelimited()
        }
    }

    @Test("A length just past the end throws truncated-style, not crash")
    func lengthPastEnd() {
        var reader = WireReader([0x05, 0x61, 0x62])
        #expect(throws: WireDecodingError.hostileLength(5)) {
            _ = try reader.readLengthDelimited()
        }
    }
}

@Suite("Fixed-width fields")
struct FixedWidthTests {
    @Test("fixed32 and fixed64 are little endian")
    func littleEndian() throws {
        var writer = WireWriter()
        writer.writeFixed32(0x0102_0304)
        #expect(writer.bytes == [0x04, 0x03, 0x02, 0x01])
        var reader = WireReader(writer.bytes)
        #expect(try reader.readFixed32() == 0x0102_0304)

        var writer64 = WireWriter()
        writer64.writeFixed64(0x0102_0304_0506_0708)
        var reader64 = WireReader(writer64.bytes)
        #expect(try reader64.readFixed64() == 0x0102_0304_0506_0708)
    }

    @Test("Truncated fixed fields throw")
    func truncatedFixed() {
        var reader = WireReader([0x01, 0x02])
        #expect(throws: WireDecodingError.truncated) {
            _ = try reader.readFixed32()
        }
    }
}

@Suite("Skipping unknown fields")
struct SkipTests {
    @Test("Skips every wire type and lands on the next tag")
    func skipsAll() throws {
        var writer = WireWriter()
        writer.writeTag(fieldNumber: 1, wireType: .varint)
        writer.writeVarint(300)
        writer.writeTag(fieldNumber: 2, wireType: .fixed64)
        writer.writeFixed64(7)
        writer.writeTag(fieldNumber: 3, wireType: .lengthDelimited)
        writer.writeLengthDelimited([0x61, 0x62])
        writer.writeTag(fieldNumber: 4, wireType: .fixed32)
        writer.writeFixed32(9)
        writer.writeTag(fieldNumber: 5, wireType: .varint)
        writer.writeVarint(1)

        var reader = WireReader(writer.bytes)
        var seenFields: [Int] = []
        while let tag = try reader.readTag() {
            seenFields.append(tag.fieldNumber)
            try reader.skip(wireType: tag.wireType)
        }
        #expect(seenFields == [1, 2, 3, 4, 5])
        #expect(reader.isAtEnd)
    }
}
