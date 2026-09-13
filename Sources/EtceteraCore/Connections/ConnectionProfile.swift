import Foundation

/// A file the user picked, reached through a security-scoped bookmark and
/// never copied. See SPEC 6.9.
public struct FileReference: Codable, Hashable, Sendable {
    public var bookmark: Data
    public var displayName: String

    public init(bookmark: Data, displayName: String) {
        self.bookmark = bookmark
        self.displayName = displayName
    }
}

/// A saved connection. Secrets are never part of it; they live in the
/// Keychain keyed by `id`. See SPEC 4.6.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public struct TLSSettings: Codable, Hashable, Sendable {
        public var caCertificate: FileReference?
        /// A PKCS#12 bundle; its passphrase is a secret.
        public var clientIdentity: FileReference?
        public var skipServerVerification: Bool

        public init(
            caCertificate: FileReference? = nil, clientIdentity: FileReference? = nil,
            skipServerVerification: Bool = false
        ) {
            self.caCertificate = caCertificate
            self.clientIdentity = clientIdentity
            self.skipServerVerification = skipServerVerification
        }
    }

    public var id: String
    public var name: String
    public var endpoint: String
    public var separator: String
    /// Skips API version detection, for proxies that rewrite paths.
    public var pinnedPrefix: String?
    public var username: String?
    public var tls: TLSSettings
    /// Live tree updates through a watch; off for large or busy clusters.
    public var watchEnabled: Bool
    public var schema: SchemaSettings

    public init(
        id: String, name: String, endpoint: String, separator: String = "/", pinnedPrefix: String? = nil,
        username: String? = nil, tls: TLSSettings = TLSSettings(), watchEnabled: Bool = true,
        schema: SchemaSettings = SchemaSettings()
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.separator = separator
        self.pinnedPrefix = pinnedPrefix
        self.username = username
        self.tls = tls
        self.watchEnabled = watchEnabled
        self.schema = schema
    }

    /// Missing keys take defaults, so files written by older versions load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try container.decode(String.self, forKey: .endpoint)
        separator = try container.decodeIfPresent(String.self, forKey: .separator) ?? "/"
        pinnedPrefix = try container.decodeIfPresent(String.self, forKey: .pinnedPrefix)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        tls = try container.decodeIfPresent(TLSSettings.self, forKey: .tls) ?? TLSSettings()
        watchEnabled = try container.decodeIfPresent(Bool.self, forKey: .watchEnabled) ?? true
        schema = try container.decodeIfPresent(SchemaSettings.self, forKey: .schema) ?? SchemaSettings()
    }
}
