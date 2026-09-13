import EtcdSchema
import Foundation
import Testing

@testable import EtceteraCore

// A connection moves between Macs as JSON. Bookmarks only work on the Mac and
// app that made them, and secrets stay in the Keychain, so neither travels.

@MainActor
@Suite("Connection import and export", .tags(.unit))
struct ConnectionTransferTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func model() -> ProfilesModel {
        ProfilesModel(store: ProfileStore(directory: directory.url), secrets: InMemorySecretStore())
    }

    private func full(id: String = "p1", name: String = "prod") -> ConnectionProfile {
        ConnectionProfile(
            id: id, name: name, endpoint: "https://etcd:2379", separator: ":", pinnedPrefix: "/v3beta",
            username: "root",
            tls: .init(
                caCertificate: FileReference(bookmark: Data("ca-bookmark".utf8), displayName: "ca.pem"),
                clientIdentity: FileReference(bookmark: Data("id-bookmark".utf8), displayName: "me.p12"),
                skipServerVerification: true),
            watchEnabled: false,
            schema: SchemaSettings(
                source: FileReference(bookmark: Data("proto-bookmark".utf8), displayName: "protos"),
                mappings: [SchemaMappingRule(.prefix("cfg:"), message: "cfg.Config")]))
    }

    @Test("Export carries the settings but no id, bookmarks or secrets")
    func exportOmitsMachineState() throws {
        let json = try ConnectionTransfer.export(full(id: "id-7f3a"))
        #expect(json.contains("https://etcd:2379"))
        #expect(json.contains("cfg.Config"))
        #expect(json.contains("ca.pem"))
        #expect(!json.contains("\"id\""))
        #expect(!json.contains("id-7f3a"))
        for bookmark in ["ca-bookmark", "id-bookmark", "proto-bookmark"] {
            #expect(!json.contains(Data(bookmark.utf8).base64EncodedString()))
        }
    }

    @Test("An exported connection reads back with its settings and names the files to pick again")
    func roundTrip() throws {
        let connection = try ConnectionTransfer.parse(ConnectionTransfer.export(full()))
        let profile = connection.profile
        #expect(profile.name == "prod")
        #expect(profile.endpoint == "https://etcd:2379")
        #expect(profile.separator == ":")
        #expect(profile.pinnedPrefix == "/v3beta")
        #expect(profile.username == "root")
        #expect(profile.tls.skipServerVerification)
        #expect(profile.tls.caCertificate == nil && profile.tls.clientIdentity == nil)
        #expect(!profile.watchEnabled)
        #expect(profile.schema.source == nil)
        #expect(profile.schema.mappings == [SchemaMappingRule(.prefix("cfg:"), message: "cfg.Config")])
        #expect(connection.filesToReselect == ["CA certificate ca.pem", "Client identity me.p12", "Schema folder protos"])
    }

    @Test("A connection with only an endpoint takes the defaults")
    func minimal() throws {
        let connection = try ConnectionTransfer.parse(#"{"connection": {"endpoint": "http://a:2379"}}"#)
        #expect(connection.profile.name == "http://a:2379")
        #expect(connection.profile.separator == "/")
        #expect(connection.profile.watchEnabled)
        #expect(connection.filesToReselect == [])
    }

    @Test("A multi-character separator keeps the first character, the only one a connection uses")
    func separatorFirstCharacter() throws {
        let connection = try ConnectionTransfer.parse(
            #"{"connection": {"endpoint": "http://a:2379", "separator": "::x"}}"#)
        #expect(connection.profile.separator == ":")
    }

    @Test(
        "Unreadable, incomplete, newer or list-shaped input is refused",
        arguments: [
            "not json",
            #"{"connection": {"name": "no endpoint"}}"#,
            #"{"connection": {"endpoint": "  "}}"#,
            #"{"version": 2, "connection": {"endpoint": "http://a:2379"}}"#,
            #"{"connections": [{"endpoint": "http://a:2379"}]}"#,
        ])
    func refused(_ text: String) {
        #expect(throws: ConnectionImportError.self) { try ConnectionTransfer.parse(text) }
    }

    @Test("Importing adds the connection with a new id and a unique name and keeps the existing ones")
    func importAdds() throws {
        let profiles = model()
        try profiles.save(full(), password: nil, passphrase: nil)
        let imported = try ConnectionTransfer.parse(ConnectionTransfer.export(full()))
        let second = try profiles.importConnection(imported)
        let third = try profiles.importConnection(imported)

        #expect([second.name, third.name] == ["prod 2", "prod 3"])
        #expect(Set(["p1", second.id, third.id]).count == 3)
        let reloaded = model()
        reloaded.load()
        #expect(reloaded.profiles.map(\.name) == ["prod", "prod 2", "prod 3"])
    }

    @Test("Importing is refused while the saved connections are unreadable")
    func importRefusedWhenUnreadable() throws {
        let file = directory.url.appending(path: "profiles.json")
        try Data("garbage".utf8).write(to: file)
        let profiles = model()
        profiles.load()
        let imported = try ConnectionTransfer.parse(ConnectionTransfer.export(full()))
        #expect(throws: UnreadableProfilesError.self) { try profiles.importConnection(imported) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "garbage")
    }
}
