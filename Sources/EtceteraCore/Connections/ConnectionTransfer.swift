import EtcdSchema
import Foundation

/// One connection as portable JSON. Its id, bookmarks and secrets stay
/// behind: bookmarks resolve only on the Mac and app that made them, and
/// secrets live in the Keychain. File names travel so the user knows what to
/// pick again.
public enum ConnectionTransfer {
    static let version = 1

    public static func export(_ profile: ConnectionProfile) throws -> String {
        let file = TransferFile(format: "etcetera-connection", version: version, connection: PortableConnection(profile))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(file), as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> ImportedConnection {
        let file: TransferFile
        do {
            file = try JSONDecoder().decode(TransferFile.self, from: Data(text.utf8))
        } catch {
            throw ConnectionImportError(reason: String(localized: "This is not an etcetera connection: \(detail(error))", bundle: .module))
        }
        if let written = file.version, written > version {
            throw ConnectionImportError(reason: String(localized: "The connection was exported by a newer version of etcetera.", bundle: .module))
        }
        return try file.connection.imported()
    }

    static func detail(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .dataCorrupted(let context)?, .keyNotFound(_, let context)?, .typeMismatch(_, let context)?,
            .valueNotFound(_, let context)?:
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
        default:
            return error.localizedDescription
        }
    }
}

/// A connection read from an export, not yet saved: its id is empty and it
/// has no file references.
public struct ImportedConnection: Hashable, Sendable {
    public let profile: ConnectionProfile
    /// Files the exporting Mac referenced, such as "CA certificate ca.pem".
    public let filesToReselect: [String]
}

public struct ConnectionImportError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
}

struct TransferFile: Codable {
    var format: String?
    var version: Int?
    var connection: PortableConnection
}

/// Flat and optional throughout, so hand-written files need only an endpoint.
struct PortableConnection: Codable {
    var name: String?
    var endpoint: String?
    var separator: String?
    var pinnedPrefix: String?
    var username: String?
    var watchEnabled: Bool?
    var skipServerVerification: Bool?
    var caCertificate: String?
    var clientIdentity: String?
    var schemaFolder: String?
    var schemaMappings: [SchemaMappingRule]?

    init(_ profile: ConnectionProfile) {
        name = profile.name
        endpoint = profile.endpoint
        separator = profile.separator
        pinnedPrefix = profile.pinnedPrefix
        username = profile.username
        watchEnabled = profile.watchEnabled
        skipServerVerification = profile.tls.skipServerVerification
        caCertificate = profile.tls.caCertificate?.displayName
        clientIdentity = profile.tls.clientIdentity?.displayName
        schemaFolder = profile.schema.source?.displayName
        schemaMappings = profile.schema.mappings.isEmpty ? nil : profile.schema.mappings
    }

    func imported() throws -> ImportedConnection {
        let endpoint = (endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            throw ConnectionImportError(reason: String(localized: "The connection has no endpoint.", bundle: .module))
        }
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ConnectionProfile(
            id: "", name: name.isEmpty ? endpoint : name, endpoint: endpoint,
            separator: separator?.first.map(String.init) ?? "/",
            pinnedPrefix: pinnedPrefix, username: username,
            tls: .init(skipServerVerification: skipServerVerification ?? false),
            watchEnabled: watchEnabled ?? true,
            schema: SchemaSettings(mappings: schemaMappings ?? []))
        let files = [
            caCertificate.map { String(localized: "CA certificate \($0)", bundle: .module) },
            clientIdentity.map { String(localized: "Client identity \($0)", bundle: .module) },
            schemaFolder.map { String(localized: "Schema folder \($0)", bundle: .module) },
        ]
        return ImportedConnection(profile: profile, filesToReselect: files.compactMap { $0 })
    }
}
