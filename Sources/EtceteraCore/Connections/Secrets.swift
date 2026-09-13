import Foundation
import Synchronization

public enum SecretKind: String, CaseIterable, Sendable {
    case password
    case pkcs12Passphrase
}

/// Where secrets live: the Keychain in the application, memory in tests.
/// Never profile JSON, never logs. See SPEC 6.9.
public protocol SecretStore: Sendable {
    func secret(_ kind: SecretKind, for profileID: String) -> String?
    /// Whether a secret is stored, without reading it.
    func hasSecret(_ kind: SecretKind, for profileID: String) -> Bool
    /// Nil or empty removes the secret.
    func setSecret(_ value: String?, _ kind: SecretKind, for profileID: String) throws
}

extension SecretStore {
    public func hasSecret(_ kind: SecretKind, for profileID: String) -> Bool {
        secret(kind, for: profileID) != nil
    }

    public func removeSecrets(for profileID: String) throws {
        for kind in SecretKind.allCases {
            try setSecret(nil, kind, for: profileID)
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: String]>([:])

    public init() {}

    public func secret(_ kind: SecretKind, for profileID: String) -> String? {
        storage.withLock { $0["\(profileID).\(kind.rawValue)"] }
    }

    public func setSecret(_ value: String?, _ kind: SecretKind, for profileID: String) throws {
        storage.withLock { $0["\(profileID).\(kind.rawValue)"] = value?.isEmpty == false ? value : nil }
    }
}

/// Reads files the user picked; security-scoped bookmarks in the application.
public protocol FileAccess: Sendable {
    func contents(of reference: FileReference) throws -> Data
}

/// For connections without file references.
public struct NoFileAccess: FileAccess {
    public init() {}

    public func contents(of reference: FileReference) throws -> Data {
        throw CocoaError(.fileReadNoPermission)
    }
}
