//
//  AppSchemaLoader.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import Foundation

/// Compiles a profile's schema folder with protoc and caches schema.pb next
/// to the profiles, reusing it while the sources are unchanged. See SPEC 5.2.
struct AppSchemaLoader: SchemaLoading {
    func schema(for settings: SchemaSettings, profileID: String, force: Bool) async throws -> CompiledSchema {
        guard let source = settings.source else { throw CocoaError(.fileNoSuchFile) }
        var isStale = false
        let root = try URL(
            resolvingBookmarkData: source.bookmark, options: [.withSecurityScope], relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        guard root.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { root.stopAccessingSecurityScopedResource() }
        let protoc = try ProtocLocation.resolve()
        defer { protoc.stopAccessing() }
        let cache = SchemaCache(
            directory: ProfileStore.applicationSupport.appending(path: "Schemas/\(profileID)"),
            compiler: ProtocCompiler(protocURL: protoc.url, includePaths: ProtocLocation.bundledIncludes))
        let loaded = try await cache.load(root: root, force: force)
        return CompiledSchema(registry: loaded.registry, skipped: loaded.skipped)
    }
}

/// The protoc bundled in Contents/Resources, or one chosen in Settings and
/// reached through a security-scoped bookmark.
nonisolated enum ProtocLocation {
    static let useCustomKey = "protoc.useCustom"
    static let customBookmarkKey = "protoc.customBookmark"
    static let customPathKey = "protoc.customPath"

    nonisolated struct Resolved {
        let url: URL
        fileprivate let scoped: Bool

        func stopAccessing() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    static var bundled: URL {
        Bundle.main.url(forResource: "protoc", withExtension: nil)
            ?? Bundle.main.bundleURL.appending(path: "Contents/Resources/protoc")
    }

    /// The vendored googleapis files, searched after the schema folder.
    static var bundledIncludes: [URL] {
        Bundle.main.url(forResource: "googleapis", withExtension: nil).map { [$0] } ?? []
    }

    /// A custom protoc that cannot be opened is an error, never a silent
    /// fallback to the bundled one.
    static func resolve(defaults: UserDefaults = .standard) throws -> Resolved {
        guard defaults.bool(forKey: useCustomKey) else { return Resolved(url: bundled, scoped: false) }
        var isStale = false
        guard let bookmark = defaults.data(forKey: customBookmarkKey),
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else { throw CustomProtocUnavailable() }
        return Resolved(url: url, scoped: true)
    }

    static func choose(_ url: URL, defaults: UserDefaults = .standard) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: customBookmarkKey)
        defaults.set(url.path, forKey: customPathKey)
    }
}

nonisolated struct CustomProtocUnavailable: LocalizedError {
    var errorDescription: String? {
        String(
            localized:
                "The custom protoc chosen in Settings cannot be opened. Choose it again, or switch to the bundled protoc.")
    }
}
