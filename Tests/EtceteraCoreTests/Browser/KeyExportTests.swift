import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Exporting keys", .tags(.unit))
struct KeyExportTests {
    let transport = MockTransport()

    @Test(
        "Key segments become file names that stay visible and unambiguous",
        arguments: [
            ("x", "x"), ("", "%00"), (".", "%2E"), ("..", "%2E."), (".env", "%2Eenv"),
            ("a/b", "a%2Fb"), ("50%", "50%25"), ("%00", "%2500"),
        ])
    func fileNames(segment: String, expected: String) {
        #expect(exportFileName(segment) == expected)
    }

    @Test("A key's file sits in one directory per segment below the exported folder")
    func paths() {
        let path = exportPath(
            for: Data("/app/svc/a/b".utf8), under: Data("/app/svc/".utf8), separator: "/", format: .json)
        #expect(path == ["a", "b.json"])
        let colon = exportPath(for: Data("svc:db/x".utf8), under: Data("svc:".utf8), separator: ":", format: .text)
        #expect(colon == ["db%2Fx.txt"])
    }

    @Test("JSON keeps a JSON value's key order, and wraps text and binary as JSON strings")
    func jsonContents() throws {
        let connection = ConnectionModel()
        let key = Data("a".utf8)
        let pretty = String(
            decoding: connection.exportContents(of: Data(#"{"b":1,"a":2}"#.utf8), key: key, as: .json), as: UTF8.self)
        #expect(pretty.contains("\n"))
        let b = try #require(pretty.range(of: #""b": 1"#))
        let a = try #require(pretty.range(of: #""a": 2"#))
        #expect(b.lowerBound < a.lowerBound)
        #expect(connection.exportContents(of: Data("hello/x".utf8), key: key, as: .json) == Data(#""hello/x""#.utf8))
        #expect(connection.exportContents(of: Data([0x08, 0x96]), key: key, as: .json) == Data(#""0896""#.utf8))
    }

    @Test("Text is the value as Copy Value gives it; raw is the bytes")
    func textAndRaw() {
        let connection = ConnectionModel()
        let key = Data("a".utf8)
        #expect(connection.exportContents(of: Data("hello".utf8), key: key, as: .text) == Data("hello".utf8))
        #expect(connection.exportContents(of: Data([0x08, 0x96]), key: key, as: .text) == Data("0896".utf8))
        #expect(connection.exportContents(of: Data([0x08, 0x96]), key: key, as: .raw) == Data([0x08, 0x96]))
    }

    @Test("A folder export has a file for every key below it, and names the ones too large to read")
    func subtree() async throws {
        let connection = try await connectedModel(transport)
        let tooLarge = EtcdError.status(
            code: .resourceExhausted, message: "grpc: received message larger than max (69274661 vs. 4194304)")
        for _ in 0..<6 {
            transport.enqueue(path: "/v3/kv/range", error: tooLarge)
        }
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a/big"], more: true))
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([Gateway.kv("a/x", value: "1"), Gateway.kv("a/y/z", value: #"{"k":true}"#)]))
        let export = try await connection.exportSubtree(prefix: "a/", as: .json)
        #expect(export.files.map(\.path) == [["x.json"], ["y", "z.json"]])
        #expect(export.files.first?.contents == Data("1".utf8))
        #expect(export.skipped == [Data("a/big".utf8)])
    }

    @Test("Exporting a key deleted meanwhile says so")
    func keyGone() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await #expect(throws: KeyNotFoundError.self) {
            try await connection.exportKey(Data("a".utf8), as: .json)
        }
    }
}
