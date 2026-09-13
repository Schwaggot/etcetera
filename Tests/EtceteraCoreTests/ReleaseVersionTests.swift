import Foundation
import Testing

// The release version is set once, in CHANGELOG.md; Tools/version.sh checks
// that the Xcode project and the CLI carry it.

@Suite("Release version", .tags(.unit))
struct ReleaseVersionTests {
    @Test("The Xcode project and the CLI carry CHANGELOG.md's version")
    func consistent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [root.appending(path: "Tools/version.sh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
    }
}
