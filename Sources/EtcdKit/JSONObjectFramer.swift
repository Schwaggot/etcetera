import Foundation

/// Splits a streaming response into top-level JSON values. Newer gateways
/// separate watch responses with newlines; etcd 3.2 concatenates them with
/// no separator at all, so framing by lines would never yield.
struct JSONObjectFramer {
    private var buffer: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false

    /// Feeds one byte; returns a complete top-level value when it closes.
    /// Bytes between values (whitespace, newlines) are dropped.
    mutating func append(_ byte: UInt8) -> Data? {
        if depth == 0 && byte != UInt8(ascii: "{") && byte != UInt8(ascii: "[") {
            return nil
        }
        buffer.append(byte)
        if inString {
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
            }
            return nil
        }
        switch byte {
        case UInt8(ascii: "\""):
            inString = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
            if depth == 0 {
                let value = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                return value
            }
        default:
            break
        }
        return nil
    }

    mutating func append(contentsOf bytes: some Sequence<UInt8>) -> [Data] {
        bytes.compactMap { append($0) }
    }
}
