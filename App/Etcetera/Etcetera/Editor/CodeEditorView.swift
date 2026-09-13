//
//  CodeEditorView.swift
//  Etcetera
//

import AppKit
import EtceteraCore
import SwiftUI

/// The value editor: an NSTextView with a line number gutter, current line
/// highlight, bracket matching, the find bar, and highlighting computed off
/// the main actor. SwiftUI's TextEditor can do none of this. See SPEC 4.3.
/// A large text shows a spinner until it is colored, so the app stays
/// responsive meanwhile.
struct CodeEditorView: View {
    @Binding var text: String
    var isEditable: Bool
    var wrapsLines: Bool
    var language: SyntaxLanguage

    @State private var isPreparing = false

    var body: some View {
        CodeTextView(
            text: $text, isEditable: isEditable, wrapsLines: wrapsLines, language: language,
            onPreparing: { isPreparing = $0 }
        )
        .overlay {
            if isPreparing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wrapsLines: Bool
    var language: SyntaxLanguage
    var onPreparing: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, for the line fragment geometry the gutter and the
        // current line highlight need.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Lays out only what is shown, so a large text and a width change stay cheap.
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        storage.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.start()
        update(scrollView, textView: textView, coordinator: context.coordinator, initial: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.text = $text
        update(scrollView, textView: textView, coordinator: context.coordinator, initial: false)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private func update(_ scrollView: NSScrollView, textView: EditorTextView, coordinator: Coordinator, initial: Bool) {
        coordinator.onPreparing = onPreparing
        let wasEditable = coordinator.isEditable
        coordinator.isEditable = isEditable
        if coordinator.wrapsLines != wrapsLines {
            coordinator.wrapsLines = wrapsLines
            Self.setWrapping(wrapsLines, scrollView: scrollView, textView: textView)
        }
        // Against the coordinator's copy: reading the text view's string copies it.
        let textChanged = initial || coordinator.shownText != text
        if textChanged || coordinator.language != language {
            coordinator.language = language
            // Format, Minify and Merge can be undone; text shown read-only must never come back editable.
            if textChanged, !initial, wasEditable, isEditable, !coordinator.shownText.isEmpty, !coordinator.isPreparing {
                coordinator.replaceTextUndoably(text)
            } else if textChanged {
                coordinator.replaceText(text)
            } else {
                coordinator.rehighlight(showingProgress: true)
            }
        }
    }

    private static func setWrapping(_ wraps: Bool, scrollView: NSScrollView, textView: NSTextView) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            let width = scrollView.contentSize.width
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private enum Event: Sendable {
            /// `replacesText` loads new text; otherwise the shown text is recolored.
            case load(String, SyntaxLanguage, replacesText: Bool)
            case edit(EtceteraCore.TextRange, changeInLength: Int, replacement: String)
        }

        /// `revision` counts text changes, so results for older text are recognized.
        private struct Request: Sendable {
            var revision: Int
            var event: Event
        }

        /// The theme, carried to the task that colors text off the main actor.
        private nonisolated struct Palette: @unchecked Sendable {
            let base: [NSAttributedString.Key: Any]
            let colors: [TokenKind: NSColor]

            @MainActor static let current = Palette(
                base: EditorTheme.baseAttributes,
                colors: Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { ($0, EditorTheme.color(for: $0)) }))
        }

        private nonisolated struct Colored: @unchecked Sendable {
            let string: NSAttributedString
            let lineStarts: [Int]?
        }

        /// Texts longer than this, in UTF-16 units, are colored before they show.
        static let prepareThreshold = 200_000
        /// Results with more tokens are colored off the main actor.
        static let inlineTokenLimit = 5_000

        var text: Binding<String>
        var language: SyntaxLanguage = .plainText
        var wrapsLines: Bool?
        var onPreparing: (Bool) -> Void = { _ in }
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRulerView?
        /// The text shown, or being prepared to show.
        private(set) var shownText = ""
        private(set) var isPreparing = false
        var isEditable = false {
            didSet { refreshEditable() }
        }

        private let service = HighlightService()
        private var events: AsyncStream<Request>.Continuation?
        private var pipeline: Task<Void, Never>?
        private var bracketTask: Task<Void, Never>?
        /// Read by the storage delegate before it hops to the main actor.
        nonisolated(unsafe) private var isReplacing = false
        private var bracketRanges: [NSRange] = []
        private var revision = 0
        /// A stale result was dropped, so some ranges may still need colors.
        private var needsFullHighlight = false
        /// Per editor: the window's shared manager would replay old tabs' edits.
        private let undo = UndoManager()

        init(text: Binding<String>) {
            self.text = text
        }

        /// One consumer, so edits reach the service in the order they happened.
        func start() {
            let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
            events = continuation
            let service = service
            pipeline = Task { [weak self] in
                for await request in stream {
                    switch request.event {
                    case .load(let text, let language, let replaces):
                        let result = await service.load(text, language: language)
                        await self?.applyWhole(result, text: text, replacesText: replaces, revision: request.revision)
                    case .edit(let range, let delta, let replacement):
                        let result = await service.applyEdit(
                            editedRange: range, changeInLength: delta, replacement: replacement)
                        await self?.apply(result, revision: request.revision)
                    }
                }
            }
        }

        func stop() {
            events?.finish()
            pipeline?.cancel()
            bracketTask?.cancel()
            undo.removeAllActions()
        }

        func replaceText(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            shownText = newText
            revision += 1
            // Recorded ranges refer to the old text.
            undo.removeAllActions()
            clearBracketMatch()
            let large = newText.utf16.count > Self.prepareThreshold
            setPreparing(large)
            isReplacing = true
            // A large text shows once colored; until then nothing can be typed into the old one.
            storage.setAttributedString(
                NSAttributedString(string: large ? "" : newText, attributes: EditorTheme.baseAttributes))
            isReplacing = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            ruler?.setLineStarts(LineNumberRulerView.lineStarts(in: large ? "" : newText))
            events?.yield(Request(revision: revision, event: .load(newText, language, replacesText: true)))
        }

        /// Through the text view, so the change registers with its undo manager.
        func replaceTextUndoably(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            guard textView.shouldChangeText(in: whole, replacementString: newText) else { return }
            storage.replaceCharacters(
                in: whole, with: NSAttributedString(string: newText, attributes: EditorTheme.baseAttributes))
            textView.didChangeText()
        }

        func rehighlight(showingProgress: Bool = false) {
            guard let textView else { return }
            if showingProgress, shownText.utf16.count > Self.prepareThreshold { setPreparing(true) }
            events?.yield(Request(revision: revision, event: .load(textView.string, language, replacesText: false)))
        }

        private func setPreparing(_ preparing: Bool) {
            guard preparing != isPreparing else { return }
            isPreparing = preparing
            refreshEditable()
            // Not during the view update that may have started this.
            let onPreparing = onPreparing
            Task { @MainActor in onPreparing(preparing) }
        }

        private func refreshEditable() {
            textView?.isEditable = isEditable && !isPreparing
            textView?.isSelectable = true
        }

        // MARK: NSTextStorageDelegate

        nonisolated func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isReplacing else { return }
            let replacement = textStorage.mutableString.substring(with: editedRange)
            MainActor.assumeIsolated {
                self.storageEdited(editedRange, delta: delta, replacement: replacement)
            }
        }

        private func storageEdited(_ range: NSRange, delta: Int, replacement: String) {
            revision += 1
            ruler?.textEdited(range, changeInLength: delta, replacement: replacement)
            events?.yield(
                Request(
                    revision: revision,
                    event: .edit(EtceteraCore.TextRange(range), changeInLength: delta, replacement: replacement)))
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Native, so comparing it with the model's text is a memory compare.
            var string = textView.string
            string.makeContiguousUTF8()
            shownText = string
            text.wrappedValue = string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateBracketMatch()
        }

        // MARK: Applying

        /// Colors the whole text off the main actor and swaps it in at once;
        /// a token at a time would block the main actor on a large text.
        private func applyWhole(_ result: HighlightResult, text: String, replacesText: Bool, revision: Int) async {
            let palette = Palette.current
            let colored = await Task.detached {
                Colored(
                    string: Self.colored(text, tokens: result.tokens, offset: 0, palette: palette),
                    lineStarts: replacesText ? LineNumberRulerView.lineStarts(in: text) : nil)
            }.value
            guard revision == self.revision else {
                needsFullHighlight = true
                return
            }
            // Recoloring would drop the underline of text still being composed.
            if !replacesText, textView?.hasMarkedText() == true {
                needsFullHighlight = true
                return
            }
            needsFullHighlight = false
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRanges
            isReplacing = true
            storage.setAttributedString(colored.string)
            isReplacing = false
            if let lineStarts = colored.lineStarts {
                ruler?.setLineStarts(lineStarts)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                textView.selectedRanges = selection
            }
            setPreparing(false)
        }

        /// A result for older text would color shifted ranges; it is dropped
        /// and the whole text rehighlighted once a current result lands.
        private func apply(_ result: HighlightResult, revision: Int) async {
            guard revision == self.revision else {
                needsFullHighlight = true
                return
            }
            // Recoloring would drop the underline of text still being composed;
            // committing it is an edit, whose result then rehighlights all.
            if textView?.hasMarkedText() == true {
                needsFullHighlight = true
                return
            }
            defer {
                if needsFullHighlight {
                    needsFullHighlight = false
                    rehighlight()
                }
            }
            guard let textView, let storage = textView.textStorage else { return }
            let dirty = Self.clamp(result.dirtyRange.nsRange, to: storage.length)
            if result.tokens.count > Self.inlineTokenLimit {
                let text = storage.mutableString.substring(with: dirty)
                let palette = Palette.current
                let colored = await Task.detached {
                    Colored(
                        string: Self.colored(text, tokens: result.tokens, offset: dirty.location, palette: palette),
                        lineStarts: nil)
                }.value
                guard revision == self.revision else {
                    needsFullHighlight = true
                    return
                }
                let selection = textView.selectedRanges
                isReplacing = true
                storage.replaceCharacters(in: dirty, with: colored.string)
                isReplacing = false
                textView.selectedRanges = selection
                return
            }
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: EditorTheme.text, range: dirty)
            storage.removeAttribute(.underlineStyle, range: dirty)
            for token in result.tokens {
                let range = Self.clamp(token.range.nsRange, to: storage.length)
                guard range.length > 0 else { continue }
                storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: range)
                if token.kind == .error {
                    storage.addAttribute(
                        .underlineStyle, value: NSUnderlineStyle.single.union(.patternDot).rawValue, range: range)
                }
            }
            storage.endEditing()
        }

        /// `text` starts at `offset` in the document the token ranges refer to.
        private nonisolated static func colored(
            _ text: String, tokens: [Token], offset: Int, palette: Palette
        ) -> NSAttributedString {
            let string = NSMutableAttributedString(string: text, attributes: palette.base)
            let length = string.length
            string.beginEditing()
            for token in tokens {
                let lower = max(0, token.range.location - offset)
                let upper = min(length, token.range.upperBound - offset)
                guard upper > lower, let color = palette.colors[token.kind] else { continue }
                let range = NSRange(location: lower, length: upper - lower)
                string.addAttribute(.foregroundColor, value: color, range: range)
                if token.kind == .error {
                    string.addAttribute(
                        .underlineStyle, value: NSUnderlineStyle.single.union(.patternDot).rawValue, range: range)
                }
            }
            string.endEditing()
            return string
        }

        // MARK: Brackets

        private func clearBracketMatch() {
            bracketTask?.cancel()
            guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else {
                return
            }
            for range in bracketRanges {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: Self.clamp(range, to: storage.length))
            }
            bracketRanges = []
        }

        /// Matching scans from the start, so a large text is matched off the main actor.
        private func updateBracketMatch() {
            clearBracketMatch()
            guard let textView, let storage = textView.textStorage, language == .json, !isPreparing else { return }
            let selection = textView.selectedRange()
            let characters = storage.mutableString
            let cursor = selection.location
            let nextToBracket = [cursor - 1, cursor].contains { offset in
                offset >= 0 && offset < characters.length && Self.isBracket(characters.character(at: offset))
            }
            guard selection.length == 0, nextToBracket else { return }
            if characters.length <= Self.prepareThreshold {
                show(BracketMatcher.match(in: characters as String, cursor: cursor))
                return
            }
            let snapshot = characters.copy() as! NSString as String
            let revision = revision
            bracketTask = Task {
                let pair = await Task.detached { BracketMatcher.match(in: snapshot, cursor: cursor) }.value
                guard !Task.isCancelled, revision == self.revision, textView.selectedRange() == selection else { return }
                show(pair)
            }
        }

        private func show(_ pair: BracketPair?) {
            guard let pair, let layoutManager = textView?.layoutManager else { return }
            bracketRanges = [NSRange(location: pair.bracket, length: 1), NSRange(location: pair.match, length: 1)]
            for range in bracketRanges {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: EditorTheme.bracketMatch, forCharacterRange: range)
            }
        }

        private static func isBracket(_ unit: unichar) -> Bool {
            unit == 0x7B || unit == 0x7D || unit == 0x5B || unit == 0x5D
        }

        private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            return NSRange(location: location, length: min(range.length, length - location))
        }
    }
}
