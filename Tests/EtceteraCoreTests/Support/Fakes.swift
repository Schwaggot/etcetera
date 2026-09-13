import EtceteraCore
import Foundation

/// File references resolved from a dictionary keyed by bookmark bytes.
final class FakeFileAccess: FileAccess, @unchecked Sendable {
    var files: [Data: Data] = [:]

    func contents(of reference: FileReference) throws -> Data {
        guard let data = files[reference.bookmark] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
}

/// A unique temporary directory removed when the value is discarded.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
