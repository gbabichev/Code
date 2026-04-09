//
//  CodeEditorView.swift
//  Code
//
import AppKit
import SwiftUI

@MainActor
final class ActiveEditorTextViewRegistry {
    static let shared = ActiveEditorTextViewRegistry()

    weak var textView: NSTextView?

    func register(_ textView: NSTextView) {
        self.textView = textView
    }

    func toggleLineComment() {
        (textView as? LineClickableTextView)?.toggleLineComment()
    }

    func indentSelection() {
        (textView as? LineClickableTextView)?.indentSelection()
    }

    func outdentSelection() {
        (textView as? LineClickableTextView)?.outdentSelection()
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let isWordWrapEnabled: Bool
    let skin: SkinDefinition
    let language: EditorLanguage
    let indentWidth: Int
    let autocompleteMode: EditorAutocompleteMode
    let editorFont: NSFont
    let editorSemiboldFont: NSFont
    let onDidFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            textBinding: $text,
            language: language,
            skin: skin,
            indentWidth: indentWidth,
            autocompleteMode: autocompleteMode,
            editorFont: editorFont,
            editorSemiboldFont: editorSemiboldFont,
            isWordWrapEnabled: isWordWrapEnabled,
            onDidFocus: onDidFocus
        )
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)
        let container = EditorContainerView()
        let textView = LineClickableTextView()

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = editorFont
        textView.textColor = theme.baseColor
        textView.backgroundColor = theme.editorBackgroundColor
        textView.insertionPointColor = theme.baseColor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionColor,
            .foregroundColor: theme.baseColor
        ]
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !isWordWrapEnabled
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = theme.editorBackgroundColor
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        container.embed(gutterView: context.coordinator.gutterView, scrollView: scrollView)
        context.coordinator.attach(textView: textView, scrollView: scrollView, containerView: container)
        context.coordinator.applyTheme(theme)
        context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)
        _ = context.coordinator.syncWithBindingText(text)
        DispatchQueue.main.async {
            context.coordinator.applyHighlighting()
        }

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let didLanguageChange = context.coordinator.language != language
        let didSkinChange = context.coordinator.skin != skin
        let didFontChange = context.coordinator.editorFont.fontName != editorFont.fontName
            || context.coordinator.editorFont.pointSize != editorFont.pointSize
            || context.coordinator.editorSemiboldFont.fontName != editorSemiboldFont.fontName
            || context.coordinator.editorSemiboldFont.pointSize != editorSemiboldFont.pointSize
        let didWordWrapChange = context.coordinator.isWordWrapEnabled != isWordWrapEnabled
        let didAutocompleteModeChange = context.coordinator.autocompleteMode != autocompleteMode
        context.coordinator.language = language
        context.coordinator.skin = skin
        context.coordinator.indentWidth = indentWidth
        context.coordinator.autocompleteMode = autocompleteMode
        context.coordinator.textBinding = $text
        context.coordinator.editorFont = editorFont
        context.coordinator.editorSemiboldFont = editorSemiboldFont
        context.coordinator.onDidFocus = onDidFocus

        if didLanguageChange || didSkinChange || didFontChange {
            let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)
            context.coordinator.applyTheme(theme)
        }

        // Only reconfigure layout when word wrap state actually changes
        if didWordWrapChange {
            context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)
        }
        if didAutocompleteModeChange {
            context.coordinator.handleAutocompleteModeChange()
        }

        guard let textView = context.coordinator.textView else { return }
        if unsafe textView.window?.firstResponder as? NSTextView === textView {
            ActiveEditorTextViewRegistry.shared.register(textView)
        }
        let didTextChange = context.coordinator.syncWithBindingText(text)
        if didLanguageChange || didSkinChange || didFontChange || didTextChange || context.coordinator.requiresHighlightRefresh {
            context.coordinator.applyHighlighting()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let identifierPattern = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        private static let pythonFunctionPattern = try! NSRegularExpression(pattern: #"(?m)^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
        private static let pythonVariablePattern = try! NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)"#)
        private static let shellFunctionPattern = try! NSRegularExpression(pattern: #"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*(?:\(\s*\))?\s*\{"#)
        private static let shellVariablePattern = try! NSRegularExpression(pattern: #"(?m)(?:^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)="#)
        private static let shellVariableReferencePattern = try! NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)
        private static let powerShellFunctionPattern = try! NSRegularExpression(pattern: #"(?im)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b"#)
        private static let powerShellVariablePattern = try! NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)

        var textBinding: Binding<String>
        var language: EditorLanguage
        var skin: SkinDefinition
        var indentWidth: Int
        var autocompleteMode: EditorAutocompleteMode
        var editorFont: NSFont
        var editorSemiboldFont: NSFont
        var isWordWrapEnabled: Bool
        var onDidFocus: () -> Void
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var containerView: EditorContainerView?
        let gutterView = GutterView(frame: .zero)
        private var isApplyingHighlighting = false
        private var sourceText: String
        private(set) var requiresHighlightRefresh = true
        private var pendingEditedRange: NSRange?
        private let completionController = CompletionController()

        init(textBinding: Binding<String>, language: EditorLanguage, skin: SkinDefinition, indentWidth: Int, autocompleteMode: EditorAutocompleteMode, editorFont: NSFont, editorSemiboldFont: NSFont, isWordWrapEnabled: Bool, onDidFocus: @escaping () -> Void) {
            self.textBinding = textBinding
            self.language = language
            self.skin = skin
            self.indentWidth = indentWidth
            self.autocompleteMode = autocompleteMode
            self.editorFont = editorFont
            self.editorSemiboldFont = editorSemiboldFont
            self.isWordWrapEnabled = isWordWrapEnabled
            self.onDidFocus = onDidFocus
            self.sourceText = textBinding.wrappedValue
        }

        func attach(textView: NSTextView, scrollView: NSScrollView, containerView: EditorContainerView) {
            self.textView = textView
            self.scrollView = scrollView
            self.containerView = containerView
            gutterView.textView = textView
            completionController.attach(to: containerView)

            if let lineClickableTextView = textView as? LineClickableTextView {
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
                lineClickableTextView.indentWidth = indentWidth
                lineClickableTextView.autocompleteModeProvider = { [weak self] in
                    self?.autocompleteMode ?? .systemDefault
                }
                lineClickableTextView.isCompletionVisible = { [weak self] in
                    self?.completionController.isVisible ?? false
                }
                lineClickableTextView.requestCompletionUpdate = { [weak self] in
                    self?.refreshCompletionItems()
                }
                lineClickableTextView.cancelCompletions = { [weak self] in
                    self?.completionController.hide()
                }
                lineClickableTextView.moveCompletionSelection = { [weak self] delta in
                    self?.completionController.moveSelection(delta: delta) ?? false
                }
                lineClickableTextView.acceptSelectedCompletion = { [weak self] in
                    self?.acceptSelectedCompletion() ?? false
                }
                lineClickableTextView.didBecomeActive = { [weak self] in
                    self?.onDidFocus()
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            sourceText = textView.string
            textBinding.wrappedValue = sourceText

            // Live highlighting on the exact edited range — no debounce needed
            let editedRange = pendingEditedRange
            pendingEditedRange = nil
            applyHighlighting(in: editedRange)

            (textView as? LineClickableTextView)?.performAutomaticCompletionIfNeeded()
            gutterView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Capture the exact range being edited for live highlighting
            pendingEditedRange = affectedCharRange
            (textView as? LineClickableTextView)?.notePendingCompletionTrigger(
                replacementString: replacementString,
                affectedRange: affectedCharRange
            )
            return true
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard autocompleteMode == .systemDefault else { return [] }
            let source = textView.string as NSString
            guard charRange.location != NSNotFound,
                  NSMaxRange(charRange) <= source.length,
                  charRange.length > 0 else {
                return []
            }

            let partial = source.substring(with: charRange)
            guard partial.count >= 2 else { return [] }

            let reservedWords = reservedIdentifiers(for: language)
            let suggestions = completionCandidates(in: textView.string, partial: partial, excluding: reservedWords)
            guard !suggestions.isEmpty else { return [] }

            // Don't pre-select any item — prevents the popup from ghost-typing
            // the top match into the text while the user is still typing
            unsafe index?.pointee = -1
            return suggestions
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isApplyingHighlighting { return }
            refreshCompletionItems()
            textView?.needsDisplay = true
            gutterView.needsDisplay = true
        }

        func configureLayout(isWordWrapEnabled: Bool) {
            guard let textView = textView as? LineClickableTextView,
                  let textContainer = unsafe textView.textContainer,
                  let layoutManager = unsafe textView.layoutManager else { return }

            textContainer.heightTracksTextView = false
            
            // Calculate ~10 lines of extra bottom buffer
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 12))
            textView.extraBottomPadding = lineHeight * 10

            if isWordWrapEnabled {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.minSize = NSSize(width: 0, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textContainer.widthTracksTextView = true
                let availableWidth = max((scrollView?.contentSize.width ?? textView.bounds.width), 0)
                textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
                textView.frame.size.width = availableWidth
                scrollView?.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = [.width]
                textView.minSize = NSSize(width: 0, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textContainer.widthTracksTextView = false
                textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scrollView?.hasHorizontalScroller = true
            }

            layoutManager.ensureLayout(for: textContainer)
            textView.sizeToFit()

            let minimumWidth = max((scrollView?.contentSize.width ?? textView.bounds.width), 0)
            let minimumHeight = max((scrollView?.contentSize.height ?? textView.bounds.height), 0)
            if textView.frame.width < minimumWidth {
                textView.frame.size.width = minimumWidth
            }
            if textView.frame.height < minimumHeight {
                textView.frame.size.height = minimumHeight
            }
            textView.needsDisplay = true
        }

        func applyTheme(_ theme: SkinTheme) {
            guard let textView else { return }

            textView.font = editorFont
            textView.textColor = theme.baseColor
            textView.backgroundColor = theme.editorBackgroundColor
            textView.insertionPointColor = theme.baseColor
            textView.selectedTextAttributes = [
                .backgroundColor: theme.selectionColor,
                .foregroundColor: theme.baseColor
            ]
            if let lineClickableTextView = textView as? LineClickableTextView {
                lineClickableTextView.currentLineHighlightColor = theme.currentLineColor
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
                lineClickableTextView.indentWidth = indentWidth
            }
            scrollView?.backgroundColor = theme.editorBackgroundColor
            gutterView.theme = theme
            gutterView.needsDisplay = true
            completionController.theme = CompletionPopupTheme(theme: theme)
        }

        func syncWithBindingText(_ text: String) -> Bool {
            guard let textView else {
                sourceText = text
                return false
            }
            guard sourceText != text || textView.string != text else { return false }

            sourceText = text
            textView.string = text
            requiresHighlightRefresh = true
            return true
        }

        func applyHighlighting(in editedRange: NSRange? = nil) {
            guard let textView, let textStorage = unsafe textView.textStorage else { return }


            isApplyingHighlighting = true
            let selectedRanges = textView.selectedRanges
            textStorage.beginEditing()

            // When an edited range is provided (live typing), only highlight
            // a small window around the cursor. For large files, shrink it
            // further to keep keystrokes snappy.
            let highlightRange: NSRange
            let requestedHighlightRange: NSRange?
            if let range = editedRange {
                let expansion = textStorage.length > 50_000 ? 500 : 2000
                let start = max(range.location - expansion, 0)
                let end = min(range.location + range.length + expansion, textStorage.length)
                highlightRange = NSRange(location: start, length: end - start)
                requestedHighlightRange = highlightRange
            } else {
                // Full-document pass (initial load, theme/language change)
                highlightRange = NSRange(location: 0, length: textStorage.length)
                requestedHighlightRange = nil
            }

            SyntaxHighlighterFactory.makeHighlighter(
                for: language,
                skin: skin,
                editorFont: editorFont,
                semiboldFont: editorSemiboldFont
            )
            .apply(to: textStorage, text: textView.string, in: requestedHighlightRange)
            textStorage.edited(.editedAttributes, range: highlightRange, changeInLength: 0)

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges

            if let layoutManager = unsafe textView.layoutManager,
               let textContainer = unsafe textView.textContainer {
                layoutManager.invalidateDisplay(forCharacterRange: highlightRange)
                let glyphRange = unsafe layoutManager.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                textView.setNeedsDisplay(rect)
            } else {
                textView.needsDisplay = true
            }

            gutterView.needsDisplay = true
            isApplyingHighlighting = false
            requiresHighlightRefresh = false
        }

        @objc
        private func handleBoundsDidChange() {
            // Only redraw gutter if scroll position actually changed
            guard let scrollView,
                  scrollView.contentView.bounds.origin != gutterView.lastClipOrigin else {
                return
            }
            gutterView.needsDisplay = true
            completionController.reposition(anchorRect: completionAnchor()?.rect)
        }

        private func completionCandidates(in text: String, partial: String, excluding reservedWords: Set<String>) -> [String] {
            let partialLowercased = partial.lowercased()
            var seen = Set<String>()
            var prefixMatches: [String] = []

            for candidate in autocompleteSymbols(in: text, language: language) {
                guard candidate.count >= 2 else { continue }
                guard candidate != partial else { continue }
                guard !reservedWords.contains(candidate) else { continue }

                let candidateLowercased = candidate.lowercased()
                guard candidateLowercased.hasPrefix(partialLowercased) else { continue }
                guard seen.insert(candidate).inserted else { continue }

                prefixMatches.append(candidate)
            }

            return prefixMatches.sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard))
        }

        private func autocompleteSymbols(in text: String, language: EditorLanguage) -> [String] {
            switch language {
            case .python:
                let excludedRanges = pythonCommentAndStringRanges(in: text as NSString)
                return symbols(
                    in: text,
                    using: [
                        (Self.pythonFunctionPattern, 1),
                        (Self.pythonVariablePattern, 1)
                    ],
                    excluding: excludedRanges
                )
            case .shell:
                let excludedRanges = shellLikeCommentAndStringRanges(in: text as NSString)
                return symbols(
                    in: text,
                    using: [
                        (Self.shellFunctionPattern, 1),
                        (Self.shellVariablePattern, 1),
                        (Self.shellVariableReferencePattern, 1)
                    ],
                    excluding: excludedRanges
                )
            case .powerShell:
                let excludedRanges = shellLikeCommentAndStringRanges(in: text as NSString)
                return symbols(
                    in: text,
                    using: [
                        (Self.powerShellFunctionPattern, 1),
                        (Self.powerShellVariablePattern, 1)
                    ],
                    excluding: excludedRanges
                )
            default:
                let nsText = text as NSString
                return Self.identifierPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                    .map { nsText.substring(with: $0.range) }
            }
        }

        private func symbols(
            in text: String,
            using patterns: [(regex: NSRegularExpression, captureGroup: Int)],
            excluding excludedRanges: [NSRange]
        ) -> [String] {
            let nsText = text as NSString
            var seen = Set<String>()
            var results: [String] = []

            for (regex, captureGroup) in patterns {
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                for match in matches {
                    guard match.numberOfRanges > captureGroup else { continue }
                    let captureRange = match.range(at: captureGroup)
                    guard captureRange.location != NSNotFound, captureRange.length > 0 else { continue }
                    guard !excludedRanges.contains(where: { NSIntersectionRange($0, captureRange).length > 0 }) else { continue }

                    let candidate = nsText.substring(with: captureRange)
                    guard seen.insert(candidate).inserted else { continue }
                    results.append(candidate)
                }
            }

            return results
        }

        private func shellLikeCommentAndStringRanges(in text: NSString) -> [NSRange] {
            var excludedRanges: [NSRange] = []
            var index = 0
            let newline: unichar = 10
            let hash: unichar = 35
            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backslash: unichar = 92

            while index < text.length {
                let character = text.character(at: index)

                if character == hash {
                    let start = index
                    while index < text.length, text.character(at: index) != newline {
                        index += 1
                    }
                    excludedRanges.append(NSRange(location: start, length: index - start))
                    continue
                }

                if character == singleQuote || character == doubleQuote {
                    let delimiter = character
                    let start = index
                    index += 1

                    while index < text.length {
                        let current = text.character(at: index)
                        if current == delimiter {
                            index += 1
                            break
                        }
                        if delimiter == doubleQuote, current == backslash, index + 1 < text.length {
                            index += 2
                            continue
                        }
                        index += 1
                    }

                    excludedRanges.append(NSRange(location: start, length: index - start))
                    continue
                }

                index += 1
            }

            return excludedRanges
        }

        private func pythonCommentAndStringRanges(in text: NSString) -> [NSRange] {
            var excludedRanges: [NSRange] = []
            var index = 0
            let newline: unichar = 10
            let hash: unichar = 35
            let singleQuote: unichar = 39
            let doubleQuote: unichar = 34
            let backslash: unichar = 92

            while index < text.length {
                let character = text.character(at: index)

                if character == hash {
                    let start = index
                    while index < text.length, text.character(at: index) != newline {
                        index += 1
                    }
                    excludedRanges.append(NSRange(location: start, length: index - start))
                    continue
                }

                if character == singleQuote || character == doubleQuote {
                    let delimiter = character
                    let start = index
                    let isTripleQuoted = index + 2 < text.length
                        && text.character(at: index + 1) == delimiter
                        && text.character(at: index + 2) == delimiter

                    index += isTripleQuoted ? 3 : 1

                    while index < text.length {
                        if isTripleQuoted {
                            if index + 2 < text.length,
                               text.character(at: index) == delimiter,
                               text.character(at: index + 1) == delimiter,
                               text.character(at: index + 2) == delimiter {
                                index += 3
                                break
                            }
                            index += 1
                            continue
                        }

                        let current = text.character(at: index)
                        if current == delimiter {
                            index += 1
                            break
                        }
                        if current == backslash, index + 1 < text.length {
                            index += 2
                            continue
                        }
                        index += 1
                    }

                    excludedRanges.append(NSRange(location: start, length: index - start))
                    continue
                }

                index += 1
            }

            return excludedRanges
        }

        func handleAutocompleteModeChange() {
            guard autocompleteMode == .custom else {
                completionController.hide()
                return
            }
            refreshCompletionItems()
        }

        private func refreshCompletionItems() {
            guard autocompleteMode == .custom,
                  let lineClickableTextView = textView as? LineClickableTextView else {
                completionController.hide()
                return
            }

            guard let completionState = completionState(for: lineClickableTextView) else {
                completionController.hide()
                return
            }

            completionController.show(
                items: completionState.items,
                anchorRect: completionState.anchorRect,
                placement: completionState.placement
            )
        }

        private func acceptSelectedCompletion() -> Bool {
            guard autocompleteMode == .custom,
                  let lineClickableTextView = textView as? LineClickableTextView,
                  let selectedItem = completionController.selectedItem else {
                return false
            }

            let didApply = lineClickableTextView.applyCompletion(selectedItem.text)
            if didApply {
                completionController.hide()
            }
            return didApply
        }

        private func completionState(for textView: LineClickableTextView) -> (items: [CompletionItem], anchorRect: NSRect, placement: CompletionPopupPlacement)? {
            guard let partialRange = textView.currentPartialWordRange(),
                  partialRange.length >= 2 else {
                return nil
            }

            let source = textView.string as NSString
            guard NSMaxRange(partialRange) <= source.length else { return nil }

            let partial = source.substring(with: partialRange)
            let reservedWords = reservedIdentifiers(for: language)
            let candidates = completionCandidates(in: textView.string, partial: partial, excluding: reservedWords)
            guard !candidates.isEmpty, let anchor = completionAnchor() else { return nil }
            return (candidates.map(CompletionItem.init(text:)), anchor.rect, anchor.placement)
        }

        private func completionAnchor() -> (rect: NSRect, placement: CompletionPopupPlacement)? {
            guard let textView,
                  let containerView,
                  let anchor = caretRectInTextViewCoordinates() else {
                return nil
            }
            return (containerView.convert(anchor.rect, from: textView), anchor.placement)
        }

        private func caretRectInTextViewCoordinates() -> (rect: NSRect, placement: CompletionPopupPlacement)? {
            guard let textView,
                  let layoutManager = unsafe textView.layoutManager,
                  let textContainer = unsafe textView.textContainer else {
                return nil
            }

            let textLength = (textView.string as NSString).length
            let insertionLocation = min(textView.selectedRange().location, textLength)
            if insertionLocation == textLength, layoutManager.numberOfGlyphs > 0 {
                let lastGlyphIndex = max(layoutManager.numberOfGlyphs - 1, 0)
                var lineRect = unsafe layoutManager.lineFragmentRect(
                    forGlyphAt: lastGlyphIndex,
                    effectiveRange: nil,
                    withoutAdditionalLayout: true
                )
                lineRect.origin.x += textView.textContainerInset.width
                lineRect.origin.y += textView.textContainerInset.height
                lineRect.size.width = max(lineRect.width, 2)
                let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular))
                lineRect.size.height = max(lineRect.height, lineHeight)
                return (lineRect, .aboveLine)
            }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: insertionLocation)
            var glyphRange = NSRange(location: glyphIndex, length: 0)
            if glyphIndex < layoutManager.numberOfGlyphs {
                glyphRange.length = 1
            }

            var caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if caretRect.isEmpty {
                return nil
            }

            caretRect.origin.x += textView.textContainerInset.width
            caretRect.origin.y += textView.textContainerInset.height
            caretRect.size.width = max(caretRect.width, 2)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular))
            caretRect.size.height = max(caretRect.height, lineHeight)
            return (caretRect, .belowLine)
        }

        private func reservedIdentifiers(for language: EditorLanguage) -> Set<String> {
            switch language {
            case .plainText:
                return []
            case .shell:
                return [
                    "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until",
                    "case", "esac", "in", "function", "select", "time", "coproc", "return",
                    "break", "continue", "exit", "local", "readonly", "declare", "typeset"
                ]
            case .dotenv:
                return []
            case .python:
                return [
                    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
                    "class", "continue", "def", "del", "elif", "else", "except", "finally",
                    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
                    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"
                ]
            case .powerShell:
                return [
                    "if", "else", "elseif", "switch", "foreach", "for", "while", "do", "until",
                    "break", "continue", "return", "function", "filter", "param", "begin",
                    "process", "end", "trap", "throw", "try", "catch", "finally", "class"
                ]
            case .xml, .json:
                return []
            }
        }
    }
}

final class LineClickableTextView: NSTextView {
    var currentLineHighlightColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var lineCommentPrefix: String?
    var indentWidth = 4
    var extraBottomPadding: CGFloat = 0
    private var isAdjustingFrame = false
    private var shouldTriggerAutomaticCompletion = false
    private var isApplyingAcceptedCompletion = false
    private var completionTimer: Timer?
    var requestCompletionUpdate: (() -> Void)?
    var cancelCompletions: (() -> Void)?
    var isCompletionVisible: (() -> Bool)?
    var moveCompletionSelection: ((Int) -> Bool)?
    var acceptSelectedCompletion: (() -> Bool)?
    var autocompleteModeProvider: (() -> EditorAutocompleteMode)?
    var didBecomeActive: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        guard !isAdjustingFrame else {
            super.setFrameSize(newSize)
            return
        }
        guard extraBottomPadding > 0 else {
            super.setFrameSize(newSize)
            return
        }
        isAdjustingFrame = true
        var adjusted = newSize
        adjusted.height += extraBottomPadding
        super.setFrameSize(adjusted)
        isAdjustingFrame = false
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        ActiveEditorTextViewRegistry.shared.register(self)
        didBecomeActive?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        ActiveEditorTextViewRegistry.shared.register(self)
        didBecomeActive?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command], event.charactersIgnoringModifiers == "/" {
            toggleLineComment()
            return
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "]" {
            indentSelection()
            return
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "[" {
            outdentSelection()
            return
        }
        if modifiers.isEmpty, handleCompletionKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    func toggleLineComment() {
        guard let lineCommentPrefix else { return }

        let nsText = string as NSString
        let selectedRange = selectedRange()
        let lineRange = nsText.lineRange(for: selectedRange)
        let block = nsText.substring(with: lineRange)
        let originalHasTrailingNewline = block.hasSuffix("\n")
        let lines = block.components(separatedBy: "\n")
        let lineCount = originalHasTrailingNewline ? max(lines.count - 1, 0) : lines.count
        guard lineCount > 0 else { return }

        let activeLines = Array(lines.prefix(lineCount))
        let shouldUncomment = activeLines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            && activeLines.allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return true }
                return lineHasCommentPrefix(line, prefix: lineCommentPrefix)
            }

        let updatedActiveLines = activeLines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return shouldUncomment
                ? uncommentedLine(from: line, prefix: lineCommentPrefix)
                : commentedLine(from: line, prefix: lineCommentPrefix)
        }

        var updatedLines = updatedActiveLines
        if originalHasTrailingNewline {
            updatedLines.append("")
        }
        let replacement = updatedLines.joined(separator: "\n")

        guard shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        unsafe textStorage?.beginEditing()
        unsafe textStorage?.replaceCharacters(in: lineRange, with: replacement)
        unsafe textStorage?.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    func indentSelection() {
        adjustIndentation(outdent: false)
    }

    func outdentSelection() {
        adjustIndentation(outdent: true)
    }

    private func adjustIndentation(outdent: Bool) {
        let nsText = string as NSString
        let selectedRange = selectedRange()
        let lineRange = nsText.lineRange(for: selectedRange)
        let block = nsText.substring(with: lineRange)
        let originalHasTrailingNewline = block.hasSuffix("\n")
        let lines = block.components(separatedBy: "\n")
        let lineCount = originalHasTrailingNewline ? max(lines.count - 1, 0) : lines.count
        guard lineCount > 0 else { return }

        let indentUnit = String(repeating: " ", count: max(indentWidth, 1))
        let updatedActiveLines = lines.prefix(lineCount).map { line in
            if outdent {
                if line.hasPrefix(indentUnit) {
                    return String(line.dropFirst(indentUnit.count))
                }
                if line.hasPrefix("\t") {
                    return String(line.dropFirst())
                }
                let leadingSpaces = line.prefix { $0 == " " }
                let removalCount = min(leadingSpaces.count, indentUnit.count)
                return String(line.dropFirst(removalCount))
            }

            return indentUnit + line
        }

        var updatedLines = Array(updatedActiveLines)
        if originalHasTrailingNewline {
            updatedLines.append("")
        }
        let replacement = updatedLines.joined(separator: "\n")

        guard shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        unsafe textStorage?.beginEditing()
        unsafe textStorage?.replaceCharacters(in: lineRange, with: replacement)
        unsafe textStorage?.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func lineHasCommentPrefix(_ line: String, prefix: String) -> Bool {
        let indentationEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        return line[indentationEnd...].hasPrefix(prefix)
    }

    private func commentedLine(from line: String, prefix: String) -> String {
        let indentationEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        var updated = String(line[..<indentationEnd])
        updated += prefix
        if indentationEnd != line.endIndex {
            updated += " "
            updated += line[indentationEnd...]
        }
        return updated
    }

    private func uncommentedLine(from line: String, prefix: String) -> String {
        let indentationEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        var updated = String(line[..<indentationEnd])
        let remainder = line[indentationEnd...]
        guard remainder.hasPrefix(prefix) else { return line }

        var dropCount = prefix.count
        let afterPrefixIndex = remainder.index(remainder.startIndex, offsetBy: prefix.count)
        if afterPrefixIndex < remainder.endIndex, remainder[afterPrefixIndex] == " " {
            dropCount += 1
        }
        updated += remainder.dropFirst(dropCount)
        return updated
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            ActiveEditorTextViewRegistry.shared.register(self)
            didBecomeActive?()
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            cancelCompletionTimer()
            cancelCompletions?()
        }
        return didResignFirstResponder
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isApplyingAcceptedCompletion = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag {
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingAcceptedCompletion = false
            }
        } else {
            isApplyingAcceptedCompletion = false
        }
    }

    override func insertNewline(_ sender: Any?) {
        if isCompletionVisible?() == true, acceptSelectedCompletion?() == true {
            return
        }
        let indentation = currentLineLeadingWhitespaceForInsertion()
        super.insertNewline(sender)
        guard !indentation.isEmpty else { return }
        super.insertText(indentation, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if isCompletionVisible?() == true, acceptSelectedCompletion?() == true {
            return
        }
        if selectedRange().length > 0 {
            indentSelection()
            return
        }
        super.insertTab(sender)
    }

    override func moveUp(_ sender: Any?) {
        if isCompletionVisible?() == true, moveCompletionSelection?(-1) == true {
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if isCompletionVisible?() == true, moveCompletionSelection?(1) == true {
            return
        }
        super.moveDown(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if isCompletionVisible?() == true {
            cancelCompletions?()
            return
        }
        super.cancelOperation(sender)
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        super.deleteForward(sender)
    }

    func notePendingCompletionTrigger(replacementString: String?, affectedRange: NSRange) {
        guard autocompleteModeProvider?() != .off else {
            cancelCompletionTimer()
            cancelCompletions?()
            return
        }

        guard !isApplyingAcceptedCompletion else {
            cancelCompletionTimer()
            shouldTriggerAutomaticCompletion = false
            return
        }

        guard affectedRange.length == 0,
              let replacementString,
              replacementString.count == 1,
              let scalar = replacementString.unicodeScalars.first else {
            cancelCompletionTimer()
            shouldTriggerAutomaticCompletion = false
            return
        }

        let isValidChar = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar)
        if isValidChar {
            // Reset debounce timer on each valid character — only show completions after a pause
            scheduleCompletionAfterPause()
        } else {
            cancelCompletionTimer()
            shouldTriggerAutomaticCompletion = false
            cancelCompletions?()
        }
    }

    func performAutomaticCompletionIfNeeded() {
        if isCompletionVisible?() == true {
            requestCompletionUpdate?()
        }
    }

    private func scheduleCompletionAfterPause() {
        cancelCompletionTimer()
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.showCompletionIfReady()
            }
        }
    }

    private func cancelCompletionTimer() {
        completionTimer?.invalidate()
        completionTimer = nil
    }

    private func showCompletionIfReady() {
        guard !isApplyingAcceptedCompletion,
              selectedRange().length == 0,
              currentPartialWordRange()?.length ?? 0 >= 2 else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  unsafe self.window?.firstResponder === self,
                  !self.isApplyingAcceptedCompletion,
                  self.currentPartialWordRange()?.length ?? 0 >= 2 else {
                return
            }
            switch self.autocompleteModeProvider?() ?? .systemDefault {
            case .off:
                self.cancelCompletions?()
            case .systemDefault:
                self.complete(nil)
            case .custom:
                self.requestCompletionUpdate?()
            }
        }
    }

    private func currentLineLeadingWhitespaceForInsertion() -> String {
        let nsText = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound else { return "" }

        let location = min(selection.location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        guard lineRange.location != NSNotFound, lineRange.length > 0 else { return "" }

        let line = nsText.substring(with: lineRange)
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    func currentPartialWordRange() -> NSRange? {
        let nsText = string as NSString
        let selection = selectedRange()
        guard selection.length == 0,
              selection.location != NSNotFound,
              selection.location <= nsText.length else {
            return nil
        }

        let identifierSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = selection.location
        while start > 0 {
            let scalar = nsText.substring(with: NSRange(location: start - 1, length: 1)).unicodeScalars.first
            guard let scalar, identifierSet.contains(scalar) else { break }
            start -= 1
        }

        let length = selection.location - start
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    func applyCompletion(_ word: String) -> Bool {
        guard let partialRange = currentPartialWordRange() else { return false }

        cancelCompletionTimer()
        isApplyingAcceptedCompletion = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingAcceptedCompletion = false
            }
        }

        guard shouldChangeText(in: partialRange, replacementString: word) else { return false }
        unsafe textStorage?.beginEditing()
        unsafe textStorage?.replaceCharacters(in: partialRange, with: word)
        unsafe textStorage?.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: partialRange.location + (word as NSString).length, length: 0))
        return true
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard isCompletionVisible?() == true else { return false }

        switch event.keyCode {
        case 53:
            cancelCompletions?()
            return true
        default:
            return false
        }
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        guard currentLineHighlightColor.alphaComponent > 0,
              let layoutManager = unsafe layoutManager else {
            return
        }

        let highlightRect = currentLineHighlightRect(layoutManager: layoutManager)
        guard highlightRect.intersects(dirtyRect) else { return }

        currentLineHighlightColor.setFill()
        highlightRect.fill()
    }

    private func currentLineHighlightRect(layoutManager: NSLayoutManager) -> NSRect {
        let insertionLocation = min(selectedRange().location, string.count)

        if insertionLocation == string.count, !layoutManager.extraLineFragmentRect.isEmpty {
            let extraRect = layoutManager.extraLineFragmentRect
            return NSRect(
                x: 0,
                y: extraRect.minY + textContainerInset.height,
                width: bounds.width,
                height: extraRect.height
            )
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: insertionLocation)
        let lineRect = unsafe layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        return NSRect(
            x: 0,
            y: lineRect.minY + textContainerInset.height,
            width: bounds.width,
            height: lineRect.height
        )
    }
}

final class EditorContainerView: NSView {
    private let gutterWidth: CGFloat = 56
    private var gutterView: GutterView?
    private var scrollView: NSScrollView?
    private let completionPopupView = CompletionPopupView()

    func embed(gutterView: GutterView, scrollView: NSScrollView) {
        self.gutterView?.removeFromSuperview()
        self.scrollView?.removeFromSuperview()

        self.gutterView = gutterView
        self.scrollView = scrollView

        addSubview(gutterView)
        addSubview(scrollView)
        addSubview(completionPopupView)
        completionPopupView.isHidden = true
    }

    override func layout() {
        super.layout()

        guard let gutterView, let scrollView else { return }
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
        completionPopupView.constrainFrame(to: bounds, minimumX: gutterWidth + 8)
    }

    fileprivate func updateCompletionPopup(items: [CompletionItem], selectedIndex: Int, anchorRect: NSRect, placement: CompletionPopupPlacement, theme: CompletionPopupTheme) {
        completionPopupView.theme = theme
        completionPopupView.items = items
        completionPopupView.selectedIndex = selectedIndex
        completionPopupView.sizeToFitContent()

        let popupWidth = completionPopupView.frame.width
        let popupHeight = completionPopupView.frame.height
        let minimumX = gutterWidth + 8
        let maximumX = bounds.maxX - popupWidth - 8
        let originX = min(max(anchorRect.minX, minimumX), max(minimumX, maximumX))
        let preferredOriginY: CGFloat
        switch placement {
        case .belowLine:
            preferredOriginY = anchorRect.minY - popupHeight - 4
        case .aboveLine:
            preferredOriginY = anchorRect.maxY + 4
        }
        var originY = preferredOriginY

        if originY < bounds.minY + 8 {
            originY = min(bounds.maxY - popupHeight - 8, anchorRect.maxY + 4)
        } else if originY + popupHeight > bounds.maxY - 8 {
            originY = max(bounds.minY + 8, anchorRect.minY - popupHeight - 4)
        }

        completionPopupView.frame = NSRect(x: originX, y: originY, width: popupWidth, height: popupHeight)
        completionPopupView.isHidden = false
        completionPopupView.needsDisplay = true
    }

    fileprivate func hideCompletionPopup() {
        completionPopupView.isHidden = true
    }
}

private struct CompletionItem: Equatable, Identifiable {
    let text: String

    var id: String { text }
}

private enum CompletionPopupPlacement {
    case belowLine
    case aboveLine
}

private struct CompletionPopupTheme {
    let backgroundColor: NSColor
    let borderColor: NSColor
    let textColor: NSColor
    let selectedBackgroundColor: NSColor
    let selectedTextColor: NSColor

    init(theme: SkinTheme) {
        backgroundColor = theme.editorBackgroundColor.blended(withFraction: 0.08, of: .white) ?? theme.editorBackgroundColor
        borderColor = theme.gutterBorderColor
        textColor = theme.baseColor
        selectedBackgroundColor = theme.selectionColor
        selectedTextColor = theme.baseColor
    }

    static let fallback = CompletionPopupTheme(theme: .fallback)
}

@MainActor
private final class CompletionController {
    weak var containerView: EditorContainerView?
    var theme = CompletionPopupTheme.fallback
    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    private var lastAnchorRect: NSRect?
    private var placement: CompletionPopupPlacement = .belowLine

    var isVisible: Bool {
        !items.isEmpty
    }

    var selectedItem: CompletionItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func attach(to containerView: EditorContainerView) {
        self.containerView = containerView
    }

    func show(items: [CompletionItem], anchorRect: NSRect, placement: CompletionPopupPlacement) {
        guard !items.isEmpty else {
            hide()
            return
        }

        if self.items != items {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        }
        self.items = items
        lastAnchorRect = anchorRect
        self.placement = placement

        containerView?.updateCompletionPopup(
            items: items,
            selectedIndex: selectedIndex,
            anchorRect: anchorRect,
            placement: placement,
            theme: theme
        )
    }

    func hide() {
        items = []
        selectedIndex = 0
        lastAnchorRect = nil
        containerView?.hideCompletionPopup()
    }

    func moveSelection(delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
        reposition(anchorRect: nil)
        return true
    }

    func reposition(anchorRect: NSRect?) {
        guard !items.isEmpty, let containerView else { return }
        let nextAnchorRect = anchorRect ?? lastAnchorRect ?? containerView.bounds.insetBy(dx: 8, dy: 8)
        lastAnchorRect = nextAnchorRect
        containerView.updateCompletionPopup(
            items: items,
            selectedIndex: selectedIndex,
            anchorRect: nextAnchorRect,
            placement: placement,
            theme: theme
        )
    }
}

private final class CompletionPopupView: NSView {
    private let rowHeight: CGFloat = 26
    private let maxVisibleRows = 8
    var theme = CompletionPopupTheme.fallback {
        didSet { needsDisplay = true }
    }
    var items: [CompletionItem] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    func sizeToFitContent() {
        let visibleRowCount = max(1, min(items.count, maxVisibleRows))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        let widestLabel = items.map { ($0.text as NSString).size(withAttributes: attributes).width }.max() ?? 120
        let width = min(max(180, ceil(widestLabel) + 28), 360)
        frame.size = NSSize(width: width, height: CGFloat(visibleRowCount) * rowHeight + 8)
    }

    func constrainFrame(to visibleRect: NSRect, minimumX: CGFloat) {
        guard !isHidden else { return }
        var nextFrame = frame
        nextFrame.origin.x = min(max(nextFrame.origin.x, minimumX), max(minimumX, visibleRect.maxX - nextFrame.width - 8))
        nextFrame.origin.y = min(max(nextFrame.origin.y, visibleRect.minY + 8), max(visibleRect.minY + 8, visibleRect.maxY - nextFrame.height - 8))
        frame = nextFrame
    }

    override func draw(_ dirtyRect: NSRect) {
        let popupBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let backgroundPath = NSBezierPath(roundedRect: popupBounds, xRadius: 8, yRadius: 8)
        theme.backgroundColor.setFill()
        backgroundPath.fill()
        theme.borderColor.setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        let visibleItems = Array(items.prefix(maxVisibleRows))
        for (index, item) in visibleItems.enumerated() {
            let rowRect = NSRect(x: 4, y: 4 + CGFloat(index) * rowHeight, width: bounds.width - 8, height: rowHeight)
            if index == selectedIndex {
                let selectionPath = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
                theme.selectedBackgroundColor.setFill()
                selectionPath.fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: index == selectedIndex ? theme.selectedTextColor : theme.textColor
            ]
            let textRect = rowRect.insetBy(dx: 10, dy: 5)
            (item.text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}

final class GutterView: NSView {
    weak var textView: NSTextView?
    var theme = SkinTheme.fallback {
        didSet { needsDisplay = true }
    }
    
    // Cache for scroll offset to avoid redundant redraws
    var lastClipOrigin: CGPoint = .zero

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = unsafe textView.layoutManager,
              let textContainer = unsafe textView.textContainer,
              let scrollView = textView.enclosingScrollView else {
            return
        }

        theme.gutterBackgroundColor.setFill()
        bounds.fill()

        let borderRect = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        theme.gutterBorderColor.setFill()
        borderRect.fill()

        let clipOrigin = scrollView.contentView.bounds.origin
        let visibleRect = NSRect(origin: clipOrigin, size: scrollView.contentView.bounds.size)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        let selectedLine = selectedLineNumber(in: textView)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        var glyphIndex = visibleGlyphRange.location
        var lineNumber = lineNumber(atGlyphIndex: glyphIndex, layoutManager: layoutManager, text: text)

        while glyphIndex < NSMaxRange(visibleGlyphRange), glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphRange = NSRange()
            let lineRect = unsafe layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let y = lineRect.minY - clipOrigin.y + textView.textContainerInset.height
            let height = max(lineRect.height, layoutManager.defaultLineHeight(for: textView.font ?? theme.font))

            if lineNumber == selectedLine {
                theme.gutterCurrentLineColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.font,
                .foregroundColor: lineNumber == selectedLine ? theme.gutterCurrentLineNumberColor : theme.gutterTextColor,
                .paragraphStyle: paragraph
            ]
            let label = NSAttributedString(string: "\(lineNumber)", attributes: attributes)
            label.draw(in: NSRect(x: 16, y: y + 1, width: bounds.width - 24, height: height))

            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNumber += lineCount(in: lineRange, text: text)
        }

        drawExtraLineFragmentIfNeeded(
            layoutManager: layoutManager,
            clipOrigin: clipOrigin,
            selectedLine: selectedLine,
            lineNumber: lineNumber
        )
        
        // Update cache
        lastClipOrigin = clipOrigin
    }

    private func selectedLineNumber(in textView: NSTextView) -> Int {
        let text = textView.string as NSString
        return lineNumber(atCharacterIndex: min(textView.selectedRange().location, text.length), text: text)
    }

    private func lineNumber(atGlyphIndex glyphIndex: Int, layoutManager: NSLayoutManager, text: NSString) -> Int {
        let characterIndex = min(layoutManager.characterIndexForGlyph(at: glyphIndex), text.length)
        return lineNumber(atCharacterIndex: characterIndex, text: text)
    }

    private func lineNumber(atCharacterIndex characterIndex: Int, text: NSString) -> Int {
        if characterIndex <= 0 { return 1 }

        var count = 1
        var searchRange = NSRange(location: 0, length: min(characterIndex, text.length))
        while searchRange.length > 0 {
            let newlineRange = text.range(of: "\n", options: [], range: searchRange)
            if newlineRange.location == NSNotFound { break }
            count += 1
            let next = NSMaxRange(newlineRange)
            searchRange = NSRange(location: next, length: max(0, characterIndex - next))
        }
        return count
    }

    private func lineCount(in lineRange: NSRange, text: NSString) -> Int {
        let substring = text.substring(with: lineRange)
        let newlineCount = substring.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        return max(newlineCount, 1)
    }


    private func drawExtraLineFragmentIfNeeded(
        layoutManager: NSLayoutManager,
        clipOrigin: NSPoint,
        selectedLine: Int,
        lineNumber: Int
    ) {
        let extraLineRect = layoutManager.extraLineFragmentRect
        guard !extraLineRect.isEmpty else { return }

        let y = extraLineRect.minY - clipOrigin.y + (textView?.textContainerInset.height ?? 0)
        let height = extraLineRect.height
        guard y + height >= 0, y <= bounds.height else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        if lineNumber == selectedLine {
            theme.gutterCurrentLineColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.font,
            .foregroundColor: lineNumber == selectedLine ? theme.gutterCurrentLineNumberColor : theme.gutterTextColor,
            .paragraphStyle: paragraph
        ]
        let label = NSAttributedString(string: "\(lineNumber)", attributes: attributes)
        label.draw(in: NSRect(x: 16, y: y + 1, width: bounds.width - 24, height: height))
    }
}
