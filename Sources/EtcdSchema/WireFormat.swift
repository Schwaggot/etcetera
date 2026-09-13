import Foundation

// The protobuf binary wire format, implemented directly because no Swift
// library decodes a message from a runtime descriptor. See SPEC 5.4.

public enum WireDecodingError: Error, Sendable, Equatable {
    case truncated
    case varintTooLong
    case invalidWireType(UInt8)
    case invalidTag
    /// A length prefix that exceeds the remaining input.
    case hostileLength(UInt64)
    case deprecatedGroup
    case malformedUTF8
    /// An end-group tag without a matching start-group tag.
    case unexpectedEndGroup
    /// Nesting beyond the decoder's recursion limit.
    case tooDeep
}

extension WireDecodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .truncated:
            String(localized: "the data ends in the middle of a field", bundle: .module)
        case .varintTooLong:
            String(localized: "an integer is encoded with more than 10 bytes", bundle: .module)
        case .invalidWireType(let wireType):
            String(localized: "a field uses the unknown wire type \(Int(wireType))", bundle: .module)
        case .invalidTag:
            String(localized: "a field has an invalid field number", bundle: .module)
        case .hostileLength(let length):
            String(localized: "a field claims \(length) bytes, more than the data holds", bundle: .module)
        case .deprecatedGroup:
            String(localized: "the data uses the deprecated group encoding", bundle: .module)
        case .malformedUTF8:
            String(localized: "a text field is not valid UTF-8", bundle: .module)
        case .unexpectedEndGroup:
            String(localized: "a group ends without having started", bundle: .module)
        case .tooDeep:
            String(localized: "messages are nested too deeply", bundle: .module)
        }
    }
}

/// Wire types 0, 1, 2, 5. The deprecated groups (3 and 4) are not produced
/// by proto3: `readTag` rejects them, and `WireCodec` skips them whole via `skipGroup`.
public enum WireType: UInt8, Sendable, Equatable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// A bounds-checked reader over the raw bytes. It must throw, never crash,
/// never hang, and never allocate more than the input length.
public struct WireReader {
    @usableFromInline let bytes: [UInt8]
    public private(set) var index: Int
    /// Exclusive bound; sub-readers share `bytes` and narrow it.
    public let end: Int

    public init(_ data: Data) {
        self.init([UInt8](data))
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.index = 0
        self.end = bytes.count
    }

    /// A reader over `range` of `bytes` without copying them.
    public init(sharing bytes: [UInt8], range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= bytes.count)
        self.bytes = bytes
        self.index = range.lowerBound
        self.end = range.upperBound
    }

    public var isAtEnd: Bool { index >= end }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < end else { throw WireDecodingError.truncated }
            guard shift < 64 else { throw WireDecodingError.varintTooLong }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// Reads a field tag. Returns nil at the end of the input.
    public mutating func readTag() throws -> (fieldNumber: Int, wireType: WireType)? {
        guard let (fieldNumber, rawWireType) = try readRawTag() else { return nil }
        if rawWireType == 3 || rawWireType == 4 {
            throw WireDecodingError.deprecatedGroup
        }
        guard let wireType = WireType(rawValue: rawWireType) else {
            throw WireDecodingError.invalidWireType(rawWireType)
        }
        return (fieldNumber, wireType)
    }

    /// Reads a tag and returns the raw wire type, including 3 and 4, so a
    /// decoder can skip groups. Wire types 6 and 7 still throw.
    public mutating func readRawTag() throws -> (fieldNumber: Int, wireType: UInt8)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let rawWireType = UInt8(tag & 0x7)
        let fieldNumber = tag >> 3
        guard fieldNumber > 0, fieldNumber <= 536_870_911 else {
            throw WireDecodingError.invalidTag
        }
        guard rawWireType <= 5 else {
            throw WireDecodingError.invalidWireType(rawWireType)
        }
        return (Int(fieldNumber), rawWireType)
    }

    public mutating func readFixed32() throws -> UInt32 {
        guard end - index >= 4 else { throw WireDecodingError.truncated }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(bytes[index + i]) << (8 * UInt32(i))
        }
        index += 4
        return value
    }

    public mutating func readFixed64() throws -> UInt64 {
        guard end - index >= 8 else { throw WireDecodingError.truncated }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[index + i]) << (8 * UInt64(i))
        }
        index += 8
        return value
    }

    /// Reads a length-delimited slice. Hostile length prefixes throw before
    /// any allocation.
    public mutating func readLengthDelimited() throws -> ArraySlice<UInt8> {
        let range = try readLengthDelimitedRange()
        return bytes[range]
    }

    /// Reads a length-delimited payload as a sub-reader sharing storage.
    public mutating func readSubReader() throws -> WireReader {
        let range = try readLengthDelimitedRange()
        return WireReader(sharing: bytes, range: range)
    }

    private mutating func readLengthDelimitedRange() throws -> Range<Int> {
        let length = try readVarint()
        guard length <= UInt64(end - index) else {
            throw WireDecodingError.hostileLength(length)
        }
        let range = index..<(index + Int(length))
        index += Int(length)
        return range
    }

    /// The elements left in a packed payload of the given wire type, so the
    /// decoder can reserve exactly.
    public func packedElementCount(wireType: UInt8) -> Int {
        switch wireType {
        case 1: return (end - index) / 8
        case 5: return (end - index) / 4
        default: return bytes[index..<end].reduce(0) { $0 + ($1 < 0x80 ? 1 : 0) }
        }
    }

    /// Skips one field of the given wire type, for unknown field handling.
    public mutating func skip(wireType: WireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            _ = try readFixed64()
        case .lengthDelimited:
            _ = try readLengthDelimited()
        case .fixed32:
            _ = try readFixed32()
        }
    }

    /// Skips a group body after its start tag, through the matching end
    /// tag. Nested groups count against `depthLimit`.
    public mutating func skipGroup(fieldNumber: Int, depthLimit: Int) throws {
        guard depthLimit > 0 else { throw WireDecodingError.tooDeep }
        while let (number, wireType) = try readRawTag() {
            switch wireType {
            case 3:
                try skipGroup(fieldNumber: number, depthLimit: depthLimit - 1)
            case 4:
                guard number == fieldNumber else { throw WireDecodingError.unexpectedEndGroup }
                return
            default:
                try skip(wireType: WireType(rawValue: wireType)!)
            }
        }
        throw WireDecodingError.truncated
    }

    /// The bytes between two indices, for retaining unknown fields verbatim.
    public func raw(from start: Int, to stop: Int) -> ArraySlice<UInt8> {
        bytes[start..<stop]
    }
}

/// Zigzag decoding for sint32 and sint64.
@inlinable
public func zigzagDecode(_ value: UInt64) -> Int64 {
    Int64(value >> 1) ^ -Int64(value & 1)
}

@inlinable
public func zigzagEncode(_ value: Int64) -> UInt64 {
    UInt64(bitPattern: (value << 1) ^ (value >> 63))
}

/// An append-only writer emitting the wire format.
public struct WireWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var data: Data { Data(bytes) }

    public mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    public mutating func writeTag(fieldNumber: Int, wireType: WireType) {
        writeVarint(UInt64(fieldNumber) << 3 | UInt64(wireType.rawValue))
    }

    public mutating func writeFixed32(_ value: UInt32) {
        for i in 0..<4 {
            bytes.append(UInt8((value >> (8 * UInt32(i))) & 0xFF))
        }
    }

    public mutating func writeFixed64(_ value: UInt64) {
        for i in 0..<8 {
            bytes.append(UInt8((value >> (8 * UInt64(i))) & 0xFF))
        }
    }

    public mutating func writeLengthDelimited(_ payload: [UInt8]) {
        writeVarint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    public mutating func writeLengthDelimited(_ payload: Data) {
        writeLengthDelimited([UInt8](payload))
    }

    public mutating func writeRaw<C: Collection>(_ raw: C) where C.Element == UInt8 {
        bytes.append(contentsOf: raw)
    }
}
