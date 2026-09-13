import Foundation

/// A range in UTF-16 code units, the unit NSTextView and NSRange count in.
public struct TextRange: Hashable, Sendable, CustomStringConvertible {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public func overlaps(_ other: TextRange) -> Bool {
        location < other.upperBound && other.location < upperBound
    }

    public var description: String { "{\(location), \(length)}" }
}

/// The token types the highlighter colors. See SPEC 4.3.
public enum TokenKind: UInt8, Hashable, Sendable, CaseIterable {
    case string, number, keyword, key, punctuation, error
}

/// One highlighted run. Doubles as the token run the main actor applies.
public struct Token: Hashable, Sendable {
    public var kind: TokenKind
    public var range: TextRange

    public init(kind: TokenKind, range: TextRange) {
        self.kind = kind
        self.range = range
    }
}

/// Tokenizes one line at a time so an edit retokenizes only the lines it
/// touches. `State` carries whatever context crosses a line break.
public protocol Tokenizer: Sendable {
    associatedtype State: Hashable & Sendable

    var initialState: State { get }

    /// Tokenizes `line`, which excludes its terminator. Token locations are
    /// relative to the line start. Leaves `state` at the line-end state.
    func tokenize(line: ArraySlice<UInt16>, state: inout State, into tokens: inout [Token])
}

/// The fallback for unknown content: no tokens.
public struct PlainTextTokenizer: Tokenizer {
    public init() {}
    public var initialState: Int { 0 }
    public func tokenize(line: ArraySlice<UInt16>, state: inout Int, into tokens: inout [Token]) {}
}

/// The languages the editor can highlight.
public enum SyntaxLanguage: String, Hashable, Sendable, CaseIterable {
    case json
    case plainText
}
