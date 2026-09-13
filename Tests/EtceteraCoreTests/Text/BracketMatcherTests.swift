import Foundation
import Testing

@testable import EtceteraCore

@Suite("Bracket matching", .tags(.unit))
struct BracketMatcherTests {
    private func offset(_ text: String, _ needle: String, from: Int = 0) -> Int {
        let ns = text as NSString
        return ns.range(of: needle, range: NSRange(location: from, length: ns.length - from)).location
    }

    @Test("A backslash at the end of a line does not carry the string onto the next line")
    func escapeAtLineEnd() {
        let units = Array("[\"a\\\n, [1]]".utf16)
        #expect(BracketMatcher.matchingOffset(in: units, at: 7) == 9)
        #expect(BracketMatcher.matchingOffset(in: units, at: 0) == 10)
    }

    @Test("An opener matches its closer and back")
    func matchesBothDirections() {
        let units = Array(#"{"a": [1, 2]}"#.utf16)
        #expect(BracketMatcher.matchingOffset(in: units, at: 0) == 12)
        #expect(BracketMatcher.matchingOffset(in: units, at: 12) == 0)
        #expect(BracketMatcher.matchingOffset(in: units, at: 6) == 11)
        #expect(BracketMatcher.matchingOffset(in: units, at: 11) == 6)
    }

    @Test("Brackets inside strings are ignored")
    func ignoresStrings() {
        let text = #"{"a": "}]", "b": ["\"]"]}"#
        let units = Array(text.utf16)
        #expect(BracketMatcher.matchingOffset(in: units, at: 0) == units.count - 1)
        let array = offset(text, "[")
        #expect(BracketMatcher.matchingOffset(in: units, at: array) == units.count - 2)
    }

    @Test("A bracket inside a string has no match")
    func bracketInString() {
        let text = #"["}"]"#
        #expect(BracketMatcher.matchingOffset(in: Array(text.utf16), at: 2) == nil)
    }

    @Test("Unbalanced or mismatched brackets have no match")
    func unbalanced() {
        #expect(BracketMatcher.matchingOffset(in: Array("[1, 2".utf16), at: 0) == nil)
        #expect(BracketMatcher.matchingOffset(in: Array("1]".utf16), at: 1) == nil)
        #expect(BracketMatcher.matchingOffset(in: Array("[1}".utf16), at: 0) == nil)
    }

    @Test("A non-bracket position has no match")
    func notABracket() {
        #expect(BracketMatcher.matchingOffset(in: Array("[1]".utf16), at: 1) == nil)
    }

    @Test("The cursor checks the character before it first")
    func cursorPrefersPrevious() {
        // Cursor between "]" and "}": the "]" before the cursor wins.
        let text = "{[]}"
        #expect(BracketMatcher.match(in: text, cursor: 3) == BracketPair(bracket: 2, match: 1))
        // Cursor at 0: only the "{" after it qualifies.
        #expect(BracketMatcher.match(in: text, cursor: 0) == BracketPair(bracket: 0, match: 3))
        #expect(BracketMatcher.match(in: "abc", cursor: 1) == nil)
    }

    @Test("Offsets count UTF-16 units")
    func utf16() {
        let text = "[\"\u{1F600}\", {}]"
        let units = Array(text.utf16)
        #expect(BracketMatcher.matchingOffset(in: units, at: 0) == units.count - 1)
    }
}
