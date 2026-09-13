import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Connecting with a profile", .tags(.unit))
struct ConnectionSetupTests {
    let transport = MockTransport()
    let secrets = InMemorySecretStore()
    let files = FakeFileAccess()

    private func profile() -> ConnectionProfile {
        ConnectionProfile(id: "p1", name: "test", endpoint: "http://127.0.0.1:2379", watchEnabled: false)
    }

    private func model() -> ConnectionModel {
        ConnectionModel(transport: transport, secrets: secrets, files: files)
    }

    private func gatewayOff() {
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        for prefix in ["/v3", "/v3beta", "/v3alpha"] {
            transport.enqueue(path: "\(prefix)/maintenance/status", error: HTTPStatusError(status: 404, body: Data()))
        }
    }

    @Test("A pinned prefix from the profile skips probing")
    func pinnedPrefix() async {
        var profile = profile()
        profile.pinnedPrefix = "/v3beta"
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotConnectToHost)))
        transport.enqueue(path: "/v3beta/kv/range", json: Gateway.range([]))
        let model = model()
        await model.connect(to: profile)
        #expect(model.phase == .connected)
        #expect(transport.requests.map(\.path) == ["/version", "/v3beta/kv/range"])
    }

    @Test("A profile with a username authenticates with the stored password before browsing")
    func authenticates() async throws {
        var profile = profile()
        profile.username = "root"
        try secrets.setSecret("hunter2", .password, for: "p1")
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "t"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        let model = model()
        await model.connect(to: profile)
        #expect(model.phase == .connected)
        #expect(transport.requests.map(\.path) == ["/version", "/v3/auth/authenticate", "/v3/kv/range"])
        let body = try #require(transport.requests(for: "/v3/auth/authenticate").first?.json)
        #expect(body["name"] as? String == "root")
        #expect(body["password"] as? String == "hunter2")
    }

    @Test("The profile's separator and endpoint are applied on connect")
    func appliesProfile() async {
        var profile = profile()
        profile.separator = ":"
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range(keys: ["a:b"]))
        let model = model()
        await model.connect(to: profile)
        #expect(model.separator == ":")
        #expect(model.profile?.id == "p1")
        #expect(model.root.children?.map(\.name) == ["a"])
    }

    @Test("The CA certificate is read through its file reference")
    func caFromReference() throws {
        var profile = profile()
        profile.tls.caCertificate = FileReference(bookmark: Data("ca".utf8), displayName: "ca.pem")
        files.files[Data("ca".utf8)] = Data("PEM DATA".utf8)
        let tls = try ConnectionSetup.tlsConfiguration(for: profile, secrets: secrets, files: files)
        #expect(tls.customRootCertificates == [Data("PEM DATA".utf8)])
        #expect(!tls.skipServerVerification)
    }

    @Test("The PKCS#12 bundle is read by reference and its passphrase comes from the secret store")
    func clientIdentity() throws {
        var profile = profile()
        profile.tls.clientIdentity = FileReference(bookmark: Data("p12".utf8), displayName: "client.p12")
        profile.tls.skipServerVerification = true
        files.files[Data("p12".utf8)] = Data([1, 2, 3])
        try secrets.setSecret("pass", .pkcs12Passphrase, for: "p1")
        let tls = try ConnectionSetup.tlsConfiguration(for: profile, secrets: secrets, files: files)
        #expect(tls.clientIdentity?.blob == Data([1, 2, 3]))
        #expect(tls.clientIdentity?.passphrase == "pass")
        #expect(tls.skipServerVerification)
    }

    @Test("Skipping verification is visible on the connection, for the window warning")
    func skipVerificationVisible() async {
        var profile = profile()
        profile.tls.skipServerVerification = true
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        let model = model()
        await model.connect(to: profile)
        #expect(model.skipsServerVerification)
        model.disconnect()
        #expect(!model.skipsServerVerification)
    }

    @Test("The test reports every step and stops at the first failure")
    func testStopsAtFirstFailure() async {
        gatewayOff()
        let report = await ConnectionSetup.test(profile(), secrets: secrets, files: files, transport: transport)
        #expect(report.results.map(\.step) == ConnectionStep.allCases)
        #expect(report.outcome(for: .certificates) == .skipped)
        guard case .failed(let message) = report.outcome(for: .connect) else {
            Issue.record("expected the connect step to fail, got \(String(describing: report.outcome(for: .connect)))")
            return
        }
        #expect(message.contains("JSON gateway"))
        #expect(report.outcome(for: .authenticate) == .skipped)
        #expect(report.outcome(for: .status) == .skipped)
        #expect(report.failedStep == .connect)
    }

    @Test("An unreadable CA file fails the certificate step")
    func unreadableCA() async {
        var profile = profile()
        profile.tls.caCertificate = FileReference(bookmark: Data("gone".utf8), displayName: "ca.pem")
        let report = await ConnectionSetup.test(profile, secrets: secrets, files: files, transport: transport)
        #expect(report.failedStep == .certificates)
        #expect(transport.requests.isEmpty)
    }

    @Test("A rejected password fails the authenticate step")
    func rejectedPassword() async throws {
        var profile = profile()
        profile.username = "root"
        try secrets.setSecret("wrong", .password, for: "p1")
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(
            path: "/v3/auth/authenticate",
            error: EtcdError.status(code: .invalidArgument, message: "etcdserver: authentication failed"))
        let report = await ConnectionSetup.test(profile, secrets: secrets, files: files, transport: transport)
        #expect(report.failedStep == .authenticate)
        #expect(report.outcome(for: .status) == .skipped)
    }

    @Test("A passing test names the server version and reads cluster status")
    func passing() async {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/maintenance/status", json: #"{"version": "3.5.21", "dbSize": "4096"}"#)
        let report = await ConnectionSetup.test(profile(), secrets: secrets, files: files, transport: transport)
        #expect(report.failedStep == nil)
        guard case .passed(let detail) = report.outcome(for: .connect) else {
            Issue.record("expected the connect step to pass")
            return
        }
        #expect(detail.contains("3.5.21"))
        guard case .passed = report.outcome(for: .status) else {
            Issue.record("expected the status step to pass")
            return
        }
    }
}
