//
//  EditorTheme.swift
//  Etcetera
//

import AppKit
import EtceteraCore

/// Editor colors from semantic system colors, so they follow the system
/// appearance. See SPEC 4.3.
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    static let text = NSColor.textColor
    static let currentLine = NSColor.controlAccentColor.withAlphaComponent(0.08)
    static let bracketMatch = NSColor.systemYellow.withAlphaComponent(0.35)

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .key: .systemPurple
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPink
        case .punctuation: .secondaryLabelColor
        case .error: .systemRed
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: text]
    }
}
