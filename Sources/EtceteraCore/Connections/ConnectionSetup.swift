import EtcdKit
import Foundation

/// The steps of opening a connection, in order. The Test button reports
/// which one failed. See SPEC 4.6.
public enum ConnectionStep: String, CaseIterable, Sendable {
    case certificates = "Read certificates"
    case connect = "Connect and detect the API version"
    case authenticate = "Authenticate"
    case status = "Read cluster status"

    public var title: String {
        switch self {
        case .certificates: String(localized: "Read certificates", bundle: .module, comment: "Connection test step")
        case .connect: String(localized: "Connect and detect the API version", bundle: .module, comment: "Connection test step")
        case .authenticate: String(localized: "Authenticate", bundle: .module, comment: "Connection test step")
        case .status: String(localized: "Read cluster status", bundle: .module, comment: "Connection test step")
        }
    }
}

public struct ConnectionStepError: Error, LocalizedError, Sendable {
    public let step: ConnectionStep
    public let message: String

    public var errorDescription: String? { message }
}

public struct ConnectionTestReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case passed(String)
        case failed(String)
        /// Not configured, or not reached after an earlier failure.
        case skipped
    }

    public struct StepResult: Equatable, Sendable {
        public var step: ConnectionStep
        public var outcome: Outcome
    }

    public var results: [StepResult]

    public func outcome(for step: ConnectionStep) -> Outcome? {
        results.first { $0.step == step }?.outcome
    }

    public var failedStep: ConnectionStep? {
        results.first {
            if case .failed = $0.outcome { return true }
            return false
        }?.step
    }
}

public enum ConnectionSetup {
    /// TLS settings with the referenced files read and the PKCS#12
    /// passphrase taken from the secret store.
    public static func tlsConfiguration(
        for profile: ConnectionProfile, secrets: any SecretStore, files: any FileAccess
    ) throws -> TLSConfiguration {
        var tls = TLSConfiguration(skipServerVerification: profile.tls.skipServerVerification)
        if let ca = profile.tls.caCertificate {
            tls.customRootCertificates = [try files.contents(of: ca)]
        }
        if let identity = profile.tls.clientIdentity {
            tls.clientIdentity = (try files.contents(of: identity), secrets.secret(.pkcs12Passphrase, for: profile.id) ?? "")
        }
        return tls
    }

    /// Opens an authenticated client. Throws `ConnectionStepError` naming the
    /// step that failed; `passed` hears each step that succeeded.
    static func open(
        _ profile: ConnectionProfile, secrets: any SecretStore, files: any FileAccess,
        transport: (any EtcdTransport)?, passed: (ConnectionStep, String) -> Void = { _, _ in }
    ) async throws -> EtcdClient {
        guard let url = URL(string: profile.endpoint), url.scheme != nil, url.host() != nil else {
            throw ConnectionStepError(step: .connect, message: String(localized: "Not a valid endpoint URL: \(profile.endpoint)", bundle: .module))
        }
        let tls: TLSConfiguration
        let resolved: any EtcdTransport
        do {
            tls = try tlsConfiguration(for: profile, secrets: secrets, files: files)
            resolved = try transport ?? HTTPTransport(endpoint: url, tls: tls)
        } catch {
            throw ConnectionStepError(step: .certificates, message: ConnectionModel.message(for: error))
        }
        if profile.tls.caCertificate != nil || profile.tls.clientIdentity != nil {
            passed(.certificates, String(localized: "Loaded", bundle: .module, comment: "Connection test result: certificates were read"))
        }

        let client: EtcdClient
        do {
            let pinned = profile.pinnedPrefix.flatMap { $0.isEmpty ? nil : $0 }
            client = try await EtcdClient(
                configuration: .init(endpoint: url, tls: tls, pinnedPrefix: pinned, transport: resolved))
        } catch {
            throw ConnectionStepError(step: .connect, message: ConnectionModel.message(for: error))
        }
        let prefix = client.apiPrefix
        if let version = client.serverVersion {
            passed(.connect, String(localized: "etcd \(version.description) at \(prefix)", bundle: .module))
        } else {
            passed(.connect, String(localized: "etcd, version unknown, at \(prefix)", bundle: .module))
        }

        if let username = profile.username, !username.isEmpty {
            do {
                try await client.authenticate(name: username, password: secrets.secret(.password, for: profile.id) ?? "")
            } catch {
                throw ConnectionStepError(step: .authenticate, message: ConnectionModel.message(for: error))
            }
            passed(.authenticate, String(localized: "Signed in as \(username)", bundle: .module))
        }
        return client
    }

    /// Runs every step and reports each outcome; steps after a failure are
    /// skipped.
    public static func test(
        _ profile: ConnectionProfile, secrets: any SecretStore, files: any FileAccess,
        transport: (any EtcdTransport)? = nil
    ) async -> ConnectionTestReport {
        var details: [ConnectionStep: String] = [:]
        var failure: ConnectionStepError?
        do {
            let client = try await open(profile, secrets: secrets, files: files, transport: transport) {
                details[$0] = $1
            }
            do {
                let status = try await client.status()
                let size = ByteCountFormatter.string(fromByteCount: status.dbSize, countStyle: .file)
                details[.status] = String(localized: "Database \(size), leader \(String(status.leader, radix: 16))", bundle: .module)
            } catch {
                failure = ConnectionStepError(step: .status, message: ConnectionModel.message(for: error))
            }
        } catch let error as ConnectionStepError {
            failure = error
        } catch {
            failure = ConnectionStepError(step: .connect, message: ConnectionModel.message(for: error))
        }
        return ConnectionTestReport(
            results: ConnectionStep.allCases.map { step in
                if let detail = details[step] {
                    return .init(step: step, outcome: .passed(detail))
                }
                if let failure, failure.step == step {
                    return .init(step: step, outcome: .failed(failure.message))
                }
                return .init(step: step, outcome: .skipped)
            })
    }
}
