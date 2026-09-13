import Foundation
import Testing

@testable import EtceteraCore

@Suite("Hex strings", .tags(.unit))
struct HexStringTests {
    @Test("Every byte becomes two uppercase digits, without separators")
    func digits() {
        #expect(hexString(Data()) == "")
        #expect(hexString(Data([0x00, 0x0A, 0x7F, 0xFF])) == "000A7FFF")
    }
}
