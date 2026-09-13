import Foundation
import Testing

@testable import EtcdSchema

@Suite("Compiling the user's schema with protoc", .tags(.unit), .enabled(if: Repository.hasProtoc, "run Tools/protoc/fetch-protoc.sh"))
struct ProtocCompilerTests {
    let compiler: ProtocCompiler

    init() throws {
        compiler = ProtocCompiler(protocURL: try Repository.verifiedProtoc())
    }

    @Test("Lists every .proto under the root, relative and byte-sorted")
    func listsProtoFiles() throws {
        let directory = try TemporaryDirectory()
        try directory.write("b/z.proto", "")
        try directory.write("a.proto", "")
        try directory.write("b/a.proto", "")
        try directory.write("B.proto", "")
        try directory.write("notes.txt", "")
        #expect(try ProtocCompiler.protoFiles(under: directory.url) == ["B.proto", "a.proto", "b/a.proto", "b/z.proto"])
    }

    @Test("Builds exactly the argument list from the spec")
    func arguments() {
        let arguments = ProtocCompiler.arguments(
            output: URL(fileURLWithPath: "/o/schema.pb"), includePaths: [URL(fileURLWithPath: "/inc")],
            files: ["a.proto", "b/c.proto"])
        #expect(arguments == [
            "--descriptor_set_out=/o/schema.pb", "--include_imports", "--include_source_info", "-I", ".",
            "-I", "/inc", "./a.proto", "./b/c.proto",
        ])
    }

    @Test("Imports resolve from include paths after the root, and the root's own copy wins")
    func includePaths() async throws {
        let directory = try TemporaryDirectory()
        let includes = try TemporaryDirectory()
        try includes.write("shared/extra.proto", "syntax = \"proto3\";\npackage shared;\nmessage Extra {}\nmessage FromInclude {}\n")
        try includes.write("shared/only.proto", "syntax = \"proto3\";\npackage only;\nmessage Only {}\n")
        try directory.write("shared/extra.proto", "syntax = \"proto3\";\npackage shared;\nmessage Extra {}\n")
        try directory.write("a.proto", """
            syntax = "proto3";
            package a;
            import "shared/extra.proto";
            import "shared/only.proto";
            message A { shared.Extra extra = 1; only.Only only = 2; }
            """)
        let output = directory.url.appending(path: "schema.pb")
        let withIncludes = ProtocCompiler(protocURL: compiler.protocURL, includePaths: [includes.url])
        #expect(try await withIncludes.compile(root: directory.url, output: output).isEmpty)
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: output))
        #expect(registry.message(named: "only.Only") != nil)
        #expect(registry.message(named: "shared.Extra") != nil)
        #expect(registry.message(named: "shared.FromInclude") == nil)
    }

    @Test("The vendored googleapis files let a schema use HTTP annotations")
    func vendoredGoogleAPIs() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("svc.proto", """
            syntax = "proto3";
            package svc;
            import "google/api/annotations.proto";
            message Request {}
            service Service {
              rpc Get(Request) returns (Request) { option (google.api.http) = { get: "/v1/get" }; }
            }
            """)
        let output = directory.url.appending(path: "schema.pb")
        let withAPIs = ProtocCompiler(protocURL: compiler.protocURL, includePaths: [Repository.googleapis])
        #expect(try await withAPIs.compile(root: directory.url, output: output).isEmpty)
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: output))
        #expect(registry.message(named: "svc.Request") != nil)
        #expect(registry.message(named: "google.api.HttpRule") != nil)
    }

    @Test("A colon in the root and file names starting with @ or - compile under their own names")
    func awkwardNames() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("a:b/@scope/a.proto", "syntax = \"proto3\";\npackage s;\nmessage A {}\n")
        try directory.write("a:b/-d.proto", "syntax = \"proto3\";\npackage d;\nmessage D {}\n")
        let output = directory.url.appending(path: "schema.pb")
        try await compiler.compile(root: directory.url.appending(path: "a:b"), output: output)
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: output))
        #expect(registry.message(named: "s.A") != nil)
        #expect(registry.message(named: "d.D") != nil)
    }

    @Test("Compiles a tree with imports, including well-known types")
    func compilesWithImports() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("t/a.proto", """
            syntax = "proto3";
            package t;
            import "t/b.proto";
            import "google/protobuf/timestamp.proto";
            message A { B b = 1; google.protobuf.Timestamp at = 2; }
            """)
        try directory.write("t/b.proto", "syntax = \"proto3\";\npackage t;\nmessage B { string s = 1; }\n")
        let output = directory.url.appending(path: "schema.pb")
        try await compiler.compile(root: directory.url, output: output)
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: output))
        #expect(registry.message(named: "t.A") != nil)
        #expect(registry.message(named: "t.B") != nil)
        #expect(registry.message(named: "google.protobuf.Timestamp") != nil)
    }

    @Test("Surfaces protoc's errors verbatim")
    func errorsAreVerbatim() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("broken.proto", "syntax = \"proto3\";\nmessage A { string s = ; }\n")
        let output = directory.url.appending(path: "schema.pb")

        var surfaced: String?
        do {
            try await compiler.compile(root: directory.url, output: output)
        } catch ProtocError.compilationFailed(_, let stderr) {
            surfaced = stderr
        }

        // Run protoc directly with the same arguments for the reference.
        let root = directory.url.resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = compiler.protocURL
        process.arguments = ProtocCompiler.arguments(output: output, files: ["broken.proto"])
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let reference = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let stderr = try #require(surfaced)
        #expect(stderr == reference)
        #expect(stderr.contains("broken.proto:2"))
        #expect(ProtocError.compilationFailed(exitCode: 1, stderr: stderr).errorDescription == stderr)
    }

    @Test("Files protoc rejects are left out with its reasons, along with the files importing them")
    func skipsRejectedFiles() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("good.proto", "syntax = \"proto3\";\npackage g;\nmessage G {}\n")
        try directory.write("vendor/api.proto", """
            syntax = "proto3";
            package v;
            import "missing/annotations.proto";
            message Api {}
            """)
        try directory.write("user.proto", """
            syntax = "proto3";
            package u;
            import "vendor/api.proto";
            message User { v.Api api = 1; }
            """)
        let output = directory.url.appending(path: "schema.pb")
        let skipped = try await compiler.compile(root: directory.url, output: output)
        #expect(skipped.map(\.path) == ["user.proto", "vendor/api.proto"])
        #expect(skipped.last?.reason.contains("missing/annotations.proto") == true)
        let registry = try SchemaRegistry(descriptorSet: Data(contentsOf: output))
        #expect(registry.message(named: "g.G") != nil)
        #expect(registry.message(named: "u.User") == nil)
    }

    @Test("When every file is rejected, the compile fails with the first run's errors, which name the cause")
    func everyFileRejected() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("a.proto", "syntax = \"proto3\";\nmessage A { string s = ; }\n")
        try directory.write("b.proto", "syntax = \"proto3\";\nimport \"a.proto\";\nmessage B { A a = 1; }\n")
        await #expect {
            try await compiler.compile(root: directory.url, output: directory.url.appending(path: "x.pb"))
        } throws: { error in
            guard case ProtocError.compilationFailed(_, let stderr) = error else { return false }
            // b.proto is blamed only in the second run, after a.proto is left out.
            return stderr.hasPrefix("a.proto:2") && !stderr.contains("b.proto")
        }
    }

    @Test("Warnings are dropped from protoc's output; errors stay verbatim")
    func warningsDropped() {
        let stderr = """
            a.proto:5:1: warning: Import b.proto is unused.
            missing/x.proto: File not found.
            c.proto:3:1: Import "missing/x.proto" was not found or had errors.

            """
        #expect(ProtocCompiler.errors(in: stderr) == """
            missing/x.proto: File not found.
            c.proto:3:1: Import "missing/x.proto" was not found or had errors.

            """)
    }

    @Test("Errors are blamed on the input file they start with, even with colons in its name")
    func blamesInputFiles() {
        let errors = """
            missing/x.proto: File not found.
            ./c.proto:3:1: Import "missing/x.proto" was not found or had errors.
            a:b.proto:1:9: Expected ";".
            a:b.proto:2:1: Expected "}".
            """
        let rejected = ProtocCompiler.rejectedFiles(in: errors, among: ["a:b.proto", "c.proto", "d.proto"])
        #expect(rejected == [
            "c.proto": "3:1: Import \"missing/x.proto\" was not found or had errors.",
            "a:b.proto": "1:9: Expected \";\".\n2:1: Expected \"}\".",
        ])
    }

    @Test("An empty folder is reported instead of compiled")
    func emptyFolder() async throws {
        let directory = try TemporaryDirectory()
        await #expect(throws: ProtocError.noProtoFiles(root: directory.url.path)) {
            try await compiler.compile(root: directory.url, output: directory.url.appending(path: "x.pb"))
        }
    }

    @Test("A missing protoc fails to launch with a clear error")
    func missingProtoc() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("a.proto", "syntax = \"proto3\";\n")
        let missing = ProtocCompiler(protocURL: URL(fileURLWithPath: "/nonexistent/protoc"))
        await #expect {
            try await missing.compile(root: directory.url, output: directory.url.appending(path: "x.pb"))
        } throws: { error in
            guard case ProtocError.launchFailed = error else { return false }
            return true
        }
    }
}

@Suite("Caching the compiled schema", .tags(.unit))
struct SchemaCacheTests {
    let snapshot = SchemaSourceSnapshot(files: [.init(path: "a.proto", modificationTime: 100)])

    @Test("Recompiles when there is no cached descriptor or manifest")
    func missingCache() {
        let manifest = SchemaCacheManifest(sources: snapshot, protocPath: "/p")
        #expect(SchemaCache.needsRecompile(manifest: nil, current: snapshot, protocPath: "/p", descriptorExists: true))
        #expect(SchemaCache.needsRecompile(manifest: manifest, current: snapshot, protocPath: "/p", descriptorExists: false))
    }

    @Test("Reuses the cache when sources and protoc are unchanged")
    func unchanged() {
        let manifest = SchemaCacheManifest(sources: snapshot, protocPath: "/p")
        #expect(!SchemaCache.needsRecompile(manifest: manifest, current: snapshot, protocPath: "/p", descriptorExists: true))
    }

    @Test("Recompiles when a file changes, appears, or protoc or the include paths change")
    func changes() {
        let manifest = SchemaCacheManifest(sources: snapshot, protocPath: "/p")
        let touched = SchemaSourceSnapshot(files: [.init(path: "a.proto", modificationTime: 101)])
        let added = SchemaSourceSnapshot(files: snapshot.files + [.init(path: "b.proto", modificationTime: 1)])
        #expect(SchemaCache.needsRecompile(manifest: manifest, current: touched, protocPath: "/p", descriptorExists: true))
        #expect(SchemaCache.needsRecompile(manifest: manifest, current: added, protocPath: "/p", descriptorExists: true))
        #expect(SchemaCache.needsRecompile(manifest: manifest, current: snapshot, protocPath: "/q", descriptorExists: true))
        #expect(
            SchemaCache.needsRecompile(
                manifest: manifest, current: snapshot, protocPath: "/p", includePaths: ["/inc"], descriptorExists: true))
    }

    @Test("Compiles once, then loads from the cache until a source changes",
        .enabled(if: Repository.hasProtoc))
    func loadCycle() async throws {
        let sources = try TemporaryDirectory()
        let cacheDirectory = try TemporaryDirectory()
        try sources.write("a.proto", "syntax = \"proto3\";\npackage c;\nmessage M { int32 x = 1; }\n")
        let cache = SchemaCache(
            directory: cacheDirectory.url, compiler: ProtocCompiler(protocURL: try Repository.verifiedProtoc()))

        let first = try await cache.load(root: sources.url)
        #expect(first.compiled)
        #expect(first.registry.message(named: "c.M") != nil)
        #expect(try await !cache.load(root: sources.url).compiled)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: sources.url.appending(path: "a.proto").path)
        #expect(try await cache.load(root: sources.url).compiled)
        #expect(try await cache.load(root: sources.url, force: true).compiled)
    }

    @Test("A cached load still reports the files the compile left out",
        .enabled(if: Repository.hasProtoc))
    func cachedSkips() async throws {
        let sources = try TemporaryDirectory()
        let cacheDirectory = try TemporaryDirectory()
        try sources.write("a.proto", "syntax = \"proto3\";\npackage c;\nmessage M { int32 x = 1; }\n")
        try sources.write("b.proto", "syntax = \"proto3\";\nimport \"missing.proto\";\n")
        let cache = SchemaCache(
            directory: cacheDirectory.url, compiler: ProtocCompiler(protocURL: try Repository.verifiedProtoc()))
        #expect(try await cache.load(root: sources.url).skipped.map(\.path) == ["b.proto"])
        let cached = try await cache.load(root: sources.url)
        #expect(!cached.compiled)
        #expect(cached.skipped.map(\.path) == ["b.proto"])
    }
}

// SPEC 6.1: the vendored protoc is checksum-verified before tests run it.
@Suite("Verifying the vendored protoc", .tags(.unit))
struct VendoredProtocTests {
    @Test("The vendored protoc matches its recorded checksum",
        .enabled(if: Repository.hasProtoc, "run Tools/protoc/fetch-protoc.sh"))
    func vendoredProtocMatches() throws {
        #expect(try Repository.verifiedProtoc() == Repository.protoc)
    }

    @Test("A binary matching its recorded checksum is accepted")
    func matchingChecksumIsAccepted() throws {
        let directory = try TemporaryDirectory()
        try directory.write("protoc", "abc")
        // SHA-256 of "abc".
        try directory.write("protoc.sha256", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n")
        let binary = directory.url.appending(path: "protoc")
        #expect(try Repository.verify(binary, against: directory.url.appending(path: "protoc.sha256")) == binary)
    }

    @Test("A binary that does not match its recorded checksum is refused with a way to fix it")
    func mismatchIsRefused() throws {
        let directory = try TemporaryDirectory()
        try directory.write("protoc", "not protoc")
        try directory.write("protoc.sha256", String(repeating: "0", count: 64) + "\n")
        #expect {
            _ = try Repository.verify(
                directory.url.appending(path: "protoc"), against: directory.url.appending(path: "protoc.sha256"))
        } throws: { error in
            String(describing: error).contains("fetch-protoc.sh")
        }
    }
}
