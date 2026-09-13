import Foundation
import Testing

@testable import EtceteraCore

// SPEC 4.6: profiles are JSON under Application Support; secrets live only
// in the secret store (the Keychain in the app).

@MainActor
@Suite("Connection profiles", .tags(.unit))
struct ProfilesModelTests {
    let directory: TemporaryDirectory
    let secrets = InMemorySecretStore()

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func model() -> ProfilesModel {
        ProfilesModel(store: ProfileStore(directory: directory.url), secrets: secrets, makeID: { "p1" })
    }

    private var file: URL { directory.url.appending(path: "profiles.json") }

    private func savedProfile(_ profiles: ProfilesModel) throws -> ConnectionProfile {
        var profile = profiles.newProfile()
        profile.name = "prod"
        profile.endpoint = "https://etcd:2379"
        profile.username = "root"
        try profiles.save(profile, password: "hunter2", passphrase: "p12-secret")
        return profile
    }

    @Test("Profiles persist as JSON and secrets only in the secret store")
    func persistence() throws {
        let profiles = model()
        let profile = try savedProfile(profiles)
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(json.contains("https:\\/\\/etcd:2379") || json.contains("https://etcd:2379"))
        #expect(!json.contains("hunter2"))
        #expect(!json.contains("p12-secret"))
        #expect(secrets.secret(.password, for: "p1") == "hunter2")
        #expect(secrets.secret(.pkcs12Passphrase, for: "p1") == "p12-secret")

        let reloaded = model()
        reloaded.load()
        #expect(reloaded.profiles == [profile])
    }

    @Test("Saving without a new secret keeps the stored one; an empty one clears it")
    func secretUpdates() throws {
        let profiles = model()
        var profile = try savedProfile(profiles)
        profile.name = "renamed"
        try profiles.save(profile, password: nil, passphrase: nil)
        #expect(secrets.secret(.password, for: "p1") == "hunter2")
        try profiles.save(profile, password: "", passphrase: nil)
        #expect(secrets.secret(.password, for: "p1") == nil)
        #expect(profiles.profiles.map(\.name) == ["renamed"])
    }

    @Test("Deleting a profile removes it and its secrets")
    func delete() throws {
        let profiles = model()
        _ = try savedProfile(profiles)
        try profiles.delete("p1")
        #expect(profiles.profiles.isEmpty)
        #expect(secrets.secret(.password, for: "p1") == nil)
        #expect(secrets.secret(.pkcs12Passphrase, for: "p1") == nil)
        let reloaded = model()
        reloaded.load()
        #expect(reloaded.profiles.isEmpty)
    }

    @Test("A missing profiles file means no profiles and no error")
    func missingFile() {
        let profiles = model()
        profiles.load()
        #expect(profiles.profiles.isEmpty)
        #expect(profiles.loadError == nil)
    }

    @Test("A corrupt profiles file is reported and never overwritten")
    func corruptFile() throws {
        try Data("garbage".utf8).write(to: file)
        let profiles = model()
        profiles.load()
        #expect(profiles.loadError != nil)
        #expect(throws: (any Error).self) {
            try profiles.save(profiles.newProfile(), password: nil, passphrase: nil)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "garbage")
    }

    @Test("A profiles file from a newer version is reported and never overwritten")
    func newerFile() throws {
        let newer = #"{"version": 2, "profiles": []}"#
        try Data(newer.utf8).write(to: file)
        let profiles = model()
        profiles.load()
        #expect(profiles.loadError != nil)
        #expect(throws: (any Error).self) {
            try profiles.save(profiles.newProfile(), password: nil, passphrase: nil)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == newer)
    }
}
