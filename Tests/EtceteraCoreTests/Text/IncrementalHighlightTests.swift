import Foundation
import Testing

@testable import EtceteraCore

@Suite("Incremental highlighting", .tags(.unit))
struct IncrementalHighlightTests {
    private func fullTokens(_ units: [UInt16]) -> [Token] {
        HighlightCache(units: units, tokenizer: JSONTokenizer()).tokens()
    }

    @Test("A one-character edit in a large document retokenizes one line")
    func oneCharacterEditIsLocal() throws {
        let text = generatedJSON(approximateBytes: 200_000)
        var cache = HighlightCache(text: text, tokenizer: JSONTokenizer())
        #expect(cache.lineCount > 5000)

        let target = (text as NSString).range(of: "\"id\": 400,")
        try #require(target.location != NSNotFound)
        let digit = TextRange(location: target.location + 7, length: 1)
        let update = cache.applyEdit(replacing: digit, with: "5")

        #expect(update.retokenizedLines == 1)
        #expect(update.dirtyRange.location <= digit.location)
        #expect(update.dirtyRange.upperBound >= digit.upperBound)
        #expect(update.dirtyRange.length < 40)
        #expect(cache.tokens() == fullTokens(cache.units))
    }

    @Test("A state change downstream stops retokenizing once the state converges")
    func stopsAtConvergence() {
        let text = "{\n\"a\": 1,\n\"b\": 2,\n\"c\": 3,\n\"d\": 4\n}"
        var cache = HighlightCache(text: text, tokenizer: JSONTokenizer())
        // Turning 1 into an unterminated string changes the state at the end
        // of line 2; line 3 ends back in the same state.
        let one = (text as NSString).range(of: "1")
        let update = cache.applyEdit(replacing: TextRange(one), with: "\"1")
        #expect(update.retokenizedLines == 2)
        #expect(cache.tokens() == fullTokens(cache.units))
    }

    @Test("Opening a container marks downstream tokens whose kind changed")
    func openingContainerRetokenizesDownstream() {
        let text = "[\n\"x\",\n\"y\"\n]"
        var cache = HighlightCache(text: text, tokenizer: JSONTokenizer())
        let update = cache.applyEdit(replacing: TextRange(location: 1, length: 0), with: "{")
        // "x" and "y" are now in key position.
        #expect(cache.tokens().filter { $0.kind == .key }.count == 2)
        #expect(update.dirtyRange.upperBound >= (cache.text as NSString).range(of: "\"y\"").upperBound)
        #expect(cache.tokens() == fullTokens(cache.units))
    }

    @Test("Inserting and deleting newlines splits and merges lines")
    func splitsAndMergesLines() {
        var cache = HighlightCache(text: #"{"a": 1, "b": 2}"#, tokenizer: JSONTokenizer())
        cache.applyEdit(replacing: TextRange(location: 8, length: 0), with: "\n\n")
        #expect(cache.lineCount == 3)
        #expect(cache.tokens() == fullTokens(cache.units))
        cache.applyEdit(replacing: TextRange(location: 8, length: 2), with: "")
        #expect(cache.lineCount == 1)
        #expect(cache.text == #"{"a": 1, "b": 2}"#)
        #expect(cache.tokens() == fullTokens(cache.units))
    }

    @Test("Random edits always match a full retokenize", arguments: [UInt64(1), 7, 42, 2026])
    func randomEditsMatchFullRetokenize(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let fragments = [
            "\"", "{", "}", "[", "]", ",", ":", "\n", "1", "-2.5", "true", "nul",
            "\"k\": ", " ", "", "\\", "\u{E9}", "\u{1F600}", "\n  \"x\": [1, 2],\n",
        ]
        var reference = Array(generatedJSON(approximateBytes: 3_000).utf16)
        var cache = HighlightCache(units: reference, tokenizer: JSONTokenizer())

        for _ in 0..<400 {
            let location = Int.random(in: 0...reference.count, using: &rng)
            let length = Int.random(in: 0...min(12, reference.count - location), using: &rng)
            let replacement = Array(fragments.randomElement(using: &rng)!.utf16)
            reference.replaceSubrange(location..<location + length, with: replacement)
            cache.applyEdit(replacing: TextRange(location: location, length: length), with: replacement)

            #expect(cache.units == reference)
            let expected = fullTokens(reference)
            if cache.tokens() != expected {
                Issue.record("incremental tokens diverged after an edit at \(location)")
                return
            }
        }
    }

    @Test("Querying a range returns only overlapping tokens")
    func rangeQuery() {
        let cache = HighlightCache(text: "[1,\n2,\n3]", tokenizer: JSONTokenizer())
        let tokens = cache.tokens(in: TextRange(location: 4, length: 2))
        #expect(tokens.map(\.kind) == [.number, .punctuation])
    }
}

@Suite("Highlight service", .tags(.unit))
struct HighlightServiceTests {
    @Test("Load returns tokens for the whole buffer")
    func load() async {
        let service = HighlightService()
        let result = await service.load(#"{"a": 1}"#, language: .json)
        #expect(result.dirtyRange == TextRange(location: 0, length: 8))
        #expect(result.tokens.count == 5)
        #expect(result.generation == 1)
    }

    @Test("NSTextStorage-style edits map back to the replaced range")
    func textStorageEdit() async {
        let service = HighlightService()
        _ = await service.load(#"{"a": 1}"#, language: .json)
        // Replace "1" (offset 6) with "true": edited range {6, 4}, delta +3.
        let result = await service.applyEdit(
            editedRange: TextRange(location: 6, length: 4), changeInLength: 3, replacement: "true")
        #expect(await service.text == #"{"a": true}"#)
        #expect(result.tokens.contains { $0.kind == .keyword && $0.range == TextRange(location: 6, length: 4) })
        #expect(result.generation == 2)
    }

    @Test("Plain text yields no tokens")
    func plainText() async {
        let service = HighlightService()
        let result = await service.load("hello {world}", language: .plainText)
        #expect(result.tokens.isEmpty)
    }
}
