import Foundation

/// Formats JSON as text, not through a decoded model, so key order and
/// string contents are preserved exactly and invalid JSON is still formatted
/// as far as possible. See SPEC 4.3.
public struct JSONFormatter: Hashable, Sendable {
    public enum Indent: Hashable, Sendable {
        case spaces(Int)
        case tab

        var bytes: [UInt8] {
            switch self {
            case .spaces(let count): [UInt8](repeating: 0x20, count: max(0, count))
            case .tab: [0x09]
            }
        }
    }

    public var indent: Indent

    public init(indent: Indent = .spaces(2)) {
        self.indent = indent
    }

    public func prettyPrint(_ text: String) -> String {
        format(text, pretty: true)
    }

    public func minify(_ text: String) -> String {
        format(text, pretty: false)
    }

    private func format(_ text: String, pretty: Bool) -> String {
        let input = Array(text.utf8)
        let count = input.count
        let unit = indent.bytes
        var out: [UInt8] = []
        out.reserveCapacity(pretty ? count + count / 2 : count)

        var depth = 0
        // Set right after an emitted newline and indent, so a second newline
        // replaces the empty line instead of stacking.
        var lineStart: Int?
        // Whitespace separating two scalars is kept as one space so that
        // invalid input like `1 2` does not fuse into `12`.
        var sawSpace = false
        var lastWasValue = false

        func emit(_ byte: UInt8) {
            out.append(byte)
            lineStart = nil
        }

        func newline() {
            if let start = lineStart {
                out.removeSubrange(start...)
            } else if !out.isEmpty {
                out.append(0x0A)
            }
            lineStart = out.count
            for _ in 0..<depth { out.append(contentsOf: unit) }
        }

        var i = 0
        while i < count {
            let c = input[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                sawSpace = true
                i += 1
                continue

            case 0x22:  // "
                if sawSpace && lastWasValue { emit(0x20) }
                emit(c)
                i += 1
                while i < count {
                    let d = input[i]
                    if d == 0x0A { break }  // unterminated: strings end at the line
                    emit(d)
                    i += 1
                    if d == 0x5C {
                        if i < count, input[i] != 0x0A {
                            emit(input[i])
                            i += 1
                        }
                    } else if d == 0x22 {
                        break
                    }
                }
                lastWasValue = true

            case 0x7B, 0x5B:  // { [
                let closer: UInt8 = c == 0x7B ? 0x7D : 0x5D
                var k = i + 1
                while k < count, Self.isSpace(input[k]) { k += 1 }
                emit(c)
                if k < count, input[k] == closer {
                    emit(closer)
                    i = k + 1
                    lastWasValue = true
                    sawSpace = false
                    continue
                }
                depth += 1
                if pretty { newline() }
                lastWasValue = false
                i += 1

            case 0x7D, 0x5D:  // } ]
                depth = max(0, depth - 1)
                if pretty { newline() }
                emit(c)
                lastWasValue = true
                i += 1

            case 0x2C:  // ,
                emit(c)
                if pretty { newline() }
                lastWasValue = false
                i += 1

            case 0x3A:  // :
                emit(c)
                if pretty { emit(0x20) }
                lastWasValue = false
                i += 1

            default:
                if sawSpace && lastWasValue { emit(0x20) }
                emit(c)
                lastWasValue = true
                i += 1
            }
            sawSpace = false
        }

        // Truncated input leaves a dangling newline and indent; drop both.
        if let start = lineStart {
            out.removeSubrange(start...)
            if out.last == 0x0A { out.removeLast() }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }
}
