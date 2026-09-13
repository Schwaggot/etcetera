import Foundation

/// Renders arbitrary bytes for display. Non-UTF-8 bytes show as \xNN escapes
/// and are not editable inline. See SPEC 4.2.
public func displayString(for data: Data) -> String {
    if let string = String(data: data, encoding: .utf8) {
        return string
    }
    return data.map { byte in
        (0x20..<0x7F).contains(byte) && byte != 0x5C
            ? String(UnicodeScalar(byte))
            : String(format: "\\x%02X", byte)
    }.joined()
}

/// A read-only byte inspector with offsets and an ASCII gutter. See SPEC 4.4.
public enum HexDump {
    public static func render(_ data: Data, bytesPerLine: Int = 16) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data)
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / bytesPerLine + 1)
        for lineStart in stride(from: 0, to: bytes.count, by: bytesPerLine) {
            let slice = bytes[lineStart..<min(lineStart + bytesPerLine, bytes.count)]
            let offset = String(format: "%08X", lineStart)
            let hex = slice.map { String(format: "%02X", $0) }
                .joined(separator: " ")
                .padding(toLength: bytesPerLine * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = slice.map { byte in
                (0x20..<0x7F).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }.joined()
            lines.append("\(offset)  \(hex)  |\(ascii)|")
        }
        return lines.joined(separator: "\n")
    }
}
