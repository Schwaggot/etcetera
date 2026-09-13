import Foundation

/// What an edit changed.
public struct HighlightUpdate: Hashable, Sendable {
    /// Post-edit range whose attributes must be reapplied. Downstream lines
    /// that were retokenized but produced identical tokens are excluded.
    public var dirtyRange: TextRange
    /// Lines tokenized to process the edit, for tests and diagnostics.
    public var retokenizedLines: Int
}

/// Per-line token cache with the tokenizer state at each line start. An edit
/// retokenizes the touched lines and continues downstream only until the
/// line-start state converges with the cached one.
public struct HighlightCache<T: Tokenizer>: Sendable {
    struct Line: Sendable {
        /// UTF-16 units, excluding the newline.
        var length: Int
        var hasNewline: Bool
        var startState: T.State
        /// Line-relative.
        var tokens: [Token]
    }

    public let tokenizer: T
    public private(set) var units: [UInt16]
    private var lines: [Line] = []
    private var lineStarts: [Int] = []

    public init(text: String, tokenizer: T) {
        self.init(units: Array(text.utf16), tokenizer: tokenizer)
    }

    public init(units: [UInt16], tokenizer: T) {
        self.tokenizer = tokenizer
        self.units = units
        var state = tokenizer.initialState
        lines = makeLines(from: 0, to: units.count, lastHasNewline: false, state: &state)
        rebuildLineStarts(from: 0)
    }

    public var text: String { String(decoding: units, as: UTF16.self) }
    public var lineCount: Int { lines.count }

    /// Absolute tokens overlapping `range`, or all tokens when nil.
    public func tokens(in range: TextRange? = nil) -> [Token] {
        let query = range ?? TextRange(location: 0, length: units.count)
        var result: [Token] = []
        var index = lineIndex(containing: max(0, query.location))
        while index < lines.count, lineStarts[index] < query.upperBound {
            let base = lineStarts[index]
            for token in lines[index].tokens {
                let absolute = TextRange(location: base + token.range.location, length: token.range.length)
                if absolute.overlaps(query) {
                    result.append(Token(kind: token.kind, range: absolute))
                }
            }
            index += 1
        }
        return result
    }

    @discardableResult
    public mutating func applyEdit(replacing range: TextRange, with replacement: String) -> HighlightUpdate {
        applyEdit(replacing: range, with: Array(replacement.utf16))
    }

    /// Replaces `range` (pre-edit UTF-16 offsets) with `replacement`.
    @discardableResult
    public mutating func applyEdit(replacing range: TextRange, with replacement: [UInt16]) -> HighlightUpdate {
        let location = min(max(0, range.location), units.count)
        let upper = min(max(location, range.upperBound), units.count)
        let firstLine = lineIndex(containing: location)
        let lastLine = lineIndex(containing: upper)
        let regionStart = lineStarts[firstLine]
        let regionEndOld = lineStarts[lastLine] + lines[lastLine].length
        let lastHasNewline = lines[lastLine].hasNewline

        units.replaceSubrange(location..<upper, with: replacement)
        let regionEndNew = regionEndOld + replacement.count - (upper - location)

        var state = lines[firstLine].startState
        let newLines = makeLines(
            from: regionStart, to: regionEndNew, lastHasNewline: lastHasNewline, state: &state)
        lines.replaceSubrange(firstLine...lastLine, with: newLines)
        rebuildLineStarts(from: firstLine)

        var index = firstLine + newLines.count
        var retokenized = newLines.count
        var dirtyEndLine = index - 1
        while index < lines.count, lines[index].startState != state {
            let start = lineStarts[index]
            var tokens: [Token] = []
            lines[index].startState = state
            tokenizer.tokenize(line: units[start..<start + lines[index].length], state: &state, into: &tokens)
            if tokens != lines[index].tokens {
                lines[index].tokens = tokens
                dirtyEndLine = index
            }
            retokenized += 1
            index += 1
        }

        let dirtyEnd = lineStarts[dirtyEndLine] + lines[dirtyEndLine].length
        return HighlightUpdate(
            dirtyRange: TextRange(location: regionStart, length: dirtyEnd - regionStart),
            retokenizedLines: retokenized)
    }

    // MARK: - Internals

    private func makeLines(from start: Int, to end: Int, lastHasNewline: Bool, state: inout T.State) -> [Line] {
        var result: [Line] = []
        var lineStart = start
        while true {
            var stop = lineStart
            while stop < end, units[stop] != 0x0A { stop += 1 }
            let atEnd = stop >= end
            let startState = state
            var tokens: [Token] = []
            tokenizer.tokenize(line: units[lineStart..<stop], state: &state, into: &tokens)
            result.append(
                Line(
                    length: stop - lineStart, hasNewline: atEnd ? lastHasNewline : true,
                    startState: startState, tokens: tokens))
            if atEnd { return result }
            lineStart = stop + 1
        }
    }

    private mutating func rebuildLineStarts(from index: Int) {
        if index == 0 || lineStarts.isEmpty {
            lineStarts = [0]
        } else if lineStarts.count > index + 1 {
            lineStarts.removeSubrange((index + 1)...)
        }
        lineStarts.reserveCapacity(lines.count)
        var next = lineStarts.count
        while next < lines.count {
            lineStarts.append(lineStarts[next - 1] + lines[next - 1].length + 1)
            next += 1
        }
    }

    /// The last line whose start is at or before `offset`.
    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}

/// Type-erased view of a cache, so the service can switch languages.
public protocol HighlightingDocument: Sendable {
    var text: String { get }
    func tokens(in range: TextRange?) -> [Token]
    mutating func applyEdit(replacing range: TextRange, with replacement: String) -> HighlightUpdate
}

extension HighlightCache: HighlightingDocument {}
