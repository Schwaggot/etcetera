import Foundation

/// How a value is presented. The application guesses on load and the user can
/// override. See SPEC 4.4.
public enum ValueFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case json = "JSON"
    /// Chosen only when a schema mapping matches the key, never by guessing.
    case protobuf = "Protobuf"
    case text = "Text"
    case hex = "Hex"

    public var id: String { rawValue }

    /// JSON if it parses, text if valid UTF-8, hex for everything else.
    public static func guess(for data: Data) -> ValueFormat {
        if !data.isEmpty,
            (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
        {
            return .json
        }
        if String(data: data, encoding: .utf8) != nil {
            return .text
        }
        return .hex
    }

    /// Whether the editor can show this format as editable text.
    public var isTextual: Bool { self != .hex }
}
