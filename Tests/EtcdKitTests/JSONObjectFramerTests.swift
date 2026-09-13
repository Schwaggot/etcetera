import Foundation
import Testing

@testable import EtcdKit

@Suite("Framing streamed JSON values", .tags(.unit))
struct JSONObjectFramerTests {
    private func frame(_ chunks: [String]) -> [String] {
        var framer = JSONObjectFramer()
        return chunks.flatMap { framer.append(contentsOf: Array($0.utf8)) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Newline-delimited values, as newer gateways send them")
    func newlineDelimited() {
        #expect(frame(["{\"a\":1}\n{\"b\":2}\n"]) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test("Concatenated values with no separator, as etcd 3.2 sends them")
    func concatenated() {
        #expect(frame([#"{"result":{"created":true}}{"result":{"events":[]}}"#])
            == [#"{"result":{"created":true}}"#, #"{"result":{"events":[]}}"#])
    }

    @Test("A value split across chunks is yielded once it closes")
    func splitAcrossChunks() {
        #expect(frame([#"{"res"#, #"ult":{"x""#, #":[1,2]}}"#]) == [#"{"result":{"x":[1,2]}}"#])
    }

    @Test("Braces and escaped quotes inside strings do not end a value")
    func bracesInStrings() {
        let value = #"{"message":"a } \" { ] [ \\","n":1}"#
        #expect(frame([value + value]) == [value, value])
    }

    @Test("An unfinished value yields nothing")
    func unfinished() {
        #expect(frame([#"{"a":{"b":1}"#]).isEmpty)
    }
}
