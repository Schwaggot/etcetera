import Foundation

/// A tolerant JSON tokenizer. Invalid or partial input produces `.error`
/// tokens rather than failing, and strings in key position become `.key`.
/// JSON strings cannot span lines, so an unterminated string ends at the
/// line end.
public struct JSONTokenizer: Tokenizer {
    public struct State: Hashable, Sendable {
        enum Container: UInt8, Hashable, Sendable {
            case object, array
        }

        enum Expect: UInt8, Hashable, Sendable {
            case value, key, colon, commaOrEnd
        }

        var stack: [Container] = []
        var expect: Expect = .value

        /// A missing comma between pairs is common while typing, so a string
        /// after a value inside an object is still read as the next key.
        var inKeyPosition: Bool {
            stack.last == .object && (expect == .key || expect == .commaOrEnd)
        }
    }

    public init() {}

    public var initialState: State { State() }

    public func tokenize(line: ArraySlice<UInt16>, state: inout State, into tokens: inout [Token]) {
        let base = line.startIndex
        let end = line.endIndex
        var i = base

        func append(_ kind: TokenKind, _ start: Int, _ stop: Int) {
            tokens.append(Token(kind: kind, range: TextRange(location: start - base, length: stop - start)))
        }

        while i < end {
            let c = line[i]
            switch c {
            case 0x20, 0x09, 0x0D, 0x0A:
                i += 1

            case 0x22:  // "
                let start = i
                i += 1
                var terminated = false
                while i < end {
                    let d = line[i]
                    if d == 0x5C {
                        i = min(i + 2, end)
                        continue
                    }
                    i += 1
                    if d == 0x22 {
                        terminated = true
                        break
                    }
                }
                let isKey = state.inKeyPosition
                append(terminated ? (isKey ? .key : .string) : .error, start, i)
                state.expect = isKey ? .colon : .commaOrEnd

            case 0x7B, 0x5B:  // { [
                append(.punctuation, i, i + 1)
                state.stack.append(c == 0x7B ? .object : .array)
                state.expect = c == 0x7B ? .key : .value
                i += 1

            case 0x7D, 0x5D:  // } ]
                let container: State.Container = c == 0x7D ? .object : .array
                if state.stack.last == container {
                    state.stack.removeLast()
                    state.expect = .commaOrEnd
                    append(.punctuation, i, i + 1)
                } else {
                    append(.error, i, i + 1)
                }
                i += 1

            case 0x3A:  // :
                let inObject = state.stack.last == .object
                append(inObject && state.expect == .colon ? .punctuation : .error, i, i + 1)
                if inObject { state.expect = .value }
                i += 1

            case 0x2C:  // ,
                let valid = state.expect == .commaOrEnd && !state.stack.isEmpty
                append(valid ? .punctuation : .error, i, i + 1)
                state.expect = state.stack.last == .object ? .key : .value
                i += 1

            default:
                let start = i
                var kind: TokenKind
                if Self.isWordUnit(c) {
                    while i < end, Self.isWordUnit(line[i]) { i += 1 }
                    let word = line[start..<i]
                    if Self.isDigit(c) || c == 0x2D {
                        kind = Self.isValidNumber(word) ? .number : .error
                    } else {
                        kind = Self.isKeyword(word) ? .keyword : .error
                    }
                } else {
                    while i < end, !Self.isDelimiter(line[i]) { i += 1 }
                    kind = .error
                }
                if state.inKeyPosition {
                    kind = .error
                    state.expect = .colon
                } else {
                    state.expect = .commaOrEnd
                }
                append(kind, start, i)
            }
        }
    }

    // MARK: - Character classes

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Letters, digits, and the characters a number can contain.
    static func isWordUnit(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x5F
    }

    static func isDelimiter(_ c: UInt16) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0D, 0x0A, 0x22, 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C: true
        default: false
        }
    }

    private static let keywords: [[UInt16]] = ["true", "false", "null"].map { Array($0.utf16) }

    static func isKeyword(_ word: ArraySlice<UInt16>) -> Bool {
        keywords.contains { $0.elementsEqual(word) }
    }

    /// -? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?
    static func isValidNumber(_ word: ArraySlice<UInt16>) -> Bool {
        var i = word.startIndex
        let end = word.endIndex
        func digits() -> Int {
            let start = i
            while i < end, isDigit(word[i]) { i += 1 }
            return i - start
        }
        if i < end, word[i] == 0x2D { i += 1 }
        guard i < end else { return false }
        if word[i] == 0x30 {
            i += 1
        } else if digits() == 0 {
            return false
        }
        if i < end, word[i] == 0x2E {
            i += 1
            guard digits() > 0 else { return false }
        }
        if i < end, word[i] == 0x65 || word[i] == 0x45 {
            i += 1
            if i < end, word[i] == 0x2B || word[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return false }
        }
        return i == end
    }
}
