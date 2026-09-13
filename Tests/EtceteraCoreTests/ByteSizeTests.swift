import Foundation
import Testing

@testable import EtceteraCore

@Suite("Byte sizes", .tags(.unit))
struct ByteSizeTests {
    private let english = Locale(identifier: "en_US")

    @Test(
        "Whole bytes below 1 KB, then three significant digits in decimal units",
        arguments: [
            (0, "0 B"), (23, "23 B"), (999, "999 B"),
            (1000, "1 KB"), (1200, "1.2 KB"), (1234, "1.23 KB"), (23_456, "23.5 KB"), (234_567, "235 KB"),
            (2_450_000, "2.45 MB"), (4_194_304, "4.19 MB"), (13_026_036, "13 MB"),
            (1_500_000_000, "1.5 GB"),
        ])
    func formats(bytes: Int, expected: String) {
        #expect(formatByteSize(bytes, locale: english) == expected)
    }

    @Test("A value that rounds up to 1000 moves to the next unit")
    func roundingCarries() {
        #expect(formatByteSize(999_999, locale: english) == "1 MB")
        #expect(formatByteSize(999_499, locale: english) == "999 KB")
    }

    @Test("The decimal separator follows the locale")
    func localized() {
        #expect(formatByteSize(1200, locale: Locale(identifier: "de_DE")) == "1,2 KB")
    }
}
