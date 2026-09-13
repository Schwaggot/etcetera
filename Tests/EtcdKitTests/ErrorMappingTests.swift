import Foundation
import Testing

@testable import EtcdKit

@Suite("Gateway error mapping", .tags(.unit))
struct ErrorMappingTests {
    @Test("Code 16 maps to unauthenticated")
    func unauthenticated() {
        let body = Data(
            "{\"error\": \"etcdserver: invalid auth token\", \"code\": 16, \"message\": \"etcdserver: invalid auth token\"}"
                .utf8)
        let error = GatewayErrorMapper.error(status: 401, body: body)
        guard case EtcdError.unauthenticated = error else {
            Issue.record("expected unauthenticated, got \(error)")
            return
        }
    }

    @Test("Code 7 maps to permissionDenied")
    func permissionDenied() {
        let body = Data("{\"error\": \"etcdserver: permission denied\", \"code\": 7}".utf8)
        let error = GatewayErrorMapper.error(status: 403, body: body)
        guard case EtcdError.permissionDenied = error else {
            Issue.record("expected permissionDenied, got \(error)")
            return
        }
    }

    @Test("Other codes keep the server's message verbatim")
    func statusKeepsMessage() {
        let body = Data(
            "{\"error\": \"etcdserver: mvcc: required revision has been compacted\", \"code\": 11}".utf8)
        let error = GatewayErrorMapper.error(status: 400, body: body)
        guard case EtcdError.status(let code, let message) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(code == .outOfRange)
        #expect(message == "etcdserver: mvcc: required revision has been compacted")
    }

    @Test("An unknown numeric code does not crash the mapping")
    func unknownCode() {
        let body = Data("{\"error\": \"weird\", \"code\": 99}".utf8)
        let error = GatewayErrorMapper.error(status: 500, body: body)
        guard case EtcdError.status(let code, _) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(code == .unknown)
    }

    @Test("A non-JSON body surfaces the raw HTTP status for probing")
    func rawHTTPStatus() {
        let error = GatewayErrorMapper.error(status: 404, body: Data("404 page not found".utf8))
        guard let httpError = error as? HTTPStatusError else {
            Issue.record("expected HTTPStatusError, got \(error)")
            return
        }
        #expect(httpError.status == 404)
    }

    @Test("A bare 401 without a gateway body maps to unauthenticated, so re-auth still runs")
    func bare401() {
        let error = GatewayErrorMapper.error(status: 401, body: Data("Unauthorized".utf8))
        guard case EtcdError.unauthenticated = error else {
            Issue.record("expected unauthenticated, got \(error)")
            return
        }
    }

    @Test("A bare 403 without a gateway body maps to permissionDenied")
    func bare403() {
        let error = GatewayErrorMapper.error(status: 403, body: Data("Forbidden".utf8))
        guard case EtcdError.permissionDenied = error else {
            Issue.record("expected permissionDenied, got \(error)")
            return
        }
    }

    @Test("A raw proxy status after connect surfaces as an EtcdError, not an HTTP error")
    func rawStatusBecomesEtcdError() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", json: "{\"etcdserver\": \"3.5.21\"}")
        let client = try await EtcdClient(
            configuration: .init(endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        transport.enqueue(
            path: "/v3/kv/range",
            error: GatewayErrorMapper.error(status: 502, body: Data("<html>Bad Gateway</html>".utf8)))
        do {
            _ = try await client.range(RangeRequest(key: Data("k".utf8)))
            Issue.record("expected an error")
        } catch EtcdError.status(let code, let message) {
            #expect(code == .unavailable)
            #expect(message.contains("502"))
        }
    }

    @Test("gatewayUnavailable explains itself in plain words")
    func gatewayUnavailableMessage() {
        let message = EtcdError.gatewayUnavailable.errorDescription ?? ""
        #expect(message.contains("JSON gateway"))
        #expect(message.contains("cannot connect"))
    }
}
