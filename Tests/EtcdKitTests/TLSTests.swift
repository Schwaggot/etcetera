import Foundation
import Testing

@testable import EtcdKit

@Suite("TLS configuration", .tags(.unit))
struct TLSTests {
    /// A throwaway self-signed CA; its private key was discarded.
    static let pem = """
        -----BEGIN CERTIFICATE-----
        MIIBjjCCATOgAwIBAgIUYGj5igwVQGys9JvXSE2e6hcWzwYwCgYIKoZIzj0EAwIw
        GzEZMBcGA1UEAwwQZXRjZXRlcmEgdGVzdCBDQTAgFw0yNjA5MTMwNzM5MDJaGA8y
        MTI2MDgyMDA3MzkwMlowGzEZMBcGA1UEAwwQZXRjZXRlcmEgdGVzdCBDQTBZMBMG
        ByqGSM49AgEGCCqGSM49AwEHA0IABEoS8LCYlua+awYUCyMJPlDhopHZDm7lRs3I
        2Uk8i0JPgqe33fC/2RzFxZTOpp6naM96apCatw6+6jIbodhFRrmjUzBRMB0GA1Ud
        DgQWBBRu85wjyesNOl7Kp2s9GOWBMf+C/zAfBgNVHSMEGDAWgBRu85wjyesNOl7K
        p2s9GOWBMf+C/zAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDY
        6pstYSsyssXz8zvefDhXNLCVz//Ts4D3vWVZTsCFXAIhAIWGZchtyB5iIkQbbESE
        h9aGIrGwb9O8jiPKpWNqu3FR
        -----END CERTIFICATE-----

        """

    static var der: Data {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)!
    }

    @Test("A custom CA loads from DER and from PEM")
    func rootFormats() throws {
        #expect(try HTTPTransport.rootCertificates(from: [Self.der]).count == 1)
        #expect(try HTTPTransport.rootCertificates(from: [Data(Self.pem.utf8)]).count == 1)
    }

    @Test("A PEM bundle yields every certificate in it")
    func pemBundle() throws {
        let bundle = Data((Self.pem + Self.pem).utf8)
        #expect(try HTTPTransport.rootCertificates(from: [bundle]).count == 2)
    }

    @Test("Unreadable CA data is rejected when the transport is built, not silently dropped")
    func unreadableRoot() {
        #expect {
            _ = try HTTPTransport(
                endpoint: URL(string: "https://localhost:2379")!,
                tls: TLSConfiguration(customRootCertificates: [Data("not a certificate".utf8)]))
        } throws: { error in
            guard case EtcdError.tls(.invalidRootCertificate) = error else { return false }
            return true
        }
    }

    @Test("A connection cancelled by a failed CA check reports a TLS error with the reason")
    func failedTrustIsTLS() {
        let error = HTTPTransport.mapTransportError(URLError(.cancelled), trustFailure: "certificate is not trusted")
        guard case EtcdError.tls(.untrustedServerCertificate(let reason)) = error else {
            Issue.record("expected a TLS error, got \(error)")
            return
        }
        #expect(reason.contains("not trusted"))
    }

    @Test("A cancellation without a trust failure stays a transport error")
    func plainCancellation() {
        let error = HTTPTransport.mapTransportError(URLError(.cancelled), trustFailure: nil)
        guard case EtcdError.transport = error else {
            Issue.record("expected a transport error, got \(error)")
            return
        }
    }
}
