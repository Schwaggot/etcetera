import Foundation

// The etcd JSON gateway follows the proto3 JSON mapping: 64-bit integers are
// JSON strings, bytes are base64, and absent fields mean proto3 defaults.
// These wrappers convert at the edge so no caller ever sees either encoding.

/// An `Int64` that crosses the gateway as a JSON string.
@propertyWrapper
public struct StringInt64: Codable, Hashable, Sendable {
    public var wrappedValue: Int64

    public init(wrappedValue: Int64 = 0) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard let value = Int64(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an int64: \(string)")
            }
            wrappedValue = value
        } else {
            wrappedValue = try container.decode(Int64.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(wrappedValue))
    }
}

/// A `UInt64` that crosses the gateway as a JSON string. Cluster and member
/// identifiers exceed `Int64.max` in practice.
@propertyWrapper
public struct StringUInt64: Codable, Hashable, Sendable {
    public var wrappedValue: UInt64

    public init(wrappedValue: UInt64 = 0) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard let value = UInt64(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not a uint64: \(string)")
            }
            wrappedValue = value
        } else {
            wrappedValue = try container.decode(UInt64.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(wrappedValue))
    }
}

/// `Data` that crosses the gateway as standard padded base64.
@propertyWrapper
public struct Base64Data: Codable, Hashable, Sendable {
    public var wrappedValue: Data

    public init(wrappedValue: Data = Data()) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let data = Data(base64Encoded: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not base64: \(string)")
        }
        wrappedValue = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.base64EncodedString())
    }
}

// Absent fields mean proto3 defaults. These overloads make synthesized
// Codable treat a missing key as the default instead of throwing.

extension KeyedDecodingContainer {
    public func decode(_ type: StringInt64.Type, forKey key: Key) throws -> StringInt64 {
        try decodeIfPresent(type, forKey: key) ?? StringInt64()
    }

    public func decode(_ type: StringUInt64.Type, forKey key: Key) throws -> StringUInt64 {
        try decodeIfPresent(type, forKey: key) ?? StringUInt64()
    }

    public func decode(_ type: Base64Data.Type, forKey key: Key) throws -> Base64Data {
        try decodeIfPresent(type, forKey: key) ?? Base64Data()
    }
}
