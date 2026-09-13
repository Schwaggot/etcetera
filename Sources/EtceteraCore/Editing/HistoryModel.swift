import EtcdKit
import Foundation
import Observation

/// A key's earlier versions, found by reading older revisions: each read at
/// one below a version's mod revision yields the version before it. See
/// SPEC 4.7.
@MainActor
@Observable
public final class HistoryModel {
    /// Newest first; the first is the current value.
    public private(set) var versions: [KeyValue] = []
    public private(set) var isLoading = false
    /// Older versions were compacted away.
    public private(set) var reachedCompaction = false
    public private(set) var errorMessage: String?
    /// The mod revision of the version shown.
    public var selectedRevision: Int64?
    private var generation = 0

    public init() {}

    public var selected: KeyValue? {
        versions.first { $0.modRevision == selectedRevision }
    }

    public func load(_ current: KeyValue, from connection: ConnectionModel, limit: Int = 50) async {
        generation += 1
        let run = generation
        versions = [current]
        selectedRevision = current.modRevision
        reachedCompaction = false
        errorMessage = nil
        isLoading = true
        defer { if run == generation { isLoading = false } }
        var revision = current.modRevision - 1
        while revision >= current.createRevision, versions.count < limit {
            do {
                guard let kv = try await connection.value(forKey: current.key, revision: revision),
                    run == generation, kv.createRevision == current.createRevision
                else { return }
                versions.append(kv)
                revision = kv.modRevision - 1
            } catch {
                guard run == generation else { return }
                if Self.isCompaction(error) {
                    reachedCompaction = true
                } else {
                    errorMessage = ConnectionModel.message(for: error)
                }
                return
            }
        }
    }

    /// The selected version against the current one, rendered by `render`.
    public func diffAgainstCurrent(_ render: (Data) -> String) -> [DiffLine] {
        guard let selected, let current = versions.first else { return [] }
        return LineDiff.diff(old: render(selected.value), new: render(current.value))
    }

    /// The gateway reports a read below the compact revision as OUT_OF_RANGE.
    static func isCompaction(_ error: any Error) -> Bool {
        switch error as? EtcdError {
        case .compacted: true
        case .status(.outOfRange, let message): message.contains("compacted")
        default: false
        }
    }
}
