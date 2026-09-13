import Foundation

/// A key split for the Copy menus: the whole key, the prefix up to and
/// including the last separator, and the name after it.
public struct KeyParts: Equatable, Sendable {
    public let full: String
    public let prefix: String
    public let name: String

    public init(_ key: Data, separator: Character) {
        full = displayString(for: key)
        if let index = full.lastIndex(of: separator) {
            prefix = String(full[...index])
            name = String(full[full.index(after: index)...])
        } else {
            prefix = ""
            name = full
        }
    }
}

/// A value as clipboard text: text as is, binary as hex digits.
public func clipboardText(for value: Data) -> String {
    ValueFormat.guess(for: value).isTextual ? String(decoding: value, as: UTF8.self) : hexString(value)
}

public struct KeyNotFoundError: LocalizedError, Sendable {
    public let key: Data
    public var errorDescription: String? { String(localized: "\(displayString(for: key)) no longer exists.", bundle: .module) }
}

extension ConnectionModel {
    /// A key's current value as clipboard text.
    public func clipboardValue(forKey key: Data) async throws -> String {
        guard let kv = try await value(forKey: key) else { throw KeyNotFoundError(key: key) }
        return clipboardText(for: kv.value)
    }
}
