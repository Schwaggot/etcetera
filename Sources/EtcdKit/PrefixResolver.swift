import Foundation

/// A parsed etcd server version, from the `etcdserver` field of `/version`.
public struct ServerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "3.5.21" and tolerates suffixes such as "3.6.0-alpha.1".
    public init?(parsing string: String) {
        guard let core = string.split(separator: "-", maxSplits: 1).first else { return nil }
        let parts = core.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            return nil
        }
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Maps a server version to its gateway path prefix.
///
/// | etcd version | Path prefix |
/// | 3.0 to 3.2   | /v3alpha    |
/// | 3.3          | /v3beta     |
/// | 3.4 and up   | /v3         |
public enum PrefixResolver {
    /// Probe order for stage two detection, newest first.
    public static let probeOrder = ["/v3", "/v3beta", "/v3alpha"]

    public static func prefix(for version: ServerVersion) -> String {
        if version >= ServerVersion(major: 3, minor: 4) { return "/v3" }
        if version >= ServerVersion(major: 3, minor: 3) { return "/v3beta" }
        return "/v3alpha"
    }

    public static func prefix(forServerVersion string: String) throws -> String {
        guard let version = ServerVersion(parsing: string) else {
            throw EtcdError.decoding("unparseable server version: \(string)")
        }
        return prefix(for: version)
    }
}

/// What the connected server can do, driven by its detected version.
/// The application uses this to hide controls the server cannot honor.
public struct ServerCapabilities: Sendable, Hashable {
    public var version: ServerVersion?

    /// `Lease.Leases` does not exist before 3.3.
    public var canListLeases: Bool {
        guard let version else { return false }
        return version >= ServerVersion(major: 3, minor: 3)
    }

    /// `Maintenance.Status` returns `dbSizeInUse` only on 3.4 and later.
    public var reportsDBSizeInUse: Bool {
        guard let version else { return false }
        return version >= ServerVersion(major: 3, minor: 4)
    }

    public init(version: ServerVersion?) {
        self.version = version
    }
}
