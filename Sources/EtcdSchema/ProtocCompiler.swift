import Foundation

// Compiling the user's schema with protoc and caching the result. See SPEC 5.2.

public enum ProtocError: Error, Sendable, Equatable {
    /// protoc ran and failed. `stderr` is its output, verbatim.
    case compilationFailed(exitCode: Int32, stderr: String)
    case noProtoFiles(root: String)
    case launchFailed(String)
}

extension ProtocError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .compilationFailed(_, let stderr):
            // protoc's messages are good; rewriting them would lose information.
            return stderr
        case .noProtoFiles(let root):
            return String(localized: "There are no .proto files under \(root).", bundle: .module)
        case .launchFailed(let detail):
            return String(localized: "protoc could not be started: \(detail)", bundle: .module)
        }
    }
}

/// A .proto protoc rejected, left out so the rest of the folder compiles.
public struct SkippedProtoFile: Codable, Sendable, Equatable {
    public var path: String
    /// protoc's messages about the file, verbatim.
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ProtocCompiler: Sendable {
    /// The bundled protoc, or an external one chosen in settings.
    public let protocURL: URL
    /// Searched for imports after the root, such as the bundled googleapis files.
    public let includePaths: [URL]

    public init(protocURL: URL, includePaths: [URL] = []) {
        self.protocURL = protocURL
        self.includePaths = includePaths
    }

    /// Every .proto under `root`, relative to it and sorted by bytes.
    public static func protoFiles(under root: URL) throws -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [String] = []
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "proto" {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            // A folder or pipe named .proto is no schema file.
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = resolved.path
            guard path.hasPrefix(prefix) else { continue }
            files.append(String(path.dropFirst(prefix.count)))
        }
        return files.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The exact argument list from SPEC 5.2, run from inside the root so a
    /// `:` in its path, or a file name starting with `@` or `-`, is not read
    /// as protoc syntax. Include paths follow the root, so its own files win.
    public static func arguments(output: URL, includePaths: [URL] = [], files: [String]) -> [String] {
        ["--descriptor_set_out=\(output.path)", "--include_imports", "--include_source_info", "-I", "."]
            + includePaths.flatMap { ["-I", $0.path] }
            + files.map { "./" + $0 }
    }

    /// Runs protoc over every .proto under `root`, writing a
    /// FileDescriptorSet to `output`. Files protoc rejects are left out, and
    /// with them the files importing them; the compile fails only when no
    /// file is left or protoc blames none of them. See SPEC 5.2.
    @discardableResult
    public func compile(root: URL, output: URL) async throws -> [SkippedProtoFile] {
        var files = try Self.protoFiles(under: root)
        guard !files.isEmpty else { throw ProtocError.noProtoFiles(root: root.path) }
        var skipped: [SkippedProtoFile] = []
        var firstFailure: ProtocError?
        while true {
            let (status, stderr) = try await run(
                Self.arguments(output: output, includePaths: includePaths, files: files), in: root)
            if status == 0 {
                return skipped.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            }
            let errors = Self.errors(in: stderr)
            let failure = ProtocError.compilationFailed(exitCode: status, stderr: errors)
            let rejected = Self.rejectedFiles(in: errors, among: files)
            guard !rejected.isEmpty else { throw failure }
            files.removeAll { rejected[$0] != nil }
            // With every file rejected, the first run's errors name the causes.
            guard !files.isEmpty else { throw firstFailure ?? failure }
            firstFailure = firstFailure ?? failure
            skipped += rejected.map { SkippedProtoFile(path: $0.key, reason: $0.value) }
        }
    }

    /// protoc's output without its warnings, which never fail a compile.
    static func errors(in stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(": warning: ") }
            .joined(separator: "\n")
    }

    /// The input files protoc blames, each with its messages about it.
    static func rejectedFiles(in errors: String, among files: [String]) -> [String: String] {
        let inputs = Set(files)
        var rejected: [String: String] = [:]
        for line in errors.split(separator: "\n") {
            let text = line.hasPrefix("./") ? line.dropFirst(2) : line
            // "path:line:column: message" or "path: message"; a path may hold colons.
            var searchStart = text.startIndex
            while let colon = text[searchStart...].firstIndex(of: ":") {
                let path = String(text[..<colon])
                if inputs.contains(path) {
                    let message = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    rejected[path] = rejected[path].map { $0 + "\n" + message } ?? message
                    break
                }
                searchStart = text.index(after: colon)
            }
        }
        return rejected
    }

    private func run(_ arguments: [String], in root: URL) async throws -> (Int32, String) {
        let executable = protocURL
        let directory = root.resolvingSymlinksInPath()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int32, String), any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProtocError.launchFailed(error.localizedDescription))
                    return
                }
                // Drain before waiting so a chatty protoc cannot fill the pipe.
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Cache

/// The source folder's .proto files and their modification times.
public struct SchemaSourceSnapshot: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        /// Seconds since 1970, as reported by the file system.
        public var modificationTime: Double

        public init(path: String, modificationTime: Double) {
            self.path = path
            self.modificationTime = modificationTime
        }
    }

    public var files: [File]

    public init(files: [File]) {
        self.files = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
}

/// Lists a schema folder. Injected so cache decisions are unit-testable.
public protocol SchemaSourceListing: Sendable {
    func snapshot(of root: URL) throws -> SchemaSourceSnapshot
}

public struct FileSystemSourceListing: SchemaSourceListing {
    public init() {}

    public func snapshot(of root: URL) throws -> SchemaSourceSnapshot {
        let base = root.resolvingSymlinksInPath()
        let files = try ProtocCompiler.protoFiles(under: base).map { path in
            let values = try base.appending(path: path).resourceValues(forKeys: [.contentModificationDateKey])
            return SchemaSourceSnapshot.File(
                path: path, modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return SchemaSourceSnapshot(files: files)
    }
}

/// What a cached schema.pb was compiled from; stored next to it.
public struct SchemaCacheManifest: Codable, Sendable, Equatable {
    public var sources: SchemaSourceSnapshot
    public var protocPath: String
    public var includePaths: [String]
    /// Kept so a cached load still reports them.
    public var skipped: [SkippedProtoFile]

    public init(
        sources: SchemaSourceSnapshot, protocPath: String, includePaths: [String] = [], skipped: [SkippedProtoFile] = []
    ) {
        self.sources = sources
        self.protocPath = protocPath
        self.includePaths = includePaths
        self.skipped = skipped
    }
}

/// The compiled schema.pb cached in a directory next to the profile, reused
/// until the sources or the protoc in use change.
public struct SchemaCache: Sendable {
    public static let descriptorFileName = "schema.pb"
    public static let manifestFileName = "schema-manifest.json"

    public let directory: URL
    public let compiler: ProtocCompiler
    public let listing: any SchemaSourceListing

    public init(directory: URL, compiler: ProtocCompiler, listing: any SchemaSourceListing = FileSystemSourceListing()) {
        self.directory = directory
        self.compiler = compiler
        self.listing = listing
    }

    public static func needsRecompile(
        manifest: SchemaCacheManifest?, current: SchemaSourceSnapshot, protocPath: String,
        includePaths: [String] = [], descriptorExists: Bool
    ) -> Bool {
        guard descriptorExists, let manifest else { return true }
        return manifest.sources != current || manifest.protocPath != protocPath
            || manifest.includePaths != includePaths
    }

    public var descriptorURL: URL { directory.appending(path: Self.descriptorFileName) }
    public var manifestURL: URL { directory.appending(path: Self.manifestFileName) }

    /// Whether the cached descriptor set is stale for `root`.
    public func isStale(root: URL) throws -> Bool {
        Self.needsRecompile(
            manifest: storedManifest, current: try listing.snapshot(of: root), protocPath: compiler.protocURL.path,
            includePaths: compiler.includePaths.map(\.path),
            descriptorExists: FileManager.default.fileExists(atPath: descriptorURL.path))
    }

    /// Nil when missing or unreadable, which recompiles.
    private var storedManifest: SchemaCacheManifest? {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(SchemaCacheManifest.self, from: $0) }
    }

    /// Loads the registry, compiling first when stale or when `force` is set.
    /// Returns whether protoc ran and which files it left out.
    @discardableResult
    public func load(root: URL, force: Bool = false) async throws
        -> (registry: SchemaRegistry, compiled: Bool, skipped: [SkippedProtoFile])
    {
        var compiled = false
        var skipped: [SkippedProtoFile]
        if try force || isStale(root: root) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = try listing.snapshot(of: root)
            skipped = try await compiler.compile(root: root, output: descriptorURL)
            let manifest = SchemaCacheManifest(
                sources: snapshot, protocPath: compiler.protocURL.path,
                includePaths: compiler.includePaths.map(\.path), skipped: skipped)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            compiled = true
        } else {
            skipped = storedManifest?.skipped ?? []
        }
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: descriptorURL))
        return (registry, compiled, skipped)
    }
}
