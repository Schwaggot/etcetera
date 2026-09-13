import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Copying keys and values", .tags(.unit))
struct KeyClipboardTests {
    let transport = MockTransport()

    @Test(
        "A key splits into prefix and name at its last separator",
        arguments: [
            ("/app/svc/x", "/", "/app/svc/", "x"),
            ("a", "/", "", "a"),
            ("a/", "/", "a/", ""),
            ("/a", "/", "/", "a"),
            ("svc:db:host", ":", "svc:db:", "host"),
        ])
    func parts(key: String, separator: String, prefix: String, name: String) {
        let parts = KeyParts(Data(key.utf8), separator: Character(separator))
        #expect(parts.full == key)
        #expect(parts.prefix == prefix)
        #expect(parts.name == name)
    }

    @Test("Non-UTF-8 key bytes copy as the escapes the table shows")
    func nonUTF8Key() {
        let parts = KeyParts(Data([0x61, 0x2F, 0xFF]), separator: "/")
        #expect(parts.full == "a/\\xFF")
        #expect(parts.name == "\\xFF")
    }

    @Test("Text values copy as text, binary values as hex")
    func valueText() {
        #expect(clipboardText(for: Data(#"{"a": 1}"#.utf8)) == #"{"a": 1}"#)
        #expect(clipboardText(for: Data([0x08, 0x96, 0x01])) == "089601")
    }

    @Test("Copying a value reads the key's current value")
    func clipboardValue() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv("a", value: "hello")]))
        #expect(try await connection.clipboardValue(forKey: Data("a".utf8)) == "hello")
        #expect(Gateway.rangeBodies(transport).last?["key"] as? String == Gateway.base64("a"))
    }

    @Test("Copying the value of a key deleted meanwhile says so")
    func clipboardValueGone() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await #expect(throws: KeyNotFoundError.self) {
            try await connection.clipboardValue(forKey: Data("a".utf8))
        }
    }
}
