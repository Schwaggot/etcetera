//
//  SchemaFolderWatcher.swift
//  Etcetera
//

import CoreServices
import EtceteraCore
import Foundation

/// Watches a schema folder recursively so the window can offer to
/// recompile when files change. See SPEC 5.2.
nonisolated final class SchemaFolderWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init?(reference: FileReference, onChange: @escaping @Sendable () -> Void) {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: reference.bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else { return nil }
        self.url = url
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SchemaFolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        url.stopAccessingSecurityScopedResource()
    }
}
