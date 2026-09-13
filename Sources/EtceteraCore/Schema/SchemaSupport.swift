import EtcdSchema
import Foundation

/// A profile's schema: the folder of .proto files and the key mappings.
/// See SPEC 5.5.
public struct SchemaSettings: Codable, Hashable, Sendable {
    public var source: FileReference?
    public var mappings: [SchemaMappingRule]

    public init(source: FileReference? = nil, mappings: [SchemaMappingRule] = []) {
        self.source = source
        self.mappings = mappings
    }

    public var configuration: SchemaMappingConfiguration {
        SchemaMappingConfiguration(schemaSource: source?.displayName ?? "", mappings: mappings)
    }
}

/// Compiles a profile's schema with protoc, reusing the cache while the
/// sources are unchanged. The application resolves the folder bookmark.
public protocol SchemaLoading: Sendable {
    /// Errors carry protoc's output verbatim.
    func schema(for settings: SchemaSettings, profileID: String, force: Bool) async throws -> CompiledSchema
}

/// A compiled schema and the .proto files protoc left out of it.
public struct CompiledSchema: Sendable {
    public var registry: SchemaRegistry
    public var skipped: [SkippedProtoFile]

    public init(registry: SchemaRegistry, skipped: [SkippedProtoFile] = []) {
        self.registry = registry
        self.skipped = skipped
    }
}

public enum SchemaState: Sendable {
    case notConfigured
    case compiling
    case ready(SchemaRegistry)
    case failed(String)
}

/// The outcome of the mapping editor's Test.
public enum MappingTestResult: Equatable, Sendable {
    /// No rule matches; the value shows with the format guess.
    case unmapped
    case decoded(rule: SchemaMappingRule, json: String)
    case failed(rule: SchemaMappingRule, reason: String)
}

/// How a JSON value compares with its mapped message. Advice only: the value
/// is saved as typed. See SPEC 5.5.
public enum SchemaCheck: Equatable, Sendable {
    case matches
    case mismatch(String)
}

public enum MessageCheck {
    /// A JSON object, the form a message takes when stored as text.
    public nonisolated static func isJSONObject(_ data: Data) -> Bool {
        guard data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "{") else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    public nonisolated static func check(_ text: String, message: String, codec: ProtobufValueCodec) -> SchemaCheck {
        do {
            _ = try codec.message(fromJSON: text, messageName: message)
            return .matches
        } catch {
            return .mismatch(ConnectionModel.message(for: error))
        }
    }
}

/// Tests a key against mapping rules; only for the live connection.
public typealias MappingTester = (_ key: String, _ rules: [SchemaMappingRule]) async -> MappingTestResult

/// Completion over every message name in the registry, for the mapping
/// editor.
public enum MessageCompletion {
    public static func suggestions(for query: String, in registry: SchemaRegistry, limit: Int = 50) -> [String] {
        let names = registry.allMessageNames
        guard !query.isEmpty else { return Array(names.prefix(limit)) }
        return Array(names.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }
}
