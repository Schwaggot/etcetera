import Foundation

/// One line of a diff. Line numbers are 1-based; nil on the side the line is
/// absent from.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case unchanged, inserted, deleted
    }

    public var kind: Kind
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Myers line diff for the conflict sheet and revision compare. See SPEC 4.5
/// and 4.7.
public enum LineDiff {
    /// Splits on newlines. A trailing newline does not add an empty line.
    public static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    public static func diff(old: String, new: String) -> [DiffLine] {
        diff(oldLines: lines(of: old), newLines: lines(of: new))
    }

    public static func diff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        var ids: [String: Int] = [:]
        let a = oldLines.map { line in ids[line] ?? { ids[line] = ids.count; return ids.count - 1 }() }
        let b = newLines.map { line in ids[line] ?? { ids[line] = ids.count; return ids.count - 1 }() }

        // Trimming the common ends keeps the Myers trace small.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
            a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
        {
            suffix += 1
        }
        let middle = myers(Array(a[prefix..<(a.count - suffix)]), Array(b[prefix..<(b.count - suffix)]))

        var result: [DiffLine] = []
        result.reserveCapacity(a.count + b.count)
        for index in 0..<prefix {
            result.append(DiffLine(kind: .unchanged, text: oldLines[index], oldLineNumber: index + 1, newLineNumber: index + 1))
        }
        for op in middle {
            switch op {
            case .equal(let x, let y):
                result.append(
                    DiffLine(
                        kind: .unchanged, text: oldLines[prefix + x],
                        oldLineNumber: prefix + x + 1, newLineNumber: prefix + y + 1))
            case .delete(let x):
                result.append(DiffLine(kind: .deleted, text: oldLines[prefix + x], oldLineNumber: prefix + x + 1, newLineNumber: nil))
            case .insert(let y):
                result.append(DiffLine(kind: .inserted, text: newLines[prefix + y], oldLineNumber: nil, newLineNumber: prefix + y + 1))
            }
        }
        for offset in stride(from: suffix, to: 0, by: -1) {
            let x = oldLines.count - offset
            let y = newLines.count - offset
            result.append(DiffLine(kind: .unchanged, text: oldLines[x], oldLineNumber: x + 1, newLineNumber: y + 1))
        }
        return result
    }

    public static func hasChanges(_ diff: [DiffLine]) -> Bool {
        diff.contains { $0.kind != .unchanged }
    }

    /// Unified format with `context` lines around each hunk; empty when the
    /// inputs are identical.
    public static func unified(
        _ diff: [DiffLine], context: Int = 3, oldLabel: String = "local", newLabel: String = "remote"
    ) -> String {
        let changed = diff.indices.filter { diff[$0].kind != .unchanged }
        guard !changed.isEmpty else { return "" }

        var hunks: [Range<Int>] = []
        for index in changed {
            let range = max(0, index - context)..<min(diff.count, index + context + 1)
            if let last = hunks.last, range.lowerBound <= last.upperBound {
                hunks[hunks.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                hunks.append(range)
            }
        }

        var output = "--- \(oldLabel)\n+++ \(newLabel)\n"
        for hunk in hunks {
            let lines = diff[hunk]
            let oldBefore = diff[..<hunk.lowerBound].filter { $0.kind != .inserted }.count
            let newBefore = diff[..<hunk.lowerBound].filter { $0.kind != .deleted }.count
            let oldCount = lines.filter { $0.kind != .inserted }.count
            let newCount = lines.filter { $0.kind != .deleted }.count
            let oldStart = oldCount == 0 ? oldBefore : oldBefore + 1
            let newStart = newCount == 0 ? newBefore : newBefore + 1
            output += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for line in lines {
                switch line.kind {
                case .unchanged: output += " \(line.text)\n"
                case .deleted: output += "-\(line.text)\n"
                case .inserted: output += "+\(line.text)\n"
                }
            }
        }
        return output
    }

    /// Both versions in one buffer with git-style conflict markers around
    /// every changed region, for the merge choice in SPEC 4.5.
    public static func mergeView(local: String, remote: String) -> String {
        var output = ""
        var ours: [String] = []
        var theirs: [String] = []

        func flush() {
            guard !ours.isEmpty || !theirs.isEmpty else { return }
            output += "<<<<<<< local\n"
            for line in ours { output += line + "\n" }
            output += "=======\n"
            for line in theirs { output += line + "\n" }
            output += ">>>>>>> remote\n"
            ours.removeAll()
            theirs.removeAll()
        }

        for line in diff(old: local, new: remote) {
            switch line.kind {
            case .unchanged:
                flush()
                output += line.text + "\n"
            case .deleted:
                ours.append(line.text)
            case .inserted:
                theirs.append(line.text)
            }
        }
        flush()
        return output
    }

    // MARK: - Myers

    private enum Op {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// Past this many edits the middle shows as replaced wholesale, since the
    /// trace grows with the square of the edit count.
    static let maxEdits = 2000

    private static func myers(_ a: [Int], _ b: [Int]) -> [Op] {
        let n = a.count
        let m = b.count
        let maxD = n + m
        guard maxD > 0 else { return [] }
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 2)
        // Step d reads only diagonals -d...d, so each keeps just that slice.
        var trace: [[Int]] = []
        var found = false

        search: for d in 0...min(maxD, maxEdits) {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x =
                    k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else {
            return (0..<n).map { Op.delete($0) } + (0..<m).map { Op.insert($0) }
        }

        var ops: [Op] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = k == -d || (k != d && v[k - 1 + d] < v[k + 1 + d]) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : v[prevK + d]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                ops.append(x == prevX ? .insert(y - 1) : .delete(x - 1))
                x = prevX
                y = prevY
            }
        }
        return ops.reversed()
    }
}
