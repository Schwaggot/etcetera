import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Value loading", .tags(.unit))
struct ValueModelTests {
    let transport = MockTransport()
    let value = ValueModel()

    @Test("A JSON value loads with the JSON format guessed")
    func guessesJSON() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("k", value: #"{"a": 1}"#)]))
        await value.load(key: Data("k".utf8), from: connection)
        guard case .loaded(let kv) = value.state else {
            Issue.record("expected a loaded value, got \(value.state)")
            return
        }
        #expect(kv.keyString == "k")
        #expect(value.format == .json)
    }

    @Test("Values above 5 MB open in hex")
    func largeValuesOpenInHex() async throws {
        let connection = try await connectedModel(transport)
        let large = Data(repeating: UInt8(ascii: "a"), count: ValueModel.hexThreshold + 1)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(Data("k".utf8), value: large)]))
        await value.load(key: Data("k".utf8), from: connection)
        #expect(value.format == .hex)
    }

    @Test("A key that does not exist is reported as missing")
    func missing() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await value.load(key: Data("k".utf8), from: connection)
        guard case .missing = value.state else {
            Issue.record("expected missing, got \(value.state)")
            return
        }
    }

    @Test("A read failure shows the error message")
    func failure() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.permissionDenied)
        await value.load(key: Data("k".utf8), from: connection)
        guard case .failed(let message) = value.state else {
            Issue.record("expected failure, got \(value.state)")
            return
        }
        #expect(message.contains("permission"))
    }

    @Test("A key that is not UTF-8 is read by its raw bytes")
    func rawKey() async throws {
        let connection = try await connectedModel(transport)
        let raw = Data([0x61, 0xFF])
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(raw)]))
        await value.load(key: raw, from: connection)
        let body = try #require(Gateway.rangeBodies(transport).last)
        #expect(body["key"] as? String == raw.base64EncodedString())
    }
}
