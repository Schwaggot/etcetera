import Foundation
import SwiftProtobuf

// The schema registry: fully qualified type names to descriptors, built once
// from the FileDescriptorSet protoc emits. SwiftProtobuf reads the set; the
// name resolution and graph building here are ours. See SPEC 5.3.

public enum SchemaError: Error, Sendable, Equatable {
    case invalidDescriptorSet(String)
    /// A field names a type that no file in the set defines.
    case unresolvedType(field: String, typeName: String)
    case unknownMessage(String)
}

extension SchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDescriptorSet(let detail):
            return String(localized: "The compiled schema could not be read: \(detail)", bundle: .module)
        case .unresolvedType(let field, let typeName):
            return String(localized: "Field \(field) refers to \(typeName), which is not in the schema.", bundle: .module)
        case .unknownMessage(let name):
            return String(localized: "The message type \(name) is not in the schema.", bundle: .module)
        }
    }
}

public enum FieldType: Sendable, Hashable {
    case double, float, int64, uint64, int32, fixed64, fixed32, bool, string
    case group, message, bytes, uint32, enumeration, sfixed32, sfixed64, sint32, sint64

    /// The wire type a singular value of this type uses.
    public var wireType: UInt8 {
        switch self {
        case .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool, .enumeration:
            return 0
        case .fixed64, .sfixed64, .double:
            return 1
        case .string, .bytes, .message:
            return 2
        case .group:
            return 3
        case .fixed32, .sfixed32, .float:
            return 5
        }
    }

    /// Scalars that may use packed encoding when repeated.
    public var isPackable: Bool {
        switch self {
        case .string, .bytes, .message, .group: return false
        default: return true
        }
    }

    /// 64-bit integers, which the JSON mapping renders as strings.
    public var is64Bit: Bool {
        switch self {
        case .int64, .uint64, .sint64, .fixed64, .sfixed64: return true
        default: return false
        }
    }
}

public struct FieldDescriptor: Sendable, Hashable {
    public let name: String
    public let jsonName: String
    public let number: Int
    public let type: FieldType
    public let isRepeated: Bool
    public let isRequired: Bool
    /// Fully qualified message or enum name without the leading dot.
    public let typeName: String?
    /// Index into the message's oneof names; nil for synthetic proto3
    /// optional oneofs.
    public let oneofIndex: Int?
    /// Whether an unset field is distinguishable from its default.
    public let hasExplicitPresence: Bool
    public let isPacked: Bool
    /// A repeated field of a map entry message.
    public let isMap: Bool
}

public struct MessageDescriptor: Sendable, Hashable {
    /// Shared, so each decoded message holds one reference instead of a copy.
    private final class Storage: Sendable {
        let fullName: String
        let fields: [FieldDescriptor]
        let fieldsByNumber: [FieldDescriptor]
        let oneofNames: [String]
        let isMapEntry: Bool
        let indexByNumber: [Int: Int]
        let indexByJSONKey: [String: Int]

        init(fullName: String, fields: [FieldDescriptor], oneofNames: [String], isMapEntry: Bool) {
            self.fullName = fullName
            self.fields = fields
            self.fieldsByNumber = fields.sorted { $0.number < $1.number }
            self.oneofNames = oneofNames
            self.isMapEntry = isMapEntry
            var byNumber: [Int: Int] = [:]
            var byKey: [String: Int] = [:]
            for (index, field) in fields.enumerated() {
                byNumber[field.number] = index
                byKey[field.name] = index
                byKey[field.jsonName] = byKey[field.jsonName] ?? index
            }
            self.indexByNumber = byNumber
            self.indexByJSONKey = byKey
        }
    }

    private let storage: Storage

    public var fullName: String { storage.fullName }
    /// Declaration order, which the JSON projection follows.
    public var fields: [FieldDescriptor] { storage.fields }
    /// Ascending field number, which the encoder follows.
    public var fieldsByNumber: [FieldDescriptor] { storage.fieldsByNumber }
    /// Names of real oneofs; synthetic proto3 optional oneofs are omitted.
    public var oneofNames: [String] { storage.oneofNames }
    public var isMapEntry: Bool { storage.isMapEntry }

    init(fullName: String, fields: [FieldDescriptor], oneofNames: [String], isMapEntry: Bool) {
        storage = Storage(fullName: fullName, fields: fields, oneofNames: oneofNames, isMapEntry: isMapEntry)
    }

    public func field(number: Int) -> FieldDescriptor? {
        storage.indexByNumber[number].map { storage.fields[$0] }
    }

    /// Looks up a field by its JSON name or its original proto name.
    public func field(named name: String) -> FieldDescriptor? {
        storage.indexByJSONKey[name].map { storage.fields[$0] }
    }

    public static func == (lhs: MessageDescriptor, rhs: MessageDescriptor) -> Bool {
        lhs.fullName == rhs.fullName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fullName)
    }
}

public struct EnumDescriptor: Sendable, Hashable {
    public let fullName: String
    /// Declaration order; aliases included.
    public let values: [(name: String, number: Int32)]
    /// proto2 enums are closed; proto3 enums are open.
    public let isClosed: Bool
    private let nameByNumber: [Int32: String]
    private let numberByName: [String: Int32]

    init(fullName: String, values: [(name: String, number: Int32)], isClosed: Bool) {
        self.fullName = fullName
        self.values = values
        self.isClosed = isClosed
        var byNumber: [Int32: String] = [:]
        var byName: [String: Int32] = [:]
        for value in values {
            // The first name declared for a number is canonical.
            if byNumber[value.number] == nil { byNumber[value.number] = value.name }
            byName[value.name] = value.number
        }
        self.nameByNumber = byNumber
        self.numberByName = byName
    }

    public func name(for number: Int32) -> String? { nameByNumber[number] }
    public func number(for name: String) -> Int32? { numberByName[name] }

    public static func == (lhs: EnumDescriptor, rhs: EnumDescriptor) -> Bool {
        lhs.fullName == rhs.fullName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fullName)
    }
}

/// Every message and enum in a compiled schema, keyed by fully qualified
/// name. Built once, immutable afterward.
public struct SchemaRegistry: Sendable {
    public let messages: [String: MessageDescriptor]
    public let enums: [String: EnumDescriptor]

    /// Every message name, sorted, for completion in the mapping editor.
    public var allMessageNames: [String] { messages.keys.sorted() }

    public func message(named name: String) -> MessageDescriptor? {
        messages[Self.stripDot(name)]
    }

    public func enumeration(named name: String) -> EnumDescriptor? {
        enums[Self.stripDot(name)]
    }

    /// Reads the output of `protoc --descriptor_set_out`.
    public init(descriptorSet data: Data) throws {
        let set: Google_Protobuf_FileDescriptorSet
        do {
            set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
        } catch {
            throw SchemaError.invalidDescriptorSet(String(describing: error))
        }
        try self.init(fileDescriptorSet: set)
    }

    public init(fileDescriptorSet set: Google_Protobuf_FileDescriptorSet) throws {
        var builder = Builder()
        for file in set.file {
            builder.collect(file: file)
        }
        let (messages, enums) = try builder.build()
        self.messages = messages
        self.enums = enums
    }

    static func stripDot(_ name: String) -> String {
        name.hasPrefix(".") ? String(name.dropFirst()) : name
    }
}

// MARK: - Building

private enum Syntax {
    case proto2, proto3, editions
}

private struct Builder {
    struct PendingMessage {
        var fullName: String
        var proto: Google_Protobuf_DescriptorProto
        var syntax: Syntax
        /// Features from the file and enclosing messages, innermost last.
        var features: [Google_Protobuf_FeatureSet]
    }

    var pending: [PendingMessage] = []
    var enums: [String: EnumDescriptor] = [:]

    mutating func collect(file: Google_Protobuf_FileDescriptorProto) {
        let syntax: Syntax
        switch file.syntax {
        case "proto3": syntax = .proto3
        case "editions": syntax = .editions
        default: syntax = .proto2
        }
        let scope = file.package.isEmpty ? "" : file.package + "."
        let features = file.options.hasFeatures ? [file.options.features] : []
        for enumProto in file.enumType {
            collect(enumProto: enumProto, scope: scope, syntax: syntax, features: features)
        }
        for message in file.messageType {
            collect(message: message, scope: scope, syntax: syntax, features: features)
        }
    }

    mutating func collect(
        message: Google_Protobuf_DescriptorProto, scope: String, syntax: Syntax,
        features: [Google_Protobuf_FeatureSet]
    ) {
        let fullName = scope + message.name
        var features = features
        if message.options.hasFeatures { features.append(message.options.features) }
        pending.append(PendingMessage(fullName: fullName, proto: message, syntax: syntax, features: features))
        for nested in message.nestedType {
            collect(message: nested, scope: fullName + ".", syntax: syntax, features: features)
        }
        for enumProto in message.enumType {
            collect(enumProto: enumProto, scope: fullName + ".", syntax: syntax, features: features)
        }
    }

    mutating func collect(
        enumProto: Google_Protobuf_EnumDescriptorProto, scope: String, syntax: Syntax,
        features: [Google_Protobuf_FeatureSet]
    ) {
        let fullName = scope + enumProto.name
        let isClosed: Bool
        switch syntax {
        case .proto2: isClosed = true
        case .proto3: isClosed = false
        case .editions:
            var all = features
            if enumProto.options.hasFeatures { all.append(enumProto.options.features) }
            isClosed = all.last(where: { $0.hasEnumType })?.enumType == .closed
        }
        enums[fullName] = EnumDescriptor(
            fullName: fullName,
            values: enumProto.value.map { ($0.name, $0.number) },
            isClosed: isClosed)
    }

    func build() throws -> ([String: MessageDescriptor], [String: EnumDescriptor]) {
        let mapEntries = Set(pending.filter { $0.proto.options.mapEntry }.map(\.fullName))
        let messageNames = Set(pending.map(\.fullName))
        var messages: [String: MessageDescriptor] = [:]
        for message in pending {
            let fields = try message.proto.field.map { field in
                try buildField(field, in: message, mapEntries: mapEntries, messageNames: messageNames)
            }
            // Synthetic oneofs exist only to carry proto3 optional presence.
            var syntheticOneofs = Set<Int>()
            for field in message.proto.field where field.proto3Optional && field.hasOneofIndex {
                syntheticOneofs.insert(Int(field.oneofIndex))
            }
            let oneofNames = message.proto.oneofDecl.enumerated()
                .filter { !syntheticOneofs.contains($0.offset) }
                .map(\.element.name)
            messages[message.fullName] = MessageDescriptor(
                fullName: message.fullName, fields: fields, oneofNames: oneofNames,
                isMapEntry: message.proto.options.mapEntry)
        }
        return (messages, enums)
    }

    func buildField(
        _ field: Google_Protobuf_FieldDescriptorProto, in message: PendingMessage,
        mapEntries: Set<String>, messageNames: Set<String>
    ) throws -> FieldDescriptor {
        let qualifiedName = message.fullName + "." + field.name
        // protoc never emits these, but a damaged schema.pb must not trap later.
        guard (1...536_870_911).contains(field.number) else {
            throw SchemaError.invalidDescriptorSet(
                String(localized: "\(qualifiedName) has number \(Int(field.number)), outside 1 to 536870911", bundle: .module))
        }
        if field.hasOneofIndex, !message.proto.oneofDecl.indices.contains(Int(field.oneofIndex)) {
            throw SchemaError.invalidDescriptorSet(
                String(localized: "\(qualifiedName) names oneof \(Int(field.oneofIndex)), which is not declared", bundle: .module))
        }
        let type = Self.fieldType(field.type)
        var typeName: String?
        if type == .message || type == .enumeration || type == .group {
            let name = SchemaRegistry.stripDot(field.typeName)
            let known = type == .enumeration ? enums[name] != nil : messageNames.contains(name)
            guard known else {
                throw SchemaError.unresolvedType(field: qualifiedName, typeName: field.typeName)
            }
            typeName = name
        }
        let isRepeated = field.label == .repeated

        var features = message.features
        if field.options.hasFeatures { features.append(field.options.features) }

        let isPacked: Bool
        if !isRepeated || !type.isPackable {
            isPacked = false
        } else {
            switch message.syntax {
            case .proto2: isPacked = field.options.hasPacked && field.options.packed
            case .proto3: isPacked = !field.options.hasPacked || field.options.packed
            case .editions:
                isPacked = features.last(where: { $0.hasRepeatedFieldEncoding })?.repeatedFieldEncoding != .expanded
            }
        }

        let isRealOneof = field.hasOneofIndex && !field.proto3Optional
        let hasExplicitPresence: Bool
        if isRepeated {
            hasExplicitPresence = false
        } else if type == .message || type == .group || isRealOneof || field.proto3Optional {
            hasExplicitPresence = true
        } else {
            switch message.syntax {
            case .proto2: hasExplicitPresence = true
            case .proto3: hasExplicitPresence = false
            case .editions:
                hasExplicitPresence =
                    features.last(where: { $0.hasFieldPresence })?.fieldPresence != .implicit
            }
        }

        var oneofIndex: Int?
        if isRealOneof {
            // Index among real oneofs, skipping synthetic ones declared before.
            let synthetic = Set(message.proto.field.filter { $0.proto3Optional && $0.hasOneofIndex }.map { Int($0.oneofIndex) })
            let raw = Int(field.oneofIndex)
            oneofIndex = raw - synthetic.filter { $0 < raw }.count
        }

        return FieldDescriptor(
            name: field.name,
            jsonName: field.hasJsonName ? field.jsonName : Self.lowerCamel(field.name),
            number: Int(field.number),
            type: type,
            isRepeated: isRepeated,
            isRequired: field.label == .required,
            typeName: typeName,
            oneofIndex: oneofIndex,
            hasExplicitPresence: hasExplicitPresence,
            isPacked: isPacked,
            isMap: isRepeated && type == .message && typeName.map(mapEntries.contains) == true)
    }

    static func fieldType(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> FieldType {
        switch type {
        case .double: return .double
        case .float: return .float
        case .int64: return .int64
        case .uint64: return .uint64
        case .int32: return .int32
        case .fixed64: return .fixed64
        case .fixed32: return .fixed32
        case .bool: return .bool
        case .string: return .string
        case .group: return .group
        case .message: return .message
        case .bytes: return .bytes
        case .uint32: return .uint32
        case .enum: return .enumeration
        case .sfixed32: return .sfixed32
        case .sfixed64: return .sfixed64
        case .sint32: return .sint32
        case .sint64: return .sint64
        }
    }

    /// protoc's json_name rule: drop underscores, capitalize the next letter.
    static func lowerCamel(_ name: String) -> String {
        var result = ""
        var capitalizeNext = false
        for character in name {
            if character == "_" {
                capitalizeNext = true
            } else if capitalizeNext {
                result += character.uppercased()
                capitalizeNext = false
            } else {
                result.append(character)
            }
        }
        return result
    }
}
