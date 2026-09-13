import Foundation
import Testing

@testable import EtceteraCore

@Suite("JSON formatting", .tags(.unit))
struct JSONFormatterTests {
    let formatter = JSONFormatter()

    @Test("Pretty-prints nested values with two-space indent")
    func prettyPrints() {
        let input = #"{"a":1,"b":[true,null],"c":{"d":"e"}}"#
        let expected = """
            {
              "a": 1,
              "b": [
                true,
                null
              ],
              "c": {
                "d": "e"
              }
            }
            """
        #expect(formatter.prettyPrint(input) == expected)
    }

    @Test("Preserves key order rather than sorting")
    func preservesKeyOrder() {
        let output = formatter.minify(formatter.prettyPrint(#"{"z": 1, "a": 2, "m": 3}"#))
        #expect(output == #"{"z":1,"a":2,"m":3}"#)
    }

    @Test("Preserves string contents exactly, including escapes and brackets")
    func preservesStrings() {
        let input = #"{"k": "a \"b\" {c} [d], e: f\\n é \u{1F600}"}"#
        let pretty = formatter.prettyPrint(input)
        #expect(pretty.contains(#""a \"b\" {c} [d], e: f\\n é \u{1F600}""#))
        #expect(formatter.minify(pretty) == #"{"k":"a \"b\" {c} [d], e: f\\n é \u{1F600}"}"#)
    }

    @Test("Indent is configurable", arguments: [
        (JSONFormatter.Indent.spaces(4), "{\n    \"a\": 1\n}"),
        (JSONFormatter.Indent.tab, "{\n\t\"a\": 1\n}"),
        (JSONFormatter.Indent.spaces(0), "{\n\"a\": 1\n}"),
    ])
    func configurableIndent(indent: JSONFormatter.Indent, expected: String) {
        #expect(JSONFormatter(indent: indent).prettyPrint(#"{"a":1}"#) == expected)
    }

    @Test("Empty containers print as {} and []")
    func emptyContainers() {
        #expect(formatter.prettyPrint(#"{"a": { }, "b": [ ]}"#) == "{\n  \"a\": {},\n  \"b\": []\n}")
        #expect(formatter.prettyPrint("{}") == "{}")
    }

    @Test("Minify removes insignificant whitespace")
    func minifies() {
        let input = "{\n  \"a\" : [ 1 , 2 ],\n  \"b\" : \"x y\"\n}\n"
        #expect(formatter.minify(input) == #"{"a":[1,2],"b":"x y"}"#)
    }

    @Test("Formatting is idempotent and minify inverts pretty-print")
    func idempotent() {
        let input = generatedJSON(approximateBytes: 5_000)
        let pretty = formatter.prettyPrint(input)
        #expect(formatter.prettyPrint(pretty) == pretty)
        let minified = formatter.minify(input)
        #expect(formatter.minify(pretty) == minified)
        #expect(formatter.minify(minified) == minified)
    }

    @Test("Pretty output parses to the same value as the input")
    func sameValue() throws {
        let input = generatedJSON(approximateBytes: 2_000)
        let original = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSArray
        let formatted = try JSONSerialization.jsonObject(with: Data(formatter.prettyPrint(input).utf8)) as? NSArray
        #expect(original == formatted)
    }

    @Test("Truncated JSON is still formatted as far as it goes")
    func truncatedInput() {
        #expect(formatter.prettyPrint(#"{"a": 1, "b": [1, 2"#) == "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2")
    }

    @Test("A trailing comma does not leave an empty indented line")
    func trailingComma() {
        #expect(formatter.prettyPrint("[1,]") == "[\n  1,\n]")
    }

    @Test("Whitespace between two scalars is kept as one space")
    func separatedScalars() {
        #expect(formatter.minify("[1   2]") == "[1 2]")
        #expect(formatter.minify(#"["a" "b"]"#) == #"["a" "b"]"#)
    }

    @Test("Extra closers do not underflow the indent")
    func extraClosers() {
        #expect(formatter.prettyPrint("]]{}") == "]\n]{}")
    }

    @Test("Garbage never loses characters other than whitespace", arguments: [UInt64(3), 11, 99])
    func neverDropsCharacters(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let alphabet = Array("{}[],: \n\t1ab-.\u{E9}")
        for _ in 0..<200 {
            let input = String((0..<Int.random(in: 0...60, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let significant = input.filter { !$0.isWhitespace }
            #expect(formatter.prettyPrint(input).filter { !$0.isWhitespace } == significant)
            #expect(formatter.minify(input).filter { !$0.isWhitespace } == significant)
        }
    }
}
