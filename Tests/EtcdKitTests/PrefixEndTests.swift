import Foundation
import Testing

@testable import EtcdKit

@Suite("Prefix range end", .tags(.unit))
struct PrefixEndTests {
    @Test("Increments the last byte",
        arguments: [
            ([0x61], [0x62]),  // "a" -> "b"
            ([0x2F, 0x63, 0x6F, 0x6E, 0x66], [0x2F, 0x63, 0x6F, 0x6E, 0x67]),  // "/conf" -> "/cong"
        ] as [([UInt8], [UInt8])])
    func incrementsLastByte(key: [UInt8], expected: [UInt8]) {
        #expect(prefixEnd(key) == expected)
    }

    @Test("Carries past trailing 0xFF bytes")
    func carriesPastFF() {
        #expect(prefixEnd([0x61, 0xFF]) == [0x62])
        #expect(prefixEnd([0x61, 0xFF, 0xFF]) == [0x62])
        #expect(prefixEnd([0x61, 0x62, 0xFF]) == [0x61, 0x63])
    }

    @Test("A prefix of all 0xFF scans to the end of the keyspace")
    func allFF() {
        #expect(prefixEnd([0xFF]) == [0])
        #expect(prefixEnd([0xFF, 0xFF]) == [0])
    }

    @Test("The empty prefix maps to the whole keyspace, not an empty range")
    func emptyPrefix() {
        #expect(prefixEnd([] as [UInt8]) == [0])
        #expect(prefixStart(Data()) == Data([0]))
    }

    @Test("A non-empty prefix starts the scan at itself")
    func nonEmptyStart() {
        #expect(prefixStart(Data("/config".utf8)) == Data("/config".utf8))
    }
}
