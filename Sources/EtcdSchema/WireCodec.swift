import Foundation

/// A decode failure with the field path where it happened. Decoding never
/// yields a partially decoded message. See SPEC 5.5.
public struct MessageDecodingError: Error, Sendable, Equatable {
    public let messageName: String
    /// Dotted field path from the root, such as "items[2].name".
    public let path: String
    public let reason: WireDecodingError
}

extension MessageDecodingError: LocalizedError {
    public var errorDescription: String? {
        if path.isEmpty {
            return String(localized: "The value is not a valid \(messageName): \(reason.description)", bundle: .module)
        }
        return String(localized: "The value is not a valid \(messageName) at \(path): \(reason.description)", bundle: .module)
    }
}

/// Decodes and encodes the binary wire format against runtime descriptors.
public struct WireCodec: Sendable {
    public let registry: SchemaRegistry
    /// Nesting limit for messages and groups; deeper input throws.
    public let maxDepth: Int

    public init(registry: SchemaRegistry, maxDepth: Int = 100) {
        self.registry = registry
        self.maxDepth = maxDepth
    }

    // MARK: Decoding

    public func decode(_ data: Data, as messageName: String) throws -> DynamicMessage {
        guard let descriptor = registry.message(named: messageName) else {
            throw SchemaError.unknownMessage(messageName)
        }
        return try decode(data, as: descriptor)
    }

    public func decode(_ data: Data, as descriptor: MessageDescriptor) throws -> DynamicMessage {
        try decode(data, as: descriptor, depth: 0)
    }

    /// Decodes a payload nested `depth` levels down, such as inside an Any,
    /// so the nesting limit counts from the outermost message.
    func decode(_ data: Data, as descriptor: MessageDescriptor, depth: Int) throws -> DynamicMessage {
        var reader = WireReader(data)
        return try decodeMessage(descriptor, reader: &reader, depth: depth, path: "")
    }

    private func decodeMessage(
        _ descriptor: MessageDescriptor, reader: inout WireReader, depth: Int, path: String
    ) throws -> DynamicMessage {
        var message = DynamicMessage(descriptor: descriptor)
        var fieldPath = path
        do {
            guard depth < maxDepth else { throw WireDecodingError.tooDeep }
            while !reader.isAtEnd {
                let start = reader.index
                guard let (number, wireType) = try reader.readRawTag() else { break }
                if wireType == 4 { throw WireDecodingError.unexpectedEndGroup }

                let field = descriptor.field(number: number)
                fieldPath = Self.join(path, field?.name ?? String(number))
                guard let field, field.type != .group,
                    wireType == field.type.wireType
                        || (wireType == 2 && field.isRepeated && field.type.isPackable)
                else {
                    // Unknown, a group, or a wire type mismatch: keep verbatim.
                    if wireType == 3 {
                        try reader.skipGroup(fieldNumber: number, depthLimit: maxDepth - depth)
                    } else {
                        try reader.skip(wireType: WireType(rawValue: wireType)!)
                    }
                    message.unknownFields.append(
                        UnknownField(fieldNumber: number, raw: Data(reader.raw(from: start, to: reader.index))))
                    continue
                }

                if wireType == 2 && field.type.isPackable {
                    // Packed; the unpacked form is accepted by the branch below.
                    var packed = try reader.readSubReader()
                    var elements: [DynamicValue] = []
                    elements.reserveCapacity(packed.packedElementCount(wireType: field.type.wireType))
                    while !packed.isAtEnd {
                        elements.append(try Self.readScalar(field.type, from: &packed))
                    }
                    message.append(contentsOf: elements, toField: number)
                    continue
                }

                let value: DynamicValue
                switch field.type {
                case .string:
                    let slice = try reader.readLengthDelimited()
                    guard let string = String(validating: slice, as: UTF8.self) else {
                        throw WireDecodingError.malformedUTF8
                    }
                    value = .string(string)
                case .bytes:
                    value = .bytes(Data(try reader.readLengthDelimited()))
                case .message:
                    guard let nested = registry.message(named: field.typeName ?? "") else {
                        throw WireDecodingError.invalidTag
                    }
                    var sub = try reader.readSubReader()
                    let elementPath = field.isRepeated
                        ? "\(fieldPath)[\(message.value(forField: number)?.values.count ?? 0)]"
                        : fieldPath
                    value = .message(try decodeMessage(nested, reader: &sub, depth: depth + 1, path: elementPath))
                default:
                    value = try Self.readScalar(field.type, from: &reader)
                }

                if field.isRepeated {
                    message.append(value, toField: number)
                } else if case .message(let incoming) = value,
                    case .single(.message(var existing))? = message.value(forField: number)
                {
                    // A repeated singular message merges, per the wire format. Taken out first so
                    // its arrays stay uniquely referenced and each merge appends in place.
                    message.set(nil, forField: number)
                    Self.merge(incoming, into: &existing)
                    message.set(.single(.message(existing)), forField: number)
                } else {
                    message.set(.single(value), forField: number)
                }
            }
        } catch let error as WireDecodingError {
            throw MessageDecodingError(messageName: descriptor.fullName, path: fieldPath, reason: error)
        }
        return message
    }

    static func readScalar(_ type: FieldType, from reader: inout WireReader) throws -> DynamicValue {
        switch type {
        case .int32: return .int32(Int32(truncatingIfNeeded: try reader.readVarint()))
        case .int64: return .int64(Int64(bitPattern: try reader.readVarint()))
        case .uint32: return .uint32(UInt32(truncatingIfNeeded: try reader.readVarint()))
        case .uint64: return .uint64(try reader.readVarint())
        case .sint32: return .int32(Int32(truncatingIfNeeded: zigzagDecode(try reader.readVarint())))
        case .sint64: return .int64(zigzagDecode(try reader.readVarint()))
        case .bool: return .bool(try reader.readVarint() != 0)
        case .enumeration: return .enumeration(Int32(truncatingIfNeeded: try reader.readVarint()))
        case .fixed32: return .uint32(try reader.readFixed32())
        case .sfixed32: return .int32(Int32(bitPattern: try reader.readFixed32()))
        case .float: return .float(Float(bitPattern: try reader.readFixed32()))
        case .fixed64: return .uint64(try reader.readFixed64())
        case .sfixed64: return .int64(Int64(bitPattern: try reader.readFixed64()))
        case .double: return .double(Double(bitPattern: try reader.readFixed64()))
        case .string, .bytes, .message, .group:
            throw WireDecodingError.invalidWireType(type.wireType)
        }
    }

    static func merge(_ incoming: DynamicMessage, into result: inout DynamicMessage) {
        for field in incoming.descriptor.fields {
            guard let value = incoming.value(forField: field.number) else { continue }
            if case .repeated(let values) = value {
                result.append(contentsOf: values, toField: field.number)
            } else if case .single(.message(let inner)) = value,
                case .single(.message(var current))? = result.value(forField: field.number)
            {
                result.set(nil, forField: field.number)
                merge(inner, into: &current)
                result.set(.single(.message(current)), forField: field.number)
            } else {
                result.set(value, forField: field.number)
            }
        }
        result.unknownFields += incoming.unknownFields
    }

    static func join(_ path: String, _ component: String) -> String {
        path.isEmpty ? component : "\(path).\(component)"
    }

    // MARK: Encoding

    /// Known fields ascending by field number, with unknown fields merged
    /// in by number, which is what mainstream implementations emit.
    public func encode(_ message: DynamicMessage) -> Data {
        Data(encodeMessage(message))
    }

    private func encodeMessage(_ message: DynamicMessage) -> [UInt8] {
        var writer = WireWriter()
        let unknowns = message.unknownFields.enumerated()
            .sorted { ($0.element.fieldNumber, $0.offset) < ($1.element.fieldNumber, $1.offset) }
            .map(\.element)
        var nextUnknown = 0
        for field in message.descriptor.fieldsByNumber {
            guard let value = message.value(forField: field.number) else { continue }
            while nextUnknown < unknowns.count, unknowns[nextUnknown].fieldNumber < field.number {
                writer.writeRaw(unknowns[nextUnknown].raw)
                nextUnknown += 1
            }
            switch value {
            case .single(let element):
                writeTagged(element, field: field, into: &writer)
            case .repeated(let elements):
                guard !elements.isEmpty else { continue }
                if field.isPacked {
                    var payload = WireWriter()
                    for element in elements { writeScalar(element, type: field.type, into: &payload) }
                    writer.writeTag(fieldNumber: field.number, wireType: .lengthDelimited)
                    writer.writeLengthDelimited(payload.bytes)
                } else {
                    for element in elements { writeTagged(element, field: field, into: &writer) }
                }
            }
        }
        while nextUnknown < unknowns.count {
            writer.writeRaw(unknowns[nextUnknown].raw)
            nextUnknown += 1
        }
        return writer.bytes
    }

    private func writeTagged(_ value: DynamicValue, field: FieldDescriptor, into writer: inout WireWriter) {
        switch field.type {
        case .string, .bytes, .message:
            writer.writeTag(fieldNumber: field.number, wireType: .lengthDelimited)
            switch value {
            case .string(let string): writer.writeLengthDelimited(Array(string.utf8))
            case .bytes(let bytes): writer.writeLengthDelimited(bytes)
            case .message(let message): writer.writeLengthDelimited(encodeMessage(message))
            default: writer.writeLengthDelimited([])
            }
        default:
            // Groups have no wire type here; decoded groups live in unknownFields.
            guard let wireType = WireType(rawValue: field.type.wireType) else { return }
            writer.writeTag(fieldNumber: field.number, wireType: wireType)
            writeScalar(value, type: field.type, into: &writer)
        }
    }

    private func writeScalar(_ value: DynamicValue, type: FieldType, into writer: inout WireWriter) {
        switch type {
        case .int32, .int64, .uint32, .uint64, .bool, .enumeration:
            writer.writeVarint(Self.integerBits(value))
        case .sint32, .sint64:
            writer.writeVarint(zigzagEncode(Int64(bitPattern: Self.integerBits(value))))
        case .fixed32, .sfixed32:
            writer.writeFixed32(UInt32(truncatingIfNeeded: Self.integerBits(value)))
        case .float:
            if case .float(let float) = value { writer.writeFixed32(float.bitPattern) } else { writer.writeFixed32(0) }
        case .fixed64, .sfixed64:
            writer.writeFixed64(Self.integerBits(value))
        case .double:
            if case .double(let double) = value { writer.writeFixed64(double.bitPattern) } else { writer.writeFixed64(0) }
        case .string, .bytes, .message, .group:
            break
        }
    }

    /// Integers as the varint encoder sees them: signed values sign-extend
    /// to 64 bits, as protoc does for negative int32 and enum values.
    static func integerBits(_ value: DynamicValue) -> UInt64 {
        switch value {
        case .int32(let x): return UInt64(bitPattern: Int64(x))
        case .int64(let x): return UInt64(bitPattern: x)
        case .uint32(let x): return UInt64(x)
        case .uint64(let x): return x
        case .enumeration(let x): return UInt64(bitPattern: Int64(x))
        case .bool(let x): return x ? 1 : 0
        default: return 0
        }
    }
}
