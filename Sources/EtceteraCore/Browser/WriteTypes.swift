import Foundation

/// What a confirmed delete removes: one key, and with `subtreePrefix`
/// everything below it. `affected` is shown before asking. See SPEC 4.5.
public struct DeletePlan: Equatable, Sendable {
    public let key: Data
    public let subtreePrefix: String?
    public let affected: Int64

    public init(key: Data, subtreePrefix: String?, affected: Int64) {
        self.key = key
        self.subtreePrefix = subtreePrefix
        self.affected = affected
    }
}

public struct KeyExistsError: Error, LocalizedError, Sendable {
    public let key: Data

    public var errorDescription: String? {
        String(localized: "\(displayString(for: key)) already exists.", bundle: .module)
    }
}

public struct NotConnectedError: Error, LocalizedError, Sendable {
    public var errorDescription: String? { String(localized: "Not connected to a cluster.", bundle: .module) }
}
