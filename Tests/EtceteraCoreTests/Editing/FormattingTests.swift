import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Formatting and large values in the editor", .tags(.unit))
struct FormattingTests {
    let transport = MockTransport()
    let value = ValueModel()
    let key = Data("k".utf8)

    private func loaded(_ data: Data) async throws -> ConnectionModel {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: data)]))
        await value.load(key: key, from: connection)
        return connection
    }

    @Test("Format pretty-prints the buffer and keeps key order")
    func format() async throws {
        _ = try await loaded(Data(#"{"b":1,"a":[2]}"#.utf8))
        value.formatJSON()
        #expect(value.text.contains("\n"))
        let b = try #require(value.text.range(of: "\"b\""))
        let a = try #require(value.text.range(of: "\"a\""))
        #expect(b.lowerBound < a.lowerBound)
        #expect(value.isDirty)
    }

    @Test("Minify is the inverse of format")
    func minify() async throws {
        _ = try await loaded(Data(#"{"b":1,"a":[2]}"#.utf8))
        value.formatJSON()
        value.minifyJSON()
        #expect(value.text == #"{"b":1,"a":[2]}"#)
        #expect(!value.isDirty)
    }

    @Test("Formatting a read-only value does nothing")
    func readOnly() async throws {
        _ = try await loaded(Data([0xFF]))
        value.formatJSON()
        #expect(value.text.isEmpty)
    }

    @Test("A value above 5 MB opens read-only and loads into the editor only on request")
    func largeValue() async throws {
        let large = Data(repeating: UInt8(ascii: "a"), count: ValueModel.hexThreshold + 1)
        _ = try await loaded(large)
        #expect(value.isLarge)
        #expect(!value.isEditable)
        value.openInEditor()
        #expect(value.isEditable)
        #expect(value.format == .text)
    }
}
