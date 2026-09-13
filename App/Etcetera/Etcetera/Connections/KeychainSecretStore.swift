//
//  KeychainSecretStore.swift
//  Etcetera
//

import EtceteraCore
import Foundation
import Security

/// Secrets as generic password items in the Keychain, one per profile and
/// kind. EtcdKit never sees the Keychain; secrets reach it as values.
/// See SPEC 3.2 and 4.6.
struct KeychainSecretStore: SecretStore {
    private let service = "etcetera"

    func secret(_ kind: SecretKind, for profileID: String) -> String? {
        var query = baseQuery(kind, profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Asks for the item alone, which needs no access prompt.
    func hasSecret(_ kind: SecretKind, for profileID: String) -> Bool {
        var query = baseQuery(kind, profileID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setSecret(_ value: String?, _ kind: SecretKind, for profileID: String) throws {
        let query = baseQuery(kind, profileID)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ kind: SecretKind, _ profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(profileID).\(kind.rawValue)",
        ]
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        // The status as String, so it is not digit-grouped.
        (SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "Keychain error \(String(status))")
    }
}

/// Unsaved edits from the connection editor over the stored secrets, so
/// Test runs with what the user typed.
struct OverlaySecretStore: SecretStore {
    let base: any SecretStore
    let overrides: [SecretKind: String]

    func secret(_ kind: SecretKind, for profileID: String) -> String? {
        overrides[kind] ?? base.secret(kind, for: profileID)
    }

    func hasSecret(_ kind: SecretKind, for profileID: String) -> Bool {
        overrides[kind] != nil || base.hasSecret(kind, for: profileID)
    }

    func setSecret(_ value: String?, _ kind: SecretKind, for profileID: String) throws {}
}
