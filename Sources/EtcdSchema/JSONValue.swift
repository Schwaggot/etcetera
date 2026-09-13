import Foundation

// A JSON tree that keeps object key order and number text exactly, so 64-bit
// integers and float bit patterns survive, and a parser and printer for it.
// Foundation's JSONSerialization does neither.

public struct JSONMember: Sendable, Equatable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number as written, validated against the JSON grammar.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])
}

public struct JSONSyntaxError: Error, Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let message: String
}

extension JSONSyntaxError: LocalizedError {
    public var errorDescription: String? {
        String(localized: "JSON syntax error at line \(line), column \(column): \(message)", bundle: .module)
    }
}

extension JSONValue {
    public static func parse(_ text: String, maxDepth: Int = 200) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(text.utf8), maxDepth: maxDepth)
        return try parser.parseDocument()
    }

    /// Pretty-printed with the given indent, keys in stored order.
    public func rendered(indent: Int = 2) -> String {
        var output = ""
        JSONPrinter(indent: String(repeating: " ", count: indent)).write(self, level: 0, into: &output)
        return output
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error(String(localized: "unexpected content after the value", bundle: .module)) }
        return value
    }

    func error(_ message: String) -> JSONSyntaxError {
        var line = 1
        var column = 1
        for byte in bytes[0..<min(index, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return JSONSyntaxError(line: line, column: column, message: message)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < maxDepth else { throw error(String(localized: "nesting is too deep", bundle: .module)) }
        guard index < bytes.count else { throw error(String(localized: "unexpected end of input", bundle: .module)) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error(String(localized: "unexpected character", bundle: .module))
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes.count - index >= expected.count,
            Array(bytes[index..<(index + expected.count)]) == expected
        else { throw error(String(localized: "expected \(literal)", bundle: .module)) }
        index += expected.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error(String(localized: "expected a quoted key", bundle: .module))
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error(String(localized: "expected ':'", bundle: .module)) }
            index += 1
            skipWhitespace()
            members.append(JSONMember(key, try parseValue(depth: depth + 1)))
            skipWhitespace()
            guard index < bytes.count else { throw error(String(localized: "unexpected end of input", bundle: .module)) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            } else {
                throw error(String(localized: "expected ',' or '}'", bundle: .module))
            }
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error(String(localized: "unexpected end of input", bundle: .module)) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            } else {
                throw error(String(localized: "expected ',' or ']'", bundle: .module))
            }
        }
    }

    mutating func parseNumber() throws -> String {
        let start = index
        func digits() -> Int {
            let from = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index - from
        }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error(String(localized: "invalid number", bundle: .module)) }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            throw error(String(localized: "invalid number", bundle: .module))
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error(String(localized: "invalid number", bundle: .module)) }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard digits() > 0 else { throw error(String(localized: "invalid number", bundle: .module)) }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error(String(localized: "unterminated string", bundle: .module)) }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let string = String(validating: buffer, as: UTF8.self) else {
                    throw error(String(localized: "invalid UTF-8 in string", bundle: .module))
                }
                return string
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw error(String(localized: "unterminated escape", bundle: .module)) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800..<0xDC00).contains(scalar) {
                        guard bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"),
                            bytes[index + 1] == UInt8(ascii: "u")
                        else { throw error(String(localized: "unpaired surrogate", bundle: .module)) }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw error(String(localized: "unpaired surrogate", bundle: .module)) }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00..<0xE000).contains(scalar) {
                        throw error(String(localized: "unpaired surrogate", bundle: .module))
                    }
                    buffer.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar)!)).utf8))
                default:
                    throw error(String(localized: "invalid escape", bundle: .module))
                }
            default:
                guard byte >= 0x20 else { throw error(String(localized: "control character in string", bundle: .module)) }
                buffer.append(byte)
            }
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard bytes.count - index >= 4 else { throw error(String(localized: "invalid \\u escape", bundle: .module)) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error(String(localized: "invalid \\u escape", bundle: .module))
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }
}

private struct JSONPrinter {
    let indent: String

    func write(_ value: JSONValue, level: Int, into output: inout String) {
        switch value {
        case .null: output += "null"
        case .bool(let bool): output += bool ? "true" : "false"
        case .number(let text): output += text
        case .string(let string): Self.writeString(string, into: &output)
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            output += "[\n"
            for (offset, element) in elements.enumerated() {
                output += String(repeating: indent, count: level + 1)
                write(element, level: level + 1, into: &output)
                output += offset == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "]"
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += String(repeating: indent, count: level + 1)
                Self.writeString(member.key, into: &output)
                output += ": "
                write(member.value, level: level + 1, into: &output)
                output += offset == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "}"
        }
    }

    static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
