//
//  SecurityScopedFileAccess.swift
//  Etcetera
//

import EtceteraCore
import Foundation

/// Reads certificate files through security-scoped bookmarks; nothing is
/// copied into the container. See SPEC 4.6 and 6.9.
struct SecurityScopedFileAccess: FileAccess {
    func contents(of reference: FileReference) throws -> Data {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: reference.bookmark, options: [.withSecurityScope], relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        return try Data(contentsOf: url)
    }

    /// A read-only bookmark for a file the user just picked.
    static func reference(for url: URL) throws -> FileReference {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil,
            relativeTo: nil)
        return FileReference(bookmark: bookmark, displayName: url.lastPathComponent)
    }
}
