import Foundation

// Binding key patterns to message types. See SPEC 5.5.

public struct SchemaMappingRule: Codable, Sendable, Hashable {
    public enum Pattern: Sendable, Hashable {
        case prefix(String)
        case key(String)

        public var text: String {
            switch self {
            case .prefix(let text), .key(let text): text
            }
        }
    }

    public var pattern: Pattern
    /// Fully qualified message name.
    public var message: String
    /// Dotted path of a string field in the value's JSON that names the key
    /// in the UI, such as "name" or "info.name". See SPEC 5.5.
    public var nameField: String?

    public init(_ pattern: Pattern, message: String, nameField: String? = nil) {
        self.pattern = pattern
        self.message = message
        self.nameField = nameField
    }

    enum CodingKeys: String, CodingKey {
        case prefix, key, message, nameField
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        let nameField = try container.decodeIfPresent(String.self, forKey: .nameField)?
            .trimmingCharacters(in: .whitespaces)
        self.nameField = nameField?.isEmpty == false ? nameField : nil
        let prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        let key = try container.decodeIfPresent(String.self, forKey: .key)
        switch (prefix, key) {
        case (let prefix?, nil): pattern = .prefix(prefix)
        case (nil, let key?): pattern = .key(key)
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "a mapping needs exactly one of prefix or key"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch pattern {
        case .prefix(let prefix): try container.encode(prefix, forKey: .prefix)
        case .key(let key): try container.encode(key, forKey: .key)
        }
        try container.encode(message, forKey: .message)
        if let nameField, !nameField.isEmpty { try container.encode(nameField, forKey: .nameField) }
    }

    /// The name `nameField` gives a JSON value; nil when there is no name
    /// field, the value is not a JSON object, or the field is not a
    /// non-empty string. A segment also matches its lowerCamelCase form.
    public func displayName(forValue data: Data) -> String? {
        guard let nameField, !nameField.isEmpty,
            var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let segments = nameField.split(separator: ".").map(String.init)
        for (index, segment) in segments.enumerated() {
            guard let next = node[segment] ?? node[Self.lowerCamel(segment)] else { return nil }
            if index == segments.count - 1 {
                guard let name = (next as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                else { return nil }
                return name
            }
            guard let object = next as? [String: Any] else { return nil }
            node = object
        }
        return nil
    }

    private static func lowerCamel(_ name: String) -> String {
        let parts = name.split(separator: "_")
        guard let first = parts.first else { return name }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

public enum MappingResolution: Sendable, Equatable {
    /// No rule matches; the value falls back to the format guess.
    case unmapped
    case mapped(message: String, rule: SchemaMappingRule)
    /// A rule matches but cannot be honored. Shown on the key, never ignored.
    case misconfigured(rule: SchemaMappingRule, reason: String)
}

public struct SchemaMappingConfiguration: Codable, Sendable, Equatable {
    /// Where the .proto files live, such as a security-scoped bookmark.
    public var schemaSource: String
    public var mappings: [SchemaMappingRule]

    public init(schemaSource: String, mappings: [SchemaMappingRule] = []) {
        self.schemaSource = schemaSource
        self.mappings = mappings
    }

    /// An exact key match beats any prefix; otherwise the longest prefix wins.
    public func rule(forKey key: String) -> SchemaMappingRule? {
        if let exact = mappings.first(where: { $0.pattern == .key(key) }) {
            return exact
        }
        var best: (rule: SchemaMappingRule, length: Int)?
        for rule in mappings {
            guard case .prefix(let prefix) = rule.pattern, key.hasPrefix(prefix) else { continue }
            let length = prefix.utf8.count
            if best == nil || length > best!.length {
                best = (rule, length)
            }
        }
        return best?.rule
    }

    /// Resolves a key against a compiled registry; nil means the schema has
    /// not been compiled.
    public func resolve(key: String, in registry: SchemaRegistry?) -> MappingResolution {
        guard let rule = rule(forKey: key) else { return .unmapped }
        guard let registry else {
            return .misconfigured(rule: rule, reason: String(localized: "The schema has not been compiled.", bundle: .module))
        }
        guard registry.message(named: rule.message) != nil else {
            return .misconfigured(rule: rule, reason: String(localized: "The message type \(rule.message) is not in the schema.", bundle: .module))
        }
        return .mapped(message: rule.message, rule: rule)
    }

    /// Every rule whose message is missing from the registry.
    public func problems(in registry: SchemaRegistry) -> [SchemaMappingRule] {
        mappings.filter { registry.message(named: $0.message) == nil }
    }
}
