import Foundation
import Observation

/// Profiles as JSON in one file, by default under Application Support.
public struct ProfileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Etcetera")
    }

    var file: URL { directory.appending(path: "profiles.json") }

    /// No file means no profiles. A newer version's file is refused, so a
    /// save never drops what this version does not know.
    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let saved = try JSONDecoder().decode(ProfilesFile.self, from: Data(contentsOf: file))
        guard saved.version <= 1 else { throw NewerProfilesError() }
        return saved.profiles
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ProfilesFile(version: 1, profiles: profiles)).write(to: file, options: .atomic)
    }
}

struct ProfilesFile: Codable {
    var version: Int
    var profiles: [ConnectionProfile]
}

public struct NewerProfilesError: Error, LocalizedError, Sendable {
    public var errorDescription: String? {
        String(localized: "They were saved by a newer version of etcetera.", bundle: .module)
    }
}

public struct UnreadableProfilesError: Error, LocalizedError, Sendable {
    public var errorDescription: String? {
        String(localized: "The saved connections could not be read, so they are left untouched.", bundle: .module)
    }
}

/// The saved connections and their secrets. See SPEC 4.6.
@MainActor
@Observable
public final class ProfilesModel {
    public private(set) var profiles: [ConnectionProfile] = []
    /// Set when the file exists but cannot be read; saving is refused so
    /// the file is never overwritten.
    public private(set) var loadError: String?
    public let secrets: any SecretStore
    private let store: ProfileStore
    private let makeID: @Sendable () -> String

    public init(
        store: ProfileStore, secrets: any SecretStore, makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.secrets = secrets
        self.makeID = makeID
    }

    public func load() {
        do {
            profiles = try store.load()
            loadError = nil
        } catch {
            profiles = []
            loadError = String(localized: "The saved connections could not be read: \(error.localizedDescription)", bundle: .module)
        }
    }

    public func profile(withID id: String) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    public func newProfile() -> ConnectionProfile {
        ConnectionProfile(id: makeID(), name: String(localized: "New Connection", bundle: .module, comment: "Default name of a new connection"), endpoint: "http://127.0.0.1:2379")
    }

    /// Inserts or replaces by id. A nil secret keeps the stored one; an
    /// empty one removes it.
    public func save(_ profile: ConnectionProfile, password: String?, passphrase: String?) throws {
        guard loadError == nil else { throw UnreadableProfilesError() }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try store.save(updated)
        profiles = updated
        if let password { try secrets.setSecret(password, .password, for: profile.id) }
        if let passphrase { try secrets.setSecret(passphrase, .pkcs12Passphrase, for: profile.id) }
    }

    /// Appends under a fresh id; a taken name gets a number, as Finder does with copies.
    @discardableResult
    public func importConnection(_ imported: ImportedConnection) throws -> ConnectionProfile {
        guard loadError == nil else { throw UnreadableProfilesError() }
        var profile = imported.profile
        profile.id = makeID()
        let names = Set(profiles.map(\.name))
        var number = 2
        while names.contains(profile.name) {
            profile.name = "\(imported.profile.name) \(number)"
            number += 1
        }
        let updated = profiles + [profile]
        try store.save(updated)
        profiles = updated
        return profile
    }

    public func delete(_ id: String) throws {
        guard loadError == nil else { throw UnreadableProfilesError() }
        let updated = profiles.filter { $0.id != id }
        try store.save(updated)
        profiles = updated
        try secrets.removeSecrets(for: id)
    }
}
