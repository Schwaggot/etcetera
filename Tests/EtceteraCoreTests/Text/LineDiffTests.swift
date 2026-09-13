import Foundation
import Testing

@testable import EtceteraCore

@Suite("Line diff", .tags(.unit))
struct LineDiffTests {
    @Test("Identical inputs are all unchanged and render no hunks")
    func identical() {
        let diff = LineDiff.diff(old: "a\nb\n", new: "a\nb\n")
        #expect(diff.allSatisfy { $0.kind == .unchanged })
        #expect(!LineDiff.hasChanges(diff))
        #expect(LineDiff.unified(diff) == "")
    }

    @Test("A changed line shows as a deletion then an insertion with line numbers")
    func changedLine() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc")
        #expect(diff == [
            DiffLine(kind: .unchanged, text: "a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(kind: .deleted, text: "b", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(kind: .inserted, text: "B", oldLineNumber: nil, newLineNumber: 2),
            DiffLine(kind: .unchanged, text: "c", oldLineNumber: 3, newLineNumber: 3),
        ])
    }

    @Test("A diff where every line differs stays bounded and shows all lines replaced")
    func largeDisjointDiff() {
        let old = (0..<20_000).map { "old \($0)" }
        let new = (0..<20_000).map { "new \($0)" }
        let diff = LineDiff.diff(oldLines: old, newLines: new)
        #expect(diff.count == 40_000)
        #expect(diff.prefix(20_000).allSatisfy { $0.kind == .deleted })
        #expect(diff.suffix(20_000).allSatisfy { $0.kind == .inserted })
        #expect(diff.last == DiffLine(kind: .inserted, text: "new 19999", oldLineNumber: nil, newLineNumber: 20_000))
    }

    @Test("Insertions at the ends and from empty input")
    func insertions() {
        #expect(LineDiff.diff(old: "", new: "x\ny").map(\.kind) == [.inserted, .inserted])
        #expect(LineDiff.diff(old: "x\ny", new: "").map(\.kind) == [.deleted, .deleted])
        #expect(LineDiff.diff(old: "b", new: "a\nb\nc").map(\.kind) == [.inserted, .unchanged, .inserted])
    }

    @Test("Both sides can be reconstructed and the diff is minimal", arguments: [UInt64(5), 17, 1234])
    func reconstructsAndIsMinimal(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<150 {
            let old = (0..<Int.random(in: 0...12, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let new = (0..<Int.random(in: 0...12, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let diff = LineDiff.diff(oldLines: old, newLines: new)
            #expect(diff.filter { $0.kind != .inserted }.map(\.text) == old)
            #expect(diff.filter { $0.kind != .deleted }.map(\.text) == new)
            #expect(diff.filter { $0.kind == .unchanged }.count == lcsLength(old, new))
            #expect(diff.compactMap(\.oldLineNumber) == Array(stride(from: 1, through: old.count, by: 1)))
            #expect(diff.compactMap(\.newLineNumber) == Array(stride(from: 1, through: new.count, by: 1)))
        }
    }

    @Test("Unified rendering has hunk headers and context")
    func unified() {
        let old = (1...10).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "5", with: "five")
        let expected = """
            --- local
            +++ remote
            @@ -2,7 +2,7 @@
             2
             3
             4
            -5
            +five
             6
             7
             8

            """
        #expect(LineDiff.unified(LineDiff.diff(old: old, new: new)) == expected)
    }

    @Test("A pure insertion hunk reports a zero count on the old side")
    func pureInsertionHeader() {
        let rendered = LineDiff.unified(LineDiff.diff(old: "", new: "a"), context: 0)
        #expect(rendered.contains("@@ -0,0 +1,1 @@"))
    }

    @Test("The merge view wraps each changed region in conflict markers")
    func mergeView() {
        let local = "{\n  \"a\": 1,\n  \"b\": 2\n}"
        let remote = "{\n  \"a\": 9,\n  \"b\": 2\n}"
        let expected = """
            {
            <<<<<<< local
              "a": 1,
            =======
              "a": 9,
            >>>>>>> remote
              "b": 2
            }

            """
        #expect(LineDiff.mergeView(local: local, remote: remote) == expected)
    }

    private func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }
}
