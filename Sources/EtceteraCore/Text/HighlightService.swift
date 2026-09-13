import Foundation

/// Tokens for a range, ready for the main actor to apply as attributes.
public struct HighlightResult: Hashable, Sendable {
    /// Increases with every call; the caller drops results older than the
    /// newest it has applied.
    public var generation: Int
    /// Clear attributes over this range, then apply `tokens`.
    public var dirtyRange: TextRange
    /// Absolute tokens overlapping `dirtyRange`.
    public var tokens: [Token]
}

/// Runs tokenizing off the main actor. Edits must be sent in the order they
/// happened in the text view.
public actor HighlightService {
    private var document: any HighlightingDocument
    private var generation = 0

    public init(language: SyntaxLanguage = .json, text: String = "") {
        document = Self.makeDocument(language: language, text: text)
    }

    public var text: String { document.text }

    /// Replaces the whole buffer and returns tokens for all of it.
    public func load(_ text: String, language: SyntaxLanguage) -> HighlightResult {
        document = Self.makeDocument(language: language, text: text)
        generation += 1
        return HighlightResult(
            generation: generation,
            dirtyRange: TextRange(location: 0, length: text.utf16.count),
            tokens: document.tokens(in: nil))
    }

    /// Applies one edit in pre-edit UTF-16 offsets.
    public func applyEdit(replacing range: TextRange, with replacement: String) -> HighlightResult {
        let update = document.applyEdit(replacing: range, with: replacement)
        generation += 1
        return HighlightResult(
            generation: generation, dirtyRange: update.dirtyRange,
            tokens: document.tokens(in: update.dirtyRange))
    }

    /// NSTextStorage reports edits in post-edit terms: the edited range and
    /// the change in length.
    public func applyEdit(editedRange: TextRange, changeInLength: Int, replacement: String) -> HighlightResult {
        let oldRange = TextRange(location: editedRange.location, length: editedRange.length - changeInLength)
        return applyEdit(replacing: oldRange, with: replacement)
    }

    static func makeDocument(language: SyntaxLanguage, text: String) -> any HighlightingDocument {
        switch language {
        case .json: HighlightCache(text: text, tokenizer: JSONTokenizer())
        case .plainText: HighlightCache(text: text, tokenizer: PlainTextTokenizer())
        }
    }
}
