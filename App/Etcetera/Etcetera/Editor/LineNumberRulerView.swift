//
//  LineNumberRulerView.swift
//  Etcetera
//

import AppKit

/// The editor gutter: numbers for the visible logical lines.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts, kept current edit by edit.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Views no longer clip by default; the background fill would cover the text and the header.
        clipsToBounds = true
        ruleThickness = 36
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    nonisolated static func lineStarts(in text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    func setLineStarts(_ starts: [Int]) {
        lineStarts = starts
        linesChanged()
    }

    /// One edit in the text storage's terms: the post-edit range and the
    /// change in length.
    func textEdited(_ range: NSRange, changeInLength delta: Int, replacement: String) {
        let oldUpper = NSMaxRange(range) - delta
        // A line start follows a newline, so the replaced newlines' starts lie in (location, oldUpper].
        let first = firstIndex(after: range.location)
        let end = firstIndex(after: oldUpper)
        var inserted: [Int] = []
        var offset = range.location
        for unit in replacement.utf16 {
            offset += 1
            if unit == 0x0A { inserted.append(offset) }
        }
        lineStarts.replaceSubrange(first..<end, with: inserted)
        for index in (first + inserted.count)..<lineStarts.count {
            lineStarts[index] += delta
        }
        linesChanged()
    }

    private func linesChanged() {
        needsDisplay = true
        // Resizing lays out the text view, which must wait until the text
        // storage has finished processing the edit.
        DispatchQueue.main.async { [weak self] in self?.fitThickness() }
    }

    private func fitThickness() {
        let digits = CGFloat(max(3, String(lineStarts.count).count))
        // The widest glyph of the system font is far wider than a digit.
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: EditorTheme.gutterFont]).width
        let width = ceil(digits * digitWidth) + 14
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        NSColor.textBackgroundColor.setFill()
        rect.intersection(bounds).fill()

        let length = textView.textStorage?.length ?? 0
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let origin = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        var line = max(0, firstIndex(after: characters.location) - 1)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 6, y: origin + fragment.minY + (fragment.height - size.height) / 2),
                withAttributes: attributes)
            line += 1
        }
    }

    /// The index of the first line start after `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
