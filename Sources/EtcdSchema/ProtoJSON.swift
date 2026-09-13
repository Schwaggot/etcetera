import Foundation

// The proto3 JSON mapping in both directions: DynamicMessage to JSON for
// viewing, and JSON back to DynamicMessage for editing. See SPEC 5.4 and 5.6.

/// A JSON value that does not fit the message, with the field path.
public struct ProtoJSONError: Error, Sendable, Equatable {
    /// Dotted path such as "inner.child.name" or "labels[\"app\"]".
    public let path: String
    public let reason: String
}

extension ProtoJSONError: LocalizedError {
    public var errorDescription: String? {
        path.isEmpty ? reason : "\(path): \(reason)"
    }
}

struct ProtoJSONMapper {
    let registry: SchemaRegistry
    let codec: WireCodec

    // MARK: - Projection

    /// `depth` counts message nesting so Any payloads, decoded afresh at
    /// each level, still hit the codec's nesting limit.
    func project(_ message: DynamicMessage, path: String = "", depth: Int = 0) throws -> JSONValue {
        if let special = try projectWellKnown(message, path: path, depth: depth) {
            return special
        }
        return try projectFields(message, path: path, depth: depth)
    }

    /// The generic object form, bypassing well-known type handling.
    private func projectFields(_ message: DynamicMessage, path: String, depth: Int) throws -> JSONValue {
        var members: [JSONMember] = []
        for field in message.descriptor.fields {
            guard let fieldValue = message.value(forField: field.number) else { continue }
            let fieldPath = WireCodec.join(path, field.jsonName)
            switch fieldValue {
            case .repeated(let elements) where field.isMap:
                let entryDescriptor = try messageDescriptor(field, path: fieldPath)
                var entries: [JSONMember] = []
                for element in elements {
                    guard case .message(let entry) = element,
                        let keyField = entryDescriptor.field(number: 1),
                        let valueField = entryDescriptor.field(number: 2)
                    else { continue }
                    let key = entry.value(forField: 1)?.values.first ?? Self.defaultValue(keyField.type)
                    let mapKey = Self.mapKeyString(key)
                    let valuePath = "\(fieldPath)[\"\(mapKey)\"]"
                    let value: JSONValue
                    if let stored = entry.value(forField: 2)?.values.first {
                        value = try projectValue(stored, field: valueField, path: valuePath, depth: depth + 1)
                    } else {
                        value = try projectDefault(valueField, path: valuePath, depth: depth + 1)
                    }
                    entries.append(JSONMember(mapKey, value))
                }
                members.append(JSONMember(field.jsonName, .object(entries)))
            case .repeated(let elements):
                members.append(JSONMember(field.jsonName, .array(try elements.enumerated().map {
                    try projectValue($0.element, field: field, path: "\(fieldPath)[\($0.offset)]", depth: depth + 1)
                })))
            case .single(let value):
                if !field.hasExplicitPresence && Self.isDefault(value) { continue }
                members.append(JSONMember(
                    field.jsonName, try projectValue(value, field: field, path: fieldPath, depth: depth + 1)))
            }
        }
        return .object(members)
    }

    private func projectDefault(_ field: FieldDescriptor, path: String, depth: Int) throws -> JSONValue {
        if field.type == .message {
            return try project(DynamicMessage(descriptor: messageDescriptor(field, path: path)), path: path, depth: depth)
        }
        return try projectValue(Self.defaultValue(field.type), field: field, path: path, depth: depth)
    }

    func projectValue(_ value: DynamicValue, field: FieldDescriptor, path: String, depth: Int) throws -> JSONValue {
        switch value {
        case .message(let message):
            return try project(message, path: path, depth: depth)
        case .enumeration(let number):
            if field.typeName == "google.protobuf.NullValue" { return .null }
            if let name = registry.enumeration(named: field.typeName ?? "")?.name(for: number) {
                return .string(name)
            }
            return .number(String(number))
        case .int32(let x): return .number(String(x))
        case .uint32(let x): return .number(String(x))
        case .int64(let x): return .string(String(x))
        case .uint64(let x): return .string(String(x))
        case .float(let x): return Self.floatingJSON(Double(x), text: Self.format(x))
        case .double(let x): return Self.floatingJSON(x, text: Self.format(x))
        case .bool(let x): return .bool(x)
        case .string(let x): return .string(x)
        case .bytes(let x): return .string(x.base64EncodedString())
        }
    }

    // MARK: - Parsing

    func parse(_ json: JSONValue, as descriptor: MessageDescriptor, path: String = "") throws -> DynamicMessage {
        if let special = try parseWellKnown(json, as: descriptor, path: path) {
            return special
        }
        guard case .object(let members) = json else {
            throw ProtoJSONError(path: path, reason: String(localized: "expected an object for \(descriptor.fullName)", bundle: .module))
        }
        var message = DynamicMessage(descriptor: descriptor)
        var seen = Set<Int>()
        var oneofOwners: [Int: String] = [:]
        for member in members {
            let memberPath = WireCodec.join(path, member.key)
            guard let field = descriptor.field(named: member.key) else {
                throw ProtoJSONError(path: memberPath, reason: String(localized: "unknown field in \(descriptor.fullName)", bundle: .module))
            }
            guard seen.insert(field.number).inserted else {
                throw ProtoJSONError(path: memberPath, reason: String(localized: "field is set more than once", bundle: .module))
            }
            if case .null = member.value, !Self.acceptsNull(field) { continue }
            if let oneof = field.oneofIndex {
                if let owner = oneofOwners[oneof] {
                    // A damaged schema can point a field at a oneof that is not listed.
                    let name = descriptor.oneofNames.indices.contains(oneof) ? descriptor.oneofNames[oneof] : String(oneof)
                    throw ProtoJSONError(
                        path: memberPath,
                        reason: String(
                            localized: "only one of oneof \(name) may be set, \(owner) already is",
                            bundle: .module))
                }
                oneofOwners[oneof] = member.key
            }

            if field.isMap {
                guard case .object(let entries) = member.value else {
                    throw ProtoJSONError(path: memberPath, reason: String(localized: "expected an object for a map", bundle: .module))
                }
                let entryDescriptor = try messageDescriptor(field, path: memberPath)
                guard let keyField = entryDescriptor.field(number: 1),
                    let valueField = entryDescriptor.field(number: 2)
                else { continue }
                for entry in entries {
                    let entryPath = "\(memberPath)[\"\(entry.key)\"]"
                    var entryMessage = DynamicMessage(descriptor: entryDescriptor)
                    // Both key and value are always written, as protoc does.
                    entryMessage.set(.single(try parseMapKey(entry.key, type: keyField.type, path: entryPath)), forField: 1)
                    entryMessage.set(.single(try parseValue(entry.value, field: valueField, path: entryPath)), forField: 2)
                    message.append(.message(entryMessage), toField: field.number)
                }
            } else if field.isRepeated {
                guard case .array(let elements) = member.value else {
                    throw ProtoJSONError(path: memberPath, reason: String(localized: "expected an array", bundle: .module))
                }
                for (offset, element) in elements.enumerated() {
                    message.append(
                        try parseValue(element, field: field, path: "\(memberPath)[\(offset)]"),
                        toField: field.number)
                }
            } else {
                let value = try parseValue(member.value, field: field, path: memberPath)
                if !field.hasExplicitPresence && Self.isDefault(value) { continue }
                message.set(.single(value), forField: field.number)
            }
        }
        return message
    }

    func parseValue(_ json: JSONValue, field: FieldDescriptor, path: String) throws -> DynamicValue {
        switch field.type {
        case .message:
            return .message(try parse(json, as: messageDescriptor(field, path: path), path: path))
        case .group:
            throw ProtoJSONError(path: path, reason: String(localized: "group fields are kept as raw bytes and cannot be edited", bundle: .module))
        case .enumeration:
            if field.typeName == "google.protobuf.NullValue", case .null = json { return .enumeration(0) }
            switch json {
            case .string(let name):
                guard let number = registry.enumeration(named: field.typeName ?? "")?.number(for: name) else {
                    throw ProtoJSONError(path: path, reason: enumValueReason(name, field.typeName))
                }
                return .enumeration(number)
            default:
                return .enumeration(Int32(try Self.parseInteger(json, min: Int64(Int32.min), max: Int64(Int32.max), path: path)))
            }
        case .int32, .sint32, .sfixed32:
            return .int32(Int32(try Self.parseInteger(json, min: Int64(Int32.min), max: Int64(Int32.max), path: path)))
        case .uint32, .fixed32:
            return .uint32(UInt32(try Self.parseUnsigned(json, max: UInt64(UInt32.max), path: path)))
        case .int64, .sint64, .sfixed64:
            return .int64(try Self.parseInteger(json, min: .min, max: .max, path: path))
        case .uint64, .fixed64:
            return .uint64(try Self.parseUnsigned(json, max: .max, path: path))
        case .float:
            let double = try Self.parseFloating(json, path: path, asFloat: true)
            return .float(Float(double.text ?? "") ?? Float(double.value))
        case .double:
            let double = try Self.parseFloating(json, path: path, asFloat: false)
            return .double(double.value)
        case .bool:
            guard case .bool(let bool) = json else { throw ProtoJSONError(path: path, reason: String(localized: "expected true or false", bundle: .module)) }
            return .bool(bool)
        case .string:
            guard case .string(let string) = json else { throw ProtoJSONError(path: path, reason: String(localized: "expected a string", bundle: .module)) }
            return .string(string)
        case .bytes:
            guard case .string(let string) = json, let data = Self.decodeBase64(string) else {
                throw ProtoJSONError(path: path, reason: String(localized: "expected a base64 string", bundle: .module))
            }
            return .bytes(data)
        }
    }

    private func parseMapKey(_ key: String, type: FieldType, path: String) throws -> DynamicValue {
        switch type {
        case .string: return .string(key)
        case .bool:
            switch key {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw ProtoJSONError(path: path, reason: String(localized: "map key must be true or false", bundle: .module))
            }
        default:
            let field = FieldDescriptor(
                name: "key", jsonName: "key", number: 1, type: type, isRepeated: false, isRequired: false,
                typeName: nil, oneofIndex: nil, hasExplicitPresence: false, isPacked: false, isMap: false)
            return try parseValue(.string(key), field: field, path: path)
        }
    }

    // MARK: - Well-known types

    static let wrapperTypes: Set<String> = [
        "google.protobuf.DoubleValue", "google.protobuf.FloatValue", "google.protobuf.Int64Value",
        "google.protobuf.UInt64Value", "google.protobuf.Int32Value", "google.protobuf.UInt32Value",
        "google.protobuf.BoolValue", "google.protobuf.StringValue", "google.protobuf.BytesValue",
    ]

    /// Types with a custom JSON form; inside Any they sit under "value".
    static func hasCustomJSON(_ name: String) -> Bool {
        wrapperTypes.contains(name) || [
            "google.protobuf.Timestamp", "google.protobuf.Duration", "google.protobuf.FieldMask",
            "google.protobuf.Struct", "google.protobuf.Value", "google.protobuf.ListValue",
            "google.protobuf.Any",
        ].contains(name)
    }

    private func projectWellKnown(_ message: DynamicMessage, path: String, depth: Int) throws -> JSONValue? {
        let name = message.descriptor.fullName
        func int(_ number: Int) -> Int64 {
            switch message.value(forField: number)?.values.first {
            case .int64(let x)?: return x
            case .int32(let x)?: return Int64(x)
            default: return 0
            }
        }
        switch name {
        case "google.protobuf.Timestamp":
            return .string(try WellKnownFormats.formatTimestamp(seconds: int(1), nanos: int(2), path: path))
        case "google.protobuf.Duration":
            return .string(try WellKnownFormats.formatDuration(seconds: int(1), nanos: int(2), path: path))
        case "google.protobuf.FieldMask":
            let paths = (message.value(forField: 1)?.values ?? []).compactMap { value -> String? in
                if case .string(let string) = value { return string }
                return nil
            }
            return .string(try paths.map { try WellKnownFormats.camelPath($0, path: path) }.joined(separator: ","))
        case "google.protobuf.Struct":
            guard let generic = try projectGenericMap(message, path: path, depth: depth) else { return .object([]) }
            return generic
        case "google.protobuf.ListValue":
            guard let fieldDescriptor = message.descriptor.field(number: 1) else {
                throw ProtoJSONError(path: path, reason: String(localized: "google.protobuf.ListValue in this schema has no field 1", bundle: .module))
            }
            return .array(try (message.value(forField: 1)?.values ?? []).enumerated().map {
                try projectValue($0.element, field: fieldDescriptor, path: "\(path)[\($0.offset)]", depth: depth + 1)
            })
        case "google.protobuf.Value":
            for field in message.descriptor.fieldsByNumber {
                guard let value = message.value(forField: field.number)?.values.first else { continue }
                if field.number == 2, case .double(let number) = value, !number.isFinite {
                    throw ProtoJSONError(path: path, reason: String(localized: "a Value number cannot be NaN or infinite", bundle: .module))
                }
                return try projectValue(value, field: field, path: path, depth: depth + 1)
            }
            return .null
        case "google.protobuf.Any":
            return try projectAny(message, path: path, depth: depth)
        default:
            if Self.wrapperTypes.contains(name), let field = message.descriptor.field(number: 1) {
                let value = message.value(forField: 1)?.values.first ?? Self.defaultValue(field.type)
                return try projectValue(value, field: field, path: path, depth: depth + 1)
            }
            return nil
        }
    }

    private func projectGenericMap(_ message: DynamicMessage, path: String, depth: Int) throws -> JSONValue? {
        guard let field = message.descriptor.field(number: 1) else { return nil }
        let projected = try projectFields(message, path: path, depth: depth)
        if case .object(let members) = projected, let map = members.first(where: { $0.key == field.jsonName }) {
            return map.value
        }
        return .object([])
    }

    private func projectAny(_ message: DynamicMessage, path: String, depth: Int) throws -> JSONValue {
        var typeURL = ""
        if case .string(let url)? = message.value(forField: 1)?.values.first { typeURL = url }
        var payload = Data()
        if case .bytes(let bytes)? = message.value(forField: 2)?.values.first { payload = bytes }
        if typeURL.isEmpty && payload.isEmpty { return .object([]) }

        guard let inner = registry.message(named: Self.typeName(inAnyURL: typeURL)) else {
            // Unresolvable: raw bytes with the type URL, never a guess.
            return .object([JSONMember("@type", .string(typeURL)), JSONMember("value", .string(payload.base64EncodedString()))])
        }
        let decoded = try codec.decode(payload, as: inner, depth: depth + 1)
        let projected = try project(decoded, path: WireCodec.join(path, "value"), depth: depth + 1)
        if Self.hasCustomJSON(inner.fullName) {
            return .object([JSONMember("@type", .string(typeURL)), JSONMember("value", projected)])
        }
        guard case .object(let members) = projected else { return projected }
        return .object([JSONMember("@type", .string(typeURL))] + members)
    }

    private func parseWellKnown(_ json: JSONValue, as descriptor: MessageDescriptor, path: String) throws -> DynamicMessage? {
        var message = DynamicMessage(descriptor: descriptor)
        func setNonZero(_ number: Int, _ value: DynamicValue) {
            if !Self.isDefault(value) { message.set(.single(value), forField: number) }
        }
        func string() throws -> String {
            guard case .string(let string) = json else {
                throw ProtoJSONError(path: path, reason: String(localized: "expected a string for \(descriptor.fullName)", bundle: .module))
            }
            return string
        }
        switch descriptor.fullName {
        case "google.protobuf.Timestamp":
            let (seconds, nanos) = try WellKnownFormats.parseTimestamp(try string(), path: path)
            setNonZero(1, .int64(seconds))
            setNonZero(2, .int32(nanos))
        case "google.protobuf.Duration":
            let (seconds, nanos) = try WellKnownFormats.parseDuration(try string(), path: path)
            setNonZero(1, .int64(seconds))
            setNonZero(2, .int32(nanos))
        case "google.protobuf.FieldMask":
            for part in try string().split(separator: ",", omittingEmptySubsequences: true) {
                message.append(.string(try WellKnownFormats.snakePath(String(part), path: path)), toField: 1)
            }
        case "google.protobuf.Struct":
            guard case .object = json else { throw ProtoJSONError(path: path, reason: String(localized: "expected an object for Struct", bundle: .module)) }
            let fieldName = descriptor.field(number: 1)?.jsonName ?? "fields"
            return try parse(.object([JSONMember(fieldName, json)]), asGeneric: descriptor, path: path)
        case "google.protobuf.ListValue":
            guard case .array(let elements) = json, let field = descriptor.field(number: 1) else {
                throw ProtoJSONError(path: path, reason: String(localized: "expected an array for ListValue", bundle: .module))
            }
            for (offset, element) in elements.enumerated() {
                message.append(try parseValue(element, field: field, path: "\(path)[\(offset)]"), toField: 1)
            }
        case "google.protobuf.Value":
            let (number, value): (Int, JSONValue)
            switch json {
            case .null: (number, value) = (1, .null)
            case .number: (number, value) = (2, json)
            case .string: (number, value) = (3, json)
            case .bool: (number, value) = (4, json)
            case .object: (number, value) = (5, json)
            case .array: (number, value) = (6, json)
            }
            guard let field = descriptor.field(number: number) else { return message }
            // The kind is a oneof, so even a default value is present.
            message.set(.single(try parseValue(value, field: field, path: path)), forField: number)
        case "google.protobuf.Any":
            return try parseAny(json, as: descriptor, path: path)
        default:
            guard Self.wrapperTypes.contains(descriptor.fullName), let field = descriptor.field(number: 1) else {
                return nil
            }
            setNonZero(1, try parseValue(json, field: field, path: path))
        }
        return message
    }

    /// Parses bypassing the well-known type check, for Struct's map field.
    private func parse(_ json: JSONValue, asGeneric descriptor: MessageDescriptor, path: String) throws -> DynamicMessage {
        guard case .object(let members) = json, let field = descriptor.field(number: 1),
            case .object(let entries)? = members.first?.value
        else { return DynamicMessage(descriptor: descriptor) }
        var message = DynamicMessage(descriptor: descriptor)
        let entryDescriptor = try messageDescriptor(field, path: path)
        guard let valueField = entryDescriptor.field(number: 2) else { return message }
        for entry in entries {
            var entryMessage = DynamicMessage(descriptor: entryDescriptor)
            entryMessage.set(.single(.string(entry.key)), forField: 1)
            entryMessage.set(
                .single(try parseValue(entry.value, field: valueField, path: "\(path)[\"\(entry.key)\"]")),
                forField: 2)
            message.append(.message(entryMessage), toField: 1)
        }
        return message
    }

    private func parseAny(_ json: JSONValue, as descriptor: MessageDescriptor, path: String) throws -> DynamicMessage {
        guard case .object(let members) = json else {
            throw ProtoJSONError(path: path, reason: String(localized: "expected an object for Any", bundle: .module))
        }
        var message = DynamicMessage(descriptor: descriptor)
        if members.isEmpty { return message }
        guard case .string(let typeURL)? = members.first(where: { $0.key == "@type" })?.value else {
            throw ProtoJSONError(path: path, reason: String(localized: "Any needs an \"@type\" string", bundle: .module))
        }
        let rest = members.filter { $0.key != "@type" }
        let payload: Data
        let typeName = Self.typeName(inAnyURL: typeURL)
        if let inner = registry.message(named: typeName) {
            let innerJSON: JSONValue
            if Self.hasCustomJSON(inner.fullName) {
                guard let value = rest.first(where: { $0.key == "value" })?.value, rest.count == 1 else {
                    throw ProtoJSONError(path: path, reason: String(localized: "Any of \(inner.fullName) needs exactly a \"value\" field", bundle: .module))
                }
                innerJSON = value
            } else {
                innerJSON = .object(rest)
            }
            payload = codec.encode(try parse(innerJSON, as: inner, path: WireCodec.join(path, "value")))
        } else {
            guard rest.count == 1, case .string(let base64) = rest[0].value, rest[0].key == "value",
                let data = Self.decodeBase64(base64)
            else {
                throw ProtoJSONError(
                    path: path,
                    reason: String(localized: "\(typeName) is not in the schema, so Any needs its raw \"value\" as base64", bundle: .module))
            }
            payload = data
        }
        if !typeURL.isEmpty { message.set(.single(.string(typeURL)), forField: 1) }
        if !payload.isEmpty { message.set(.single(.bytes(payload)), forField: 2) }
        return message
    }

    // MARK: - Helpers

    private func enumValueReason(_ name: String, _ typeName: String?) -> String {
        if let typeName {
            return String(localized: "\(name) is not a value of \(typeName)", bundle: .module)
        }
        return String(localized: "\(name) is not a value of the enum", bundle: .module)
    }

    private func messageDescriptor(_ field: FieldDescriptor, path: String) throws -> MessageDescriptor {
        guard let descriptor = registry.message(named: field.typeName ?? "") else {
            throw ProtoJSONError(path: path, reason: String(localized: "type \(field.typeName ?? "?") is not in the schema", bundle: .module))
        }
        return descriptor
    }

    /// The message name an Any type URL refers to: its last path segment.
    static func typeName(inAnyURL typeURL: String) -> String {
        String(typeURL.split(separator: "/").last ?? "")
    }

    static func acceptsNull(_ field: FieldDescriptor) -> Bool {
        !field.isRepeated
            && (field.typeName == "google.protobuf.Value" || field.typeName == "google.protobuf.NullValue")
    }

    static func defaultValue(_ type: FieldType) -> DynamicValue {
        switch type {
        case .int32, .sint32, .sfixed32: return .int32(0)
        case .int64, .sint64, .sfixed64: return .int64(0)
        case .uint32, .fixed32: return .uint32(0)
        case .uint64, .fixed64: return .uint64(0)
        case .float: return .float(0)
        case .double: return .double(0)
        case .bool: return .bool(false)
        case .string: return .string("")
        case .bytes: return .bytes(Data())
        case .enumeration: return .enumeration(0)
        case .message, .group: return .bytes(Data())
        }
    }

    /// Proto3 implicit-presence defaults. -0.0 is not a default, matching
    /// the reference implementations, which compare bit patterns.
    static func isDefault(_ value: DynamicValue) -> Bool {
        switch value {
        case .int32(let x): return x == 0
        case .int64(let x): return x == 0
        case .uint32(let x): return x == 0
        case .uint64(let x): return x == 0
        case .float(let x): return x.bitPattern == 0
        case .double(let x): return x.bitPattern == 0
        case .bool(let x): return !x
        case .string(let x): return x.isEmpty
        case .bytes(let x): return x.isEmpty
        case .enumeration(let x): return x == 0
        case .message: return false
        }
    }

    static func mapKeyString(_ value: DynamicValue) -> String {
        switch value {
        case .int32(let x): return String(x)
        case .int64(let x): return String(x)
        case .uint32(let x): return String(x)
        case .uint64(let x): return String(x)
        case .bool(let x): return x ? "true" : "false"
        case .string(let x): return x
        default: return ""
        }
    }

    static func floatingJSON(_ value: Double, text: String) -> JSONValue {
        if value.isNaN { return .string("NaN") }
        if value == .infinity { return .string("Infinity") }
        if value == -.infinity { return .string("-Infinity") }
        return .number(text)
    }

    /// Shortest round-trip text, with integral values written without ".0".
    static func format<F: BinaryFloatingPoint & LosslessStringConvertible>(_ value: F) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            if value == 0 { return value.sign == .minus ? "-0" : "0" }
            return String(Int64(value))
        }
        return value.description
    }

    static func decodeBase64(_ string: String) -> Data? {
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    static func parseInteger(_ json: JSONValue, min: Int64, max: Int64, path: String) throws -> Int64 {
        let text: String
        switch json {
        case .number(let number): text = number
        case .string(let string): text = string
        default: throw ProtoJSONError(path: path, reason: String(localized: "expected an integer", bundle: .module))
        }
        if let exact = Int64(text) {
            guard exact >= min && exact <= max else {
                throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range", bundle: .module))
            }
            return exact
        }
        // Exponent or fraction forms are allowed when the value is integral.
        guard let double = Double(text), double.isFinite, double == double.rounded() else {
            throw ProtoJSONError(path: path, reason: String(localized: "\(text) is not an integer", bundle: .module))
        }
        guard double >= Double(min) && double < -Double(Int64.min) && double <= Double(max) else {
            throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range", bundle: .module))
        }
        return Int64(double)
    }

    static func parseUnsigned(_ json: JSONValue, max: UInt64, path: String) throws -> UInt64 {
        let text: String
        switch json {
        case .number(let number): text = number
        case .string(let string): text = string
        default: throw ProtoJSONError(path: path, reason: String(localized: "expected an unsigned integer", bundle: .module))
        }
        if let exact = UInt64(text) {
            guard exact <= max else { throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range", bundle: .module)) }
            return exact
        }
        guard let double = Double(text), double.isFinite, double == double.rounded(), double >= 0 else {
            throw ProtoJSONError(path: path, reason: String(localized: "\(text) is not an unsigned integer", bundle: .module))
        }
        guard double < 18_446_744_073_709_551_616.0, UInt64(double) <= max else {
            throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range", bundle: .module))
        }
        return UInt64(double)
    }

    /// The value and, for float fields, the exact text so Float parsing
    /// rounds once instead of twice.
    static func parseFloating(_ json: JSONValue, path: String, asFloat: Bool) throws -> (value: Double, text: String?) {
        switch json {
        case .number(let text):
            guard let value = Double(text) else { throw ProtoJSONError(path: path, reason: String(localized: "\(text) is not a number", bundle: .module)) }
            // Overflow parses as infinity rather than failing.
            guard value.isFinite else {
                throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range", bundle: .module))
            }
            // Checked as Float: FLT_MAX prints as text a little above it as a Double.
            if asFloat, Float(text)?.isFinite != true {
                throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range for float", bundle: .module))
            }
            return (value, text)
        case .string("NaN"): return (.nan, "nan")
        case .string("Infinity"): return (.infinity, "inf")
        case .string("-Infinity"): return (-.infinity, "-inf")
        case .string(let text):
            guard let value = Double(text), value.isFinite else {
                throw ProtoJSONError(path: path, reason: String(localized: "\(text) is not a number", bundle: .module))
            }
            if asFloat, Float(text)?.isFinite != true {
                throw ProtoJSONError(path: path, reason: String(localized: "\(text) is out of range for float", bundle: .module))
            }
            return (value, text)
        default:
            throw ProtoJSONError(path: path, reason: String(localized: "expected a number", bundle: .module))
        }
    }
}
