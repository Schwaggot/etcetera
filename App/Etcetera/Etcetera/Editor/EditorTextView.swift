//
//  EditorTextView.swift
//  Etcetera
//

import AppKit

/// An NSTextView that highlights the line holding the insertion point.
final class EditorTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let line = currentLineRect() else { return }
        EditorTheme.currentLine.setFill()
        line.intersection(rect).fill()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        needsDisplay = true
    }

    private func currentLineRect() -> NSRect? {
        // The storage's own string: `string` copies the whole text on every draw.
        guard let layoutManager, let textContainer, let string = textStorage?.mutableString,
            selectedRange().length == 0
        else { return nil }
        let location = selectedRange().location
        var rect: NSRect
        if location >= string.length, !layoutManager.extraLineFragmentRect.isEmpty {
            rect = layoutManager.extraLineFragmentRect
        } else if string.length > 0 {
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length - 1), length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        } else {
            return nil
        }
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
    }
}
