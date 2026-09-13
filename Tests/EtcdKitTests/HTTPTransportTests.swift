import Foundation
import Testing

@testable import EtcdKit

@Suite("HTTP requests", .tags(.unit))
struct HTTPTransportTests {
    @Test("The token travels bare in both headers the gateways read")
    func tokenHeaders() async throws {
        let transport = try HTTPTransport(endpoint: URL(string: "http://localhost:2379")!)
        await transport.setAuthToken("abc.22")
        let request = transport.request(path: "/v3/kv/range", method: "POST", body: Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "abc.22")
        #expect(request.value(forHTTPHeaderField: "Grpc-Metadata-Token") == "abc.22")
    }

    @Test("The watch request stays open for an hour, not the 60 second request default")
    func watchRequestTimeout() throws {
        let transport = try HTTPTransport(endpoint: URL(string: "http://localhost:2379")!)
        let request = transport.streamRequest(path: "/v3/watch", body: Data("{}".utf8))
        #expect(request.timeoutInterval == 3600)
        #expect(request.httpMethod == "POST")
    }

    @Test("Without a token no auth header is sent")
    func noToken() throws {
        let transport = try HTTPTransport(endpoint: URL(string: "http://localhost:2379")!)
        let request = transport.request(path: "/version", method: "GET", body: nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Grpc-Metadata-Token") == nil)
        #expect(request.url?.absoluteString == "http://localhost:2379/version")
    }
}
