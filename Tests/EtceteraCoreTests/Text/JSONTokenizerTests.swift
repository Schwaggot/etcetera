import Foundation
import Testing

@testable import EtceteraCore

@Suite("JSON tokenizer", .tags(.unit))
struct JSONTokenizerTests {
    @Test("Classifies keys, strings, numbers, keywords, and punctuation")
    func classifiesTokenTypes() {
        let tokens = tokenTexts(#"{"name": "etcd", "port": 2379, "tls": true, "ca": null}"#)
        #expect(tokens.map(\.0) == [
            .punctuation, .key, .punctuation, .string, .punctuation,
            .key, .punctuation, .number, .punctuation,
            .key, .punctuation, .keyword, .punctuation,
            .key, .punctuation, .keyword, .punctuation,
        ])
        #expect(tokens[1].1 == #""name""#)
        #expect(tokens[7].1 == "2379")
    }

    @Test("A string in an array is a value, not a key")
    func arrayStringsAreValues() {
        let tokens = tokenTexts(#"{"tags": ["a", "b"]}"#)
        let strings = tokens.filter { $0.0 == .string }.map(\.1)
        #expect(strings == [#""a""#, #""b""#])
        #expect(tokens.filter { $0.0 == .key }.map(\.1) == [#""tags""#])
    }

    @Test("Key position is tracked across lines and nesting")
    func keyPositionAcrossLines() {
        let text = """
            {
              "a": 1,
              "b": [
                "c",
                {"d": "e"}
              ]
            }
            """
        let tokens = tokenTexts(text)
        #expect(tokens.filter { $0.0 == .key }.map(\.1) == [#""a""#, #""b""#, #""d""#])
        #expect(tokens.filter { $0.0 == .string }.map(\.1) == [#""c""#, #""e""#])
    }

    @Test("A key after a missing comma on the previous line is still a key")
    func missingCommaStillKey() {
        let tokens = tokenTexts("{\"a\": 1\n\"b\": 2}")
        #expect(tokens.filter { $0.0 == .key }.map(\.1) == [#""a""#, #""b""#])
    }

    @Test("Escaped quotes do not end a string")
    func escapedQuotes() {
        let tokens = tokenTexts(#"["say \"hi\"", 1]"#)
        #expect(tokens[1] == (.string, #""say \"hi\"""#))
        #expect(tokens[3].0 == .number)
    }

    @Test("An unterminated string is an error that ends at the line end")
    func unterminatedString() {
        let tokens = tokenTexts("{\"a\": \"open\n}")
        #expect(tokens.contains { $0.0 == .error && $0.1 == "\"open" })
        #expect(tokens.last?.0 == .punctuation)
    }

    @Test("Stray characters become errors instead of failing")
    func strayCharacters() {
        let tokens = tokenTexts("[1, @@, 2]")
        #expect(tokens.contains { $0.0 == .error && $0.1 == "@@" })
        #expect(tokens.filter { $0.0 == .number }.count == 2)
    }

    @Test("Numbers follow the JSON grammar",
        arguments: [
            ("0", true), ("-1", true), ("3.14", true), ("1e10", true), ("-2.5E-3", true),
            ("01", false), ("1.", false), ("-", false), ("1e", false), ("+1", false), ("0x1F", false),
        ])
    func numberGrammar(text: String, valid: Bool) {
        let tokens = tokenTexts("[\(text)]")
        #expect(tokens[1].0 == (valid ? .number : .error))
        #expect(tokens[1].1 == text)
    }

    @Test("Only true, false, and null are keywords")
    func keywords() {
        let tokens = tokenTexts("[true, false, null, nul, True]")
        #expect(tokens.filter { $0.0 == .keyword }.map(\.1) == ["true", "false", "null"])
        #expect(tokens.filter { $0.0 == .error }.map(\.1) == ["nul", "True"])
    }

    @Test("A mismatched closing bracket is an error")
    func mismatchedCloser() {
        let tokens = tokenTexts("[1}")
        #expect(tokens.last?.0 == .error)
    }

    @Test("A bare word in key position is an error")
    func bareKey() {
        let tokens = tokenTexts("{name: 1}")
        #expect(tokens[1] == (.error, "name"))
        #expect(tokens[2].0 == .punctuation)
        #expect(tokens[3].0 == .number)
    }

    @Test("Token ranges are UTF-16 offsets")
    func utf16Offsets() {
        let text = #"{"😀": "é", "n": 1}"#
        let tokens = HighlightCache(text: text, tokenizer: JSONTokenizer()).tokens()
        // The emoji is two UTF-16 units, so the key spans 4 units.
        #expect(tokens[1].range == TextRange(location: 1, length: 4))
        let number = tokens.first { $0.kind == .number }
        let expected = (text as NSString).range(of: "1")
        #expect(number?.range == TextRange(expected))
    }

    @Test("Plain text produces no tokens")
    func plainText() {
        let cache = HighlightCache(text: #"{"a": 1}"#, tokenizer: PlainTextTokenizer())
        #expect(cache.tokens().isEmpty)
    }
}
