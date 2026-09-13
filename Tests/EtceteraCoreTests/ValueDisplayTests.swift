import Foundation
import Testing

@testable import EtceteraCore

@Suite("Value format guess and byte display", .tags(.unit))
struct ValueDisplayTests {
    @Test("The format guess picks JSON, then text, then hex",
        arguments: [
            (Data(#"{"a": 1}"#.utf8), ValueFormat.json),
            (Data("42".utf8), .json),
            (Data("hello".utf8), .text),
            (Data(), .text),
            (Data([0xFF, 0xFE]), .hex),
        ])
    func guess(data: Data, expected: ValueFormat) {
        #expect(ValueFormat.guess(for: data) == expected)
    }

    @Test("Hex dump lines carry an offset, padded hex, and an ASCII gutter")
    func hexDump() {
        let lines = HexDump.render(Data("ABC\n".utf8) + Data(repeating: 0x41, count: 13)).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00000000  41 42 43 0A 41"))
        #expect(lines[0].hasSuffix("|ABC.AAAAAAAAAAAA|"))
        #expect(lines[1] == "00000010  41" + String(repeating: " ", count: 45) + "  |A|")
    }

    @Test("Bytes that are not UTF-8 display as \\xNN escapes, backslash included")
    func escapes() {
        #expect(displayString(for: Data("/config/app".utf8)) == "/config/app")
        #expect(displayString(for: Data([0x61, 0xFF, 0x5C])) == "a\\xFF\\x5C")
    }
}
