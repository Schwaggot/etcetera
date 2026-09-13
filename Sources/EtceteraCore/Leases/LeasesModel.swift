import EtcdKit
import Foundation
import Observation

/// The cluster's leases with their remaining time and attached keys.
@MainActor
@Observable
public final class LeasesModel {
    public struct Lease: Identifiable, Equatable, Sendable {
        public let id: Int64
        /// Seconds left; -1 once expired.
        public let ttl: Int64
        public let grantedTTL: Int64
        public let keys: [Data]
    }

    public private(set) var leases: [Lease] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    public init() {}

    public func load(from connection: ConnectionModel) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var loaded: [Lease] = []
            for id in try await connection.leaseIDs() {
                let info = try await connection.leaseTimeToLive(id)
                loaded.append(Lease(id: id, ttl: info.ttl, grantedTTL: info.grantedTTL, keys: info.keys))
            }
            leases = loaded.sorted { $0.id < $1.id }
        } catch {
            leases = []
            errorMessage = ConnectionModel.message(for: error)
        }
    }

    public func revoke(_ id: Int64, from connection: ConnectionModel) async {
        do {
            try await connection.revokeLease(id)
            leases.removeAll { $0.id == id }
        } catch {
            errorMessage = ConnectionModel.message(for: error)
        }
    }
}
