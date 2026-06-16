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
    private let textViews = NSHashTable<LineClickableTextView>.weakObjects()

    func track(_ textView: LineClickableTextView) {
        textViews.add(textView)
    }

    func register(_ textView: NSTextView) {
        self.textView = textView
        if let lineClickableTextView = textView as? LineClickableTextView {
            track(lineClickableTextView)
        }
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

    func flushPendingModelSync() {
        guard let textView = textView as? LineClickableTextView,
              textView.hasPendingModelSync?() == true else { return }
        textView.flushPendingModelSync?()
    }

    func flushAllPendingModelSync() {
        for textView in textViews.allObjects {
            guard textView.hasPendingModelSync?() == true else { continue }
            textView.flushPendingModelSync?()
        }
    }

    func undoManager(for editorID: String) -> UndoManager? {
        lineClickableTextView(for: editorID)?.undoManager
    }

    func replaceTextWithUndo(for editorID: String, replacement: String, actionName: String) -> Bool {
        guard let textView = lineClickableTextView(for: editorID) else { return false }
        return textView.replaceAllTextPreservingUndo(with: replacement, actionName: actionName)
    }

    private func lineClickableTextView(for editorID: String) -> LineClickableTextView? {
        if let activeTextView = textView as? LineClickableTextView,
           activeTextView.editorID == editorID {
            return activeTextView
        }

        return textViews.allObjects.first { $0.editorID == editorID }
    }
}

private struct GutterLineIndex {
    private var lineStarts: [Int] = [0]
    private var lineLengths: [Int] = [0]
    private var maxLineLength = 0

    var lineCount: Int {
        max(lineStarts.count, 1)
    }

    var maximumLineLength: Int {
        max(maxLineLength, 1)
    }

    mutating func rebuild(with text: NSString) {
        lineStarts = [0]
        lineLengths = []
        maxLineLength = 0
        guard text.length > 0 else {
            lineLengths = [0]
            return
        }

        var location = 0
        while location < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            unsafe text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let lineLength = max(contentsEnd - location, 0)
            lineLengths.append(lineLength)
            maxLineLength = max(maxLineLength, lineLength)

            if lineEnd >= text.length {
                if lineEnd > contentsEnd {
                    lineStarts.append(text.length)
                    lineLengths.append(0)
                }
                break
            }

            lineStarts.append(lineEnd)
            location = lineEnd
        }
    }

    mutating func applyEdit(range: NSRange, replacement: NSString) {
        lineLengths = []
        let lowerBound = upperBound(of: range.location)
        let upperBound = upperBound(of: NSMaxRange(range))
        if lowerBound < upperBound {
            lineStarts.removeSubrange(lowerBound..<upperBound)
        }

        let insertedLineStarts = Self.lineStarts(in: replacement, offset: range.location)
        if !insertedLineStarts.isEmpty {
            lineStarts.insert(contentsOf: insertedLineStarts, at: lowerBound)
        }

        let delta = replacement.length - range.length
        if delta != 0 {
            let shiftStart = lowerBound + insertedLineStarts.count
            for index in shiftStart..<lineStarts.count {
                lineStarts[index] += delta
            }
        }
        maxLineLength = max(maxLineLength, Self.maximumLineLength(in: replacement))
    }

    func lineNumber(atCharacterIndex characterIndex: Int, textLength: Int) -> Int {
        let clampedIndex = min(max(characterIndex, 0), textLength)
        return max(upperBound(of: clampedIndex), 1)
    }

    func estimatedVisualLineCount(charactersPerLine: Int, textLength: Int) -> Int {
        let charactersPerLine = max(charactersPerLine, 1)
        guard textLength > 0 else { return 1 }

        if lineLengths.count == lineStarts.count {
            return lineLengths.reduce(0) { count, lineLength in
                count + max(Int(ceil(Double(max(lineLength, 1)) / Double(charactersPerLine))), 1)
            }
        }

        var count = 0
        for index in lineStarts.indices {
            let start = lineStarts[index]
            let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : textLength
            let lineLength = max(end - start, 0)
            count += max(Int(ceil(Double(max(lineLength, 1)) / Double(charactersPerLine))), 1)
        }
        return max(count, 1)
    }

    private func upperBound(of value: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count

        while lower < upper {
            let mid = (lower + upper) / 2
            if lineStarts[mid] <= value {
                lower = mid + 1
            } else {
                upper = mid
            }
        }

        return lower
    }

    private static func lineStarts(in text: NSString, offset: Int) -> [Int] {
        guard text.length > 0 else { return [] }

        var starts: [Int] = []
        var location = 0

        while location < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            unsafe text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))

            if lineEnd >= text.length {
                if lineEnd > contentsEnd {
                    starts.append(offset + text.length)
                }
                break
            }

            starts.append(offset + lineEnd)
            location = lineEnd
        }

        return starts
    }

    private static func maximumLineLength(in text: NSString) -> Int {
        guard text.length > 0 else { return 0 }

        var maximumLength = 0
        var location = 0
        while location < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            unsafe text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            maximumLength = max(maximumLength, max(contentsEnd - location, 0))
            if lineEnd >= text.length {
                break
            }
            location = lineEnd
        }
        return maximumLength
    }
}

struct CodeEditorView: NSViewRepresentable {
    let editorID: String
    @Binding var text: String
    @Binding var scrollPosition: EditorScrollPosition?
    let isWordWrapEnabled: Bool
    let isSyntaxHighlightingEnabled: Bool
    let showsInvisibleCharacters: Bool
    let skin: SkinDefinition
    let language: EditorLanguage
    let indentation: EditorIndentationSettings
    let autocompleteMode: EditorAutocompleteMode
    let editorFont: NSFont
    let editorSemiboldFont: NSFont
    let onDidFocus: () -> Void
    let onTextChange: (String) -> Void

    init(
        editorID: String,
        text: Binding<String>,
        scrollPosition: Binding<EditorScrollPosition?>,
        isWordWrapEnabled: Bool,
        isSyntaxHighlightingEnabled: Bool,
        showsInvisibleCharacters: Bool,
        skin: SkinDefinition,
        language: EditorLanguage,
        indentation: EditorIndentationSettings,
        autocompleteMode: EditorAutocompleteMode,
        editorFont: NSFont,
        editorSemiboldFont: NSFont,
        onDidFocus: @escaping () -> Void,
        onTextChange: @escaping (String) -> Void = { _ in }
    ) {
        self.editorID = editorID
        self._text = text
        self._scrollPosition = scrollPosition
        self.isWordWrapEnabled = isWordWrapEnabled
        self.isSyntaxHighlightingEnabled = isSyntaxHighlightingEnabled
        self.showsInvisibleCharacters = showsInvisibleCharacters
        self.skin = skin
        self.language = language
        self.indentation = indentation
        self.autocompleteMode = autocompleteMode
        self.editorFont = editorFont
        self.editorSemiboldFont = editorSemiboldFont
        self.onDidFocus = onDidFocus
        self.onTextChange = onTextChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            textBinding: $text,
            scrollPosition: $scrollPosition,
            language: language,
            skin: skin,
            indentation: indentation,
            autocompleteMode: autocompleteMode,
            isSyntaxHighlightingEnabled: isSyntaxHighlightingEnabled,
            showsInvisibleCharacters: showsInvisibleCharacters,
            editorFont: editorFont,
            editorSemiboldFont: editorSemiboldFont,
            isWordWrapEnabled: isWordWrapEnabled,
            onDidFocus: onDidFocus,
            onTextChange: onTextChange
        )
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)
        let container = EditorContainerView()
        let textView = LineClickableTextView()
        let effectiveWordWrapEnabled = isWordWrapEnabled

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
        textView.editorID = editorID
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.allowsUndo = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        unsafe textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text
        let documentView = PaddedEditorDocumentView(textView: textView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !effectiveWordWrapEnabled
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = theme.editorBackgroundColor
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        container.embed(gutterView: context.coordinator.gutterView, scrollView: scrollView)
        context.coordinator.attach(
            textView: textView,
            documentView: documentView,
            scrollView: scrollView,
            containerView: container
        )
        context.coordinator.applyTheme(theme)
        context.coordinator.applyInvisibleCharacterVisibility()
        context.coordinator.isWordWrapEnabled = effectiveWordWrapEnabled
        context.coordinator.configureLayout(isWordWrapEnabled: effectiveWordWrapEnabled)
        context.coordinator.restoreInitialScrollPosition()
        documentView.requestInitialFocus()
        DispatchQueue.main.async {
            context.coordinator.enableNonContiguousLayout()
            if isSyntaxHighlightingEnabled {
                context.coordinator.applyHighlighting()
            } else {
                context.coordinator.markHighlightingCurrent()
            }
        }

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let effectiveWordWrapEnabled = isWordWrapEnabled
        let didLanguageChange = context.coordinator.language != language
        let didSkinChange = context.coordinator.skin != skin
        let didFontChange = context.coordinator.editorFont.fontName != editorFont.fontName
            || context.coordinator.editorFont.pointSize != editorFont.pointSize
            || context.coordinator.editorSemiboldFont.fontName != editorSemiboldFont.fontName
            || context.coordinator.editorSemiboldFont.pointSize != editorSemiboldFont.pointSize
        let didWordWrapChange = context.coordinator.isWordWrapEnabled != effectiveWordWrapEnabled
        let didIndentationChange = context.coordinator.indentation != indentation
        let didAutocompleteModeChange = context.coordinator.autocompleteMode != autocompleteMode
        let didSyntaxHighlightingChange = context.coordinator.isSyntaxHighlightingEnabled != isSyntaxHighlightingEnabled
        let didInvisibleCharacterVisibilityChange = context.coordinator.showsInvisibleCharacters != showsInvisibleCharacters
        context.coordinator.language = language
        context.coordinator.skin = skin
        context.coordinator.indentation = indentation
        context.coordinator.autocompleteMode = autocompleteMode
        context.coordinator.isSyntaxHighlightingEnabled = isSyntaxHighlightingEnabled
        context.coordinator.showsInvisibleCharacters = showsInvisibleCharacters
        context.coordinator.isWordWrapEnabled = effectiveWordWrapEnabled
        context.coordinator.textBinding = $text
        context.coordinator.scrollPosition = $scrollPosition
        context.coordinator.editorFont = editorFont
        context.coordinator.editorSemiboldFont = editorSemiboldFont
        context.coordinator.onDidFocus = onDidFocus
        context.coordinator.onTextChange = onTextChange

        if didLanguageChange || didSkinChange || didFontChange {
            let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)
            context.coordinator.applyTheme(theme)
        }

        if didWordWrapChange || didFontChange {
            context.coordinator.configureLayout(isWordWrapEnabled: effectiveWordWrapEnabled)
        }
        if didIndentationChange || didFontChange {
            context.coordinator.applyIndentationSettings()
        }
        if didAutocompleteModeChange {
            context.coordinator.handleAutocompleteModeChange()
        }
        if didInvisibleCharacterVisibilityChange {
            context.coordinator.applyInvisibleCharacterVisibility()
        }

        guard let textView = context.coordinator.textView else { return }
        if let lineClickableTextView = textView as? LineClickableTextView {
            lineClickableTextView.editorID = editorID
        }
        if unsafe textView.window?.firstResponder as? NSTextView === textView {
            ActiveEditorTextViewRegistry.shared.register(textView)
        }
        let didTextChange = context.coordinator.syncWithBindingText(text)
        if didLanguageChange || didSkinChange || didFontChange || didTextChange || didSyntaxHighlightingChange || context.coordinator.requiresHighlightRefresh {
            context.coordinator.applyHighlighting()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let largeLayoutTextLengthThreshold = 100_000
        private static let largeFileDeferredBindingThreshold = 100_000
        private static let largeFileDeferredBindingDelay: TimeInterval = 0.35
        private static let largeDocumentCompletionWindow = 200_000

        private struct SyntaxHighlighterCacheKey: Equatable {
            let language: EditorLanguage
            let skin: SkinDefinition
            let editorFontName: String
            let editorFontSize: CGFloat
            let semiboldFontName: String
            let semiboldFontSize: CGFloat

            static func == (lhs: SyntaxHighlighterCacheKey, rhs: SyntaxHighlighterCacheKey) -> Bool {
                lhs.language == rhs.language
                    && lhs.skin == rhs.skin
                    && lhs.editorFontName == rhs.editorFontName
                    && lhs.editorFontSize == rhs.editorFontSize
                    && lhs.semiboldFontName == rhs.semiboldFontName
                    && lhs.semiboldFontSize == rhs.semiboldFontSize
            }
        }

        private struct FontAttributeRun {
            let range: NSRange
            let font: NSFont?
        }

        var textBinding: Binding<String>
        var scrollPosition: Binding<EditorScrollPosition?>
        var language: EditorLanguage
        var skin: SkinDefinition
        var indentation: EditorIndentationSettings
        var autocompleteMode: EditorAutocompleteMode
        var isSyntaxHighlightingEnabled: Bool
        var showsInvisibleCharacters: Bool
        var editorFont: NSFont
        var editorSemiboldFont: NSFont
        var isWordWrapEnabled: Bool
        var onDidFocus: () -> Void
        var onTextChange: (String) -> Void
        weak var textView: NSTextView?
        weak var documentView: PaddedEditorDocumentView?
        weak var scrollView: NSScrollView?
        weak var containerView: EditorContainerView?
        let gutterView = GutterView(frame: .zero)
        private var isApplyingHighlighting = false
        private var sourceText: String
        private var lastSyncedBindingText: String
        private(set) var requiresHighlightRefresh = true
        private var suppressNextBindingSync = false
        private var pendingBindingSyncWorkItem: DispatchWorkItem?
        private var hasUnsyncedBindingText = false
        private var pendingEditedRange: NSRange?
        private var pendingTextEdit: (range: NSRange, replacement: NSString)?
        private var isUpdatingDocumentLayout = false
        private var exactLayoutMeasurementWorkItem: DispatchWorkItem?
        private var liveEditScrollRestoreWorkItem: DispatchWorkItem?
        private var scrollPositionRestoreWorkItems: [DispatchWorkItem] = []
        private var isRestoringScrollPosition = false
        private var isInitialScrollPositionRestorePending = false
        private var highlightedBracketRanges: [NSRange] = []
        private var cachedSyntaxHighlighter: SyntaxHighlighting?
        private var cachedSyntaxHighlighterKey: SyntaxHighlighterCacheKey?
        private let completionController = CompletionController()

        init(textBinding: Binding<String>, scrollPosition: Binding<EditorScrollPosition?>, language: EditorLanguage, skin: SkinDefinition, indentation: EditorIndentationSettings, autocompleteMode: EditorAutocompleteMode, isSyntaxHighlightingEnabled: Bool, showsInvisibleCharacters: Bool, editorFont: NSFont, editorSemiboldFont: NSFont, isWordWrapEnabled: Bool, onDidFocus: @escaping () -> Void, onTextChange: @escaping (String) -> Void) {
            self.textBinding = textBinding
            self.scrollPosition = scrollPosition
            self.language = language
            self.skin = skin
            self.indentation = indentation
            self.autocompleteMode = autocompleteMode
            self.isSyntaxHighlightingEnabled = isSyntaxHighlightingEnabled
            self.showsInvisibleCharacters = showsInvisibleCharacters
            self.editorFont = editorFont
            self.editorSemiboldFont = editorSemiboldFont
            self.isWordWrapEnabled = isWordWrapEnabled
            self.onDidFocus = onDidFocus
            self.onTextChange = onTextChange
            self.sourceText = textBinding.wrappedValue
            self.lastSyncedBindingText = textBinding.wrappedValue
        }

        func attach(
            textView: NSTextView,
            documentView: PaddedEditorDocumentView,
            scrollView: NSScrollView,
            containerView: EditorContainerView
        ) {
            self.textView = textView
            self.documentView = documentView
            self.scrollView = scrollView
            self.containerView = containerView
            gutterView.textView = textView
            gutterView.rebuildLineIndex(for: textView.string as NSString)
            completionController.attach(to: containerView)
            containerView.onLayout = { [weak self] in
                self?.handleContainerLayout()
            }

            if let lineClickableTextView = textView as? LineClickableTextView {
                ActiveEditorTextViewRegistry.shared.track(lineClickableTextView)
                lineClickableTextView.language = language
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
                applyIndentationSettings()
                lineClickableTextView.autocompleteModeProvider = { [weak self] in
                    self?.autocompleteMode ?? .on
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
                lineClickableTextView.flushPendingModelSync = { [weak self] in
                    self?.flushPendingBindingSync()
                }
                lineClickableTextView.hasPendingModelSync = { [weak self] in
                    self?.hasPendingBindingSync() ?? false
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
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTextViewFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: textView
            )
        }

        deinit {
            MainActor.assumeIsolated {
                exactLayoutMeasurementWorkItem?.cancel()
                liveEditScrollRestoreWorkItem?.cancel()
                cancelScrollPositionRestores()
            }
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let liveEditScrollOrigin = scrollOriginForLiveEditRestore()
            updateSourceTextAfterEdit(textView: textView)
            if shouldDeferBindingSync(for: (sourceText as NSString).length) {
                schedulePendingBindingSync()
            } else {
                flushPendingBindingSync()
            }

            let appliedTextEdit = pendingTextEdit
            if let pendingTextEdit {
                gutterView.applyLineIndexEdit(range: pendingTextEdit.range, replacement: pendingTextEdit.replacement)
                self.pendingTextEdit = nil
            } else {
                gutterView.rebuildLineIndex(for: sourceText as NSString)
            }

            let editedRange = pendingEditedRange
            pendingEditedRange = nil
            if isSyntaxHighlightingEnabled {
                applyHighlighting(in: editedRange, replacementLength: appliedTextEdit?.replacement.length)
            } else {
                markHighlightingCurrent()
            }

            (textView as? LineClickableTextView)?.performAutomaticCompletionIfNeeded()
            updateBracketMatchingHighlight()
            gutterView.needsDisplay = true
            updateDocumentLayoutAfterLiveEdit()
            restoreScrollOriginAfterLiveEdit(liveEditScrollOrigin)
            scheduleScrollOriginRestoreAfterLiveEdit(liveEditScrollOrigin)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Capture the exact range being edited for live highlighting
            pendingEditedRange = affectedCharRange
            pendingTextEdit = (range: affectedCharRange, replacement: (replacementString ?? "") as NSString)
            (textView as? LineClickableTextView)?.notePendingCompletionTrigger(
                replacementString: replacementString,
                affectedRange: affectedCharRange
            )
            return true
        }

        private func updateSourceTextAfterEdit(textView: NSTextView) {
            if let pendingTextEdit {
                let currentText = sourceText as NSString
                let affectedRange = pendingTextEdit.range
                if affectedRange.location != NSNotFound,
                   NSMaxRange(affectedRange) <= currentText.length {
                    let updated = NSMutableString(string: sourceText)
                    updated.replaceCharacters(in: affectedRange, with: pendingTextEdit.replacement as String)
                    sourceText = updated as String
                    hasUnsyncedBindingText = true
                    return
                }
            }

            sourceText = textView.string
            hasUnsyncedBindingText = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isApplyingHighlighting { return }
            let wasShowingCompletions = completionController.isVisible
            (textView as? LineClickableTextView)?.noteSelectionDidChange()
            if wasShowingCompletions {
                refreshCompletionItems()
            }
            updateBracketMatchingHighlight()
            textView?.needsDisplay = true
            gutterView.needsDisplay = true
        }

        func configureLayout(isWordWrapEnabled: Bool) {
            guard let textView = textView as? LineClickableTextView,
                  let textContainer = unsafe textView.textContainer,
                  let layoutManager = unsafe textView.layoutManager else { return }

            textContainer.heightTracksTextView = false
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 12))
            scrollView?.contentInsets = .init()
            documentView?.bottomPadding = lineHeight * 10

            if isWordWrapEnabled {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = []
                textView.minSize = NSSize(width: 0, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textContainer.widthTracksTextView = true
                let availableWidth = max((scrollView?.contentSize.width ?? textView.bounds.width), 0)
                textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
                documentView?.updateTextViewSize(NSSize(width: availableWidth, height: textView.frame.height))
                scrollView?.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                textView.minSize = NSSize(width: 0, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textContainer.widthTracksTextView = false
                textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scrollView?.hasHorizontalScroller = true
            }

            let minimumWidth = max((scrollView?.contentSize.width ?? textView.bounds.width), 0)
            let minimumHeight = max((scrollView?.contentSize.height ?? textView.bounds.height), 0)
            applyContentTextViewSize(minimumSize: NSSize(width: minimumWidth, height: minimumHeight))
            updateDocumentLayout()
            if shouldUseFastLayout(for: textView) {
                scheduleExactLayoutMeasurement(after: 0.05)
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
                lineClickableTextView.language = language
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
                applyIndentationSettings()
            }
            updateBracketMatchingHighlight()
            scrollView?.backgroundColor = theme.editorBackgroundColor
            documentView?.backgroundColor = theme.editorBackgroundColor
            gutterView.theme = theme
            gutterView.needsDisplay = true
            completionController.theme = CompletionPopupTheme(theme: theme)
        }

        func applyIndentationSettings() {
            guard let textView = textView as? LineClickableTextView else { return }
            textView.indentation = indentation
        }

        func applyInvisibleCharacterVisibility() {
            guard let layoutManager = unsafe textView?.layoutManager else { return }
            layoutManager.showsInvisibleCharacters = showsInvisibleCharacters
            textView?.needsDisplay = true
        }

        private func updateBracketMatchingHighlight() {
            clearBracketMatchingHighlight()

            guard let textView = textView as? LineClickableTextView,
                  let layoutManager = unsafe textView.layoutManager,
                  let match = textView.bracketMatchNearSelection() else { return }

            let attributes = bracketMatchingAttributes()
            for range in [match.source, match.match] {
                layoutManager.addTemporaryAttributes(attributes, forCharacterRange: range)
                highlightedBracketRanges.append(range)
            }
        }

        private func clearBracketMatchingHighlight() {
            guard let textView,
                  let layoutManager = unsafe textView.layoutManager,
                  !highlightedBracketRanges.isEmpty else {
                highlightedBracketRanges.removeAll()
                return
            }

            for range in highlightedBracketRanges {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
            highlightedBracketRanges.removeAll()
        }

        private func bracketMatchingAttributes() -> [NSAttributedString.Key: Any] {
            let accentColor = NSColor.controlAccentColor
            return [
                .backgroundColor: accentColor.withAlphaComponent(0.28),
                .foregroundColor: accentColor.blended(withFraction: 0.35, of: textView?.textColor ?? .textColor)
                    ?? accentColor
            ]
        }

        func syncWithBindingText(_ text: String) -> Bool {
            if suppressNextBindingSync {
                lastSyncedBindingText = text
                hasUnsyncedBindingText = false
                suppressNextBindingSync = false
                return false
            }

            guard let textView else {
                sourceText = text
                lastSyncedBindingText = text
                hasUnsyncedBindingText = false
                return false
            }
            if pendingBindingSyncWorkItem != nil, text == lastSyncedBindingText {
                return false
            }
            guard sourceText != text else { return false }

            let oldText = sourceText
            let preservedSelectedRanges = selectedRangesPreservingExpectedPosition(
                textView.selectedRanges,
                oldText: oldText,
                newText: text
            )
            let preservedScrollPosition = scrollView.map { EditorScrollPosition($0.contentView.bounds.origin) }
            pendingBindingSyncWorkItem?.cancel()
            pendingBindingSyncWorkItem = nil
            sourceText = text
            lastSyncedBindingText = text
            hasUnsyncedBindingText = false
            textView.string = text
            gutterView.rebuildLineIndex(for: text as NSString)
            updateDocumentLayout(measureTextView: true)
            restoreSelectedRangesIfNeeded(preservedSelectedRanges, in: textView)
            if let preservedScrollPosition {
                _ = restoreScrollPosition(preservedScrollPosition)
                scrollPosition.wrappedValue = preservedScrollPosition
            }
            requiresHighlightRefresh = true
            onTextChange(text)
            return true
        }

        private func updateDocumentLayout(measureTextView: Bool = false) {
            guard !isUpdatingDocumentLayout else {
                return
            }
            isUpdatingDocumentLayout = true
            defer { isUpdatingDocumentLayout = false }

            guard let scrollView,
                  let documentView,
                  let textView = textView as? LineClickableTextView else { return }
            var shouldMeasureTextView = measureTextView
            if isWordWrapEnabled,
               let textContainer = unsafe textView.textContainer {
                let width = max(scrollView.contentSize.width, 0)
                if abs(textView.frame.width - width) > 0.5 {
                    textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                    documentView.updateTextViewSize(NSSize(width: width, height: textView.frame.height))
                    shouldMeasureTextView = true
                }
            }
            if shouldMeasureTextView {
                applyContentTextViewSize(minimumSize: scrollView.contentSize)
                if shouldUseFastLayout(for: textView) {
                    scheduleExactLayoutMeasurement()
                }
            }
            documentView.updateLayout(minimumSize: scrollView.contentSize)
        }

        private func updateDocumentLayoutAfterLiveEdit() {
            guard !isUpdatingDocumentLayout else {
                return
            }
            isUpdatingDocumentLayout = true
            defer { isUpdatingDocumentLayout = false }

            guard let scrollView,
                  let documentView,
                  let textView = textView as? LineClickableTextView else { return }
            if isWordWrapEnabled,
               let textContainer = unsafe textView.textContainer {
                let width = max(scrollView.contentSize.width, 0)
                if abs(textView.frame.width - width) > 0.5 {
                    textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                }
            }
            applyFastTextViewSize(minimumSize: scrollView.contentSize)
            documentView.updateLayout(minimumSize: scrollView.contentSize)
            scheduleExactLayoutMeasurement(after: 0.18)
        }

        private func handleContainerLayout() {
            updateDocumentLayout()
            restorePendingInitialScrollPositionIfNeeded()
        }

        private func applyContentTextViewSize(minimumSize: NSSize) {
            guard let textView else { return }
            if shouldUseFastLayout(for: textView) {
                applyFastTextViewSize(minimumSize: minimumSize)
            } else {
                applyMeasuredTextViewSize(minimumSize: minimumSize)
            }
        }

        private func shouldUseFastLayout(for textView: NSTextView) -> Bool {
            (unsafe textView.textStorage?.length ?? 0) > Self.largeLayoutTextLengthThreshold
        }

        private func applyFastTextViewSize(minimumSize: NSSize) {
            guard let textView = textView as? LineClickableTextView,
                  let layoutManager = unsafe textView.layoutManager,
                  let textContainer = unsafe textView.textContainer else { return }

            let font = textView.font ?? NSFont.systemFont(ofSize: 12)
            let lineHeight = max(layoutManager.defaultLineHeight(for: font), 1)
            let characterWidth = self.characterWidth(for: textView)
            let verticalInset = textView.textContainerInset.height * 2
            let horizontalInset = textView.textContainerInset.width * 2
            let textLength = unsafe textView.textStorage?.length ?? 0
            let measuredWidth: CGFloat
            let visualLineCount: Int

            if isWordWrapEnabled {
                let containerWidth = textContainer.containerSize.width.isFinite && textContainer.containerSize.width > 1
                    ? textContainer.containerSize.width
                    : max(minimumSize.width, textView.bounds.width, 800)
                let wrappingWidth = max(containerWidth - textContainer.lineFragmentPadding * 2, 1)
                let charactersPerLine = max(Int(floor(wrappingWidth / characterWidth)), 1)
                measuredWidth = minimumSize.width
                visualLineCount = gutterView.estimatedVisualLineCount(charactersPerLine: charactersPerLine, textLength: textLength)
            } else {
                measuredWidth = max(
                    minimumSize.width,
                    CGFloat(gutterView.maximumLineLength) * characterWidth + horizontalInset + textContainer.lineFragmentPadding * 2 + 32
                )
                visualLineCount = gutterView.lineCount
            }

            let nextSize = NSSize(
                width: ceil(max(measuredWidth, minimumSize.width)),
                height: ceil(max(CGFloat(max(visualLineCount, 1)) * lineHeight + verticalInset, minimumSize.height))
            )
            if abs(textView.frame.width - nextSize.width) > 0.5 || abs(textView.frame.height - nextSize.height) > 0.5 {
                documentView?.updateTextViewSize(nextSize) ?? textView.setFrameSize(nextSize)
            }
        }

        private func applyMeasuredTextViewSize(minimumSize: NSSize) {
            guard let textView = textView as? LineClickableTextView,
                  let layoutManager = unsafe textView.layoutManager,
                  let textContainer = unsafe textView.textContainer else { return }

            let horizontalInset = textView.textContainerInset.width * 2
            let verticalInset = textView.textContainerInset.height * 2
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredWidth = isWordWrapEnabled
                ? minimumSize.width
                : max(
                    minimumSize.width,
                    CGFloat(gutterView.maximumLineLength) * characterWidth(for: textView) + horizontalInset + textContainer.lineFragmentPadding * 2 + 32
                )
            let measuredHeight = usedRect.maxY + verticalInset
            let nextSize = NSSize(
                width: ceil(max(measuredWidth, minimumSize.width)),
                height: ceil(max(measuredHeight, minimumSize.height))
            )
            if abs(textView.frame.width - nextSize.width) > 0.5 || abs(textView.frame.height - nextSize.height) > 0.5 {
                documentView?.updateTextViewSize(nextSize) ?? textView.setFrameSize(nextSize)
            }
        }

        private func characterWidth(for textView: NSTextView) -> CGFloat {
            let font = textView.font ?? NSFont.systemFont(ofSize: 12)
            return max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        }

        private func scheduleExactLayoutMeasurement(after delay: TimeInterval = 0.2) {
            exactLayoutMeasurementWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.performExactLayoutMeasurement()
            }
            exactLayoutMeasurementWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func performExactLayoutMeasurement() {
            exactLayoutMeasurementWorkItem = nil
            guard !isUpdatingDocumentLayout else {
                scheduleExactLayoutMeasurement()
                return
            }
            isUpdatingDocumentLayout = true
            defer { isUpdatingDocumentLayout = false }

            guard let scrollView,
                  let documentView,
                  textView != nil else { return }
            if isWordWrapEnabled, scrollView.contentSize.width <= 1 {
                scheduleExactLayoutMeasurement(after: 0.05)
                return
            }

            applyMeasuredTextViewSize(minimumSize: scrollView.contentSize)
            documentView.updateLayout(minimumSize: scrollView.contentSize)
            restoreCurrentScrollPositionAfterLayout()
        }

        func restoreInitialScrollPosition() {
            guard let position = scrollPosition.wrappedValue else { return }
            isInitialScrollPositionRestorePending = true
            cancelScrollPositionRestores()
            if restoreScrollPosition(position) {
                isInitialScrollPositionRestorePending = false
            }
            scheduleScrollPositionRestore(position, after: 0.05)
            scheduleScrollPositionRestore(position, after: 0.2)
        }

        private func scheduleScrollPositionRestore(_ position: EditorScrollPosition, after delay: TimeInterval) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.restoreScrollPosition(position), self.isInitialScrollPositionRestorePending {
                    self.isInitialScrollPositionRestorePending = false
                }
            }
            scrollPositionRestoreWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func cancelScrollPositionRestores() {
            scrollPositionRestoreWorkItems.forEach { $0.cancel() }
            scrollPositionRestoreWorkItems.removeAll()
        }

        private func restorePendingInitialScrollPositionIfNeeded() {
            guard isInitialScrollPositionRestorePending,
                  let position = scrollPosition.wrappedValue,
                  restoreScrollPosition(position) else { return }
            isInitialScrollPositionRestorePending = false
        }

        private func restoreCurrentScrollPositionAfterLayout() {
            guard let position = scrollPosition.wrappedValue else { return }
            _ = restoreScrollPosition(position)
        }

        @discardableResult
        private func restoreScrollPosition(_ position: EditorScrollPosition) -> Bool {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return false }

            let clipSize = scrollView.contentView.bounds.size
            guard clipSize.width > 1,
                  clipSize.height > 1,
                  documentView.frame.height > 1 else { return false }

            let maxX = max(documentView.frame.width - clipSize.width, 0)
            let maxY = max(documentView.frame.height - clipSize.height, 0)
            let restoredOrigin = NSPoint(
                x: min(max(position.x, 0), maxX),
                y: min(max(position.y, 0), maxY)
            )
            let currentOrigin = scrollView.contentView.bounds.origin
            guard abs(currentOrigin.x - restoredOrigin.x) > 0.5 || abs(currentOrigin.y - restoredOrigin.y) > 0.5 else {
                return true
            }

            prepareVisibleLayout(at: restoredOrigin, clipSize: clipSize)
            isRestoringScrollPosition = true
            scrollView.contentView.scroll(to: restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isRestoringScrollPosition = false
            gutterView.needsDisplay = true
            return true
        }

        private func scrollOriginForLiveEditRestore() -> NSPoint? {
            guard isSyntaxHighlightingEnabled,
                  let scrollView,
                  let documentView = scrollView.documentView else { return nil }

            let clipSize = scrollView.contentView.bounds.size
            guard clipSize.width > 1, clipSize.height > 1 else { return nil }
            guard !isWordWrapEnabled, documentView.frame.width > clipSize.width + 0.5 else { return nil }
            return scrollView.contentView.bounds.origin
        }

        private func scheduleScrollOriginRestoreAfterLiveEdit(_ origin: NSPoint?) {
            guard let origin else { return }
            liveEditScrollRestoreWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.restoreScrollOriginAfterLiveEdit(origin)
            }
            liveEditScrollRestoreWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func restoreScrollOriginAfterLiveEdit(_ origin: NSPoint?) {
            guard let origin,
                  let scrollView,
                  let documentView = scrollView.documentView else { return }

            let clipSize = scrollView.contentView.bounds.size
            guard clipSize.width > 1, clipSize.height > 1, documentView.frame.height > 1 else { return }

            let maxX = max(documentView.frame.width - clipSize.width, 0)
            let maxY = max(documentView.frame.height - clipSize.height, 0)
            let restoredOrigin = NSPoint(
                x: min(max(origin.x, 0), maxX),
                y: min(max(origin.y, 0), maxY)
            )
            guard isCaretVisible(at: restoredOrigin, clipSize: clipSize) else { return }

            let currentOrigin = scrollView.contentView.bounds.origin
            if abs(currentOrigin.x - restoredOrigin.x) > 0.5 || abs(currentOrigin.y - restoredOrigin.y) > 0.5 {
                isRestoringScrollPosition = true
                scrollView.contentView.scroll(to: restoredOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isRestoringScrollPosition = false
            }

            let restoredPosition = EditorScrollPosition(restoredOrigin)
            let oldPosition = scrollPosition.wrappedValue
            if abs((oldPosition?.x ?? -1) - restoredPosition.x) > 0.5 || abs((oldPosition?.y ?? -1) - restoredPosition.y) > 0.5 {
                scrollPosition.wrappedValue = restoredPosition
            }
            gutterView.needsDisplay = true
        }

        private func isCaretVisible(at origin: NSPoint, clipSize: NSSize) -> Bool {
            guard let textView,
                  let caret = caretRectInTextViewCoordinates() else { return false }

            let lineHeight = unsafe textView.layoutManager?.defaultLineHeight(for: textView.font ?? editorFont) ?? editorFont.pointSize
            let visibleRect = NSRect(origin: origin, size: clipSize).insetBy(dx: -8, dy: -max(lineHeight * 2, 24))
            return visibleRect.intersects(caret.rect)
        }

        private func prepareVisibleLayout(at origin: NSPoint, clipSize: NSSize) {
            guard let textView,
                  let layoutManager = unsafe textView.layoutManager,
                  let textContainer = unsafe textView.textContainer else { return }

            let visibleRect = NSRect(origin: origin, size: clipSize)
            layoutManager.ensureLayout(forBoundingRect: visibleRect, in: textContainer)
            textView.setNeedsDisplay(visibleRect)
        }

        @objc
        private func handleTextViewFrameDidChange() {
            updateDocumentLayout()
        }

        private func shouldDeferBindingSync(for textLength: Int) -> Bool {
            textLength > Self.largeFileDeferredBindingThreshold
        }

        private func schedulePendingBindingSync() {
            pendingBindingSyncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushPendingBindingSync()
            }
            pendingBindingSyncWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.largeFileDeferredBindingDelay, execute: workItem)
        }

        private func flushPendingBindingSync() {
            guard hasPendingBindingSync() else { return }
            pendingBindingSyncWorkItem?.cancel()
            pendingBindingSyncWorkItem = nil
            suppressNextBindingSync = true
            lastSyncedBindingText = sourceText
            hasUnsyncedBindingText = false
            textBinding.wrappedValue = sourceText
            onTextChange(sourceText)
        }

        private func hasPendingBindingSync() -> Bool {
            hasUnsyncedBindingText || pendingBindingSyncWorkItem != nil
        }

        func enableNonContiguousLayout() {
            if let layoutManager = unsafe textView?.layoutManager {
                layoutManager.allowsNonContiguousLayout = true
            }
        }

        func markHighlightingCurrent() {
            requiresHighlightRefresh = false
        }

        func applyHighlighting(in editedRange: NSRange? = nil, replacementLength: Int? = nil) {
            guard let textView, let textStorage = unsafe textView.textStorage else { return }

            // When an edited range is provided (live typing), only highlight
            // a small window around the cursor. For large files, shrink it
            // further to keep keystrokes snappy.
            let highlightRange: NSRange
            let requestedHighlightRange: NSRange?
            let fontMutationRange: NSRange?
            if let range = editedRange {
                let editedLength = replacementLength ?? range.length
                highlightRange = editedLineRange(for: range, replacementLength: editedLength, textLength: textStorage.length)
                requestedHighlightRange = highlightRange
                fontMutationRange = highlightRange
            } else {
                // Full-document pass (initial load, theme/language change)
                highlightRange = NSRange(location: 0, length: textStorage.length)
                requestedHighlightRange = nil
                fontMutationRange = nil
            }

            let shouldForceLayoutForHighlightedRange = editedRange == nil
                && highlightRange.length <= 100_000
            applyHighlightingPass(
                highlightRange: highlightRange,
                requestedHighlightRange: requestedHighlightRange,
                fontMutationRange: fontMutationRange,
                shouldForceLayoutForHighlightedRange: shouldForceLayoutForHighlightedRange
            )
        }

        private func applyHighlightingPass(
            highlightRange: NSRange,
            requestedHighlightRange: NSRange?,
            fontMutationRange: NSRange?,
            shouldForceLayoutForHighlightedRange: Bool
        ) {
            guard let textView, let textStorage = unsafe textView.textStorage else { return }
            let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)

            isApplyingHighlighting = true
            defer {
                isApplyingHighlighting = false
                requiresHighlightRefresh = false
            }
            let selectedRanges = textView.selectedRanges
            let preservedFontRuns = requestedHighlightRange == nil
                ? []
                : fontAttributeRuns(in: highlightRange, excluding: fontMutationRange, storage: textStorage)
            textStorage.beginEditing()

            if isSyntaxHighlightingEnabled {
                syntaxHighlighter().apply(to: textStorage, text: textView.string, in: requestedHighlightRange)
            } else {
                textStorage.setAttributes(theme.baseAttributes, range: highlightRange)
            }
            restoreFontAttributeRuns(preservedFontRuns, in: textStorage)

            textStorage.endEditing()
            restoreSelectedRangesIfNeeded(selectedRanges, in: textView)

            if shouldForceLayoutForHighlightedRange,
               let layoutManager = unsafe textView.layoutManager,
               let textContainer = unsafe textView.textContainer {
                layoutManager.invalidateDisplay(forCharacterRange: highlightRange)
                let glyphRange = unsafe layoutManager.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                textView.setNeedsDisplay(rect)
            } else {
                unsafe textView.layoutManager?.invalidateDisplay(forCharacterRange: highlightRange)
                textView.setNeedsDisplay(textView.visibleRect)
            }

            gutterView.needsDisplay = true
            if requestedHighlightRange == nil {
                updateDocumentLayout(measureTextView: true)
                DispatchQueue.main.async { [weak self] in
                    self?.updateDocumentLayout(measureTextView: true)
                }
            }
        }

        private func restoreSelectedRangesIfNeeded(_ selectedRanges: [NSValue], in textView: NSTextView) {
            let currentRanges = textView.selectedRanges
            guard currentRanges.count == selectedRanges.count else {
                textView.selectedRanges = selectedRanges
                return
            }

            let rangesMatch = zip(currentRanges, selectedRanges).allSatisfy { current, preserved in
                NSEqualRanges(current.rangeValue, preserved.rangeValue)
            }
            if !rangesMatch {
                textView.selectedRanges = selectedRanges
            }
        }

        private func selectedRangesClampedToTextLength(_ selectedRanges: [NSValue], textLength: Int) -> [NSValue] {
            guard !selectedRanges.isEmpty else {
                return [NSValue(range: NSRange(location: 0, length: 0))]
            }

            return selectedRanges.map { value in
                let range = value.rangeValue
                guard range.location != NSNotFound else {
                    return NSValue(range: NSRange(location: textLength, length: 0))
                }

                let location = min(max(range.location, 0), textLength)
                let length = min(max(range.length, 0), max(textLength - location, 0))
                return NSValue(range: NSRange(location: location, length: length))
            }
        }

        private func selectedRangesPreservingExpectedPosition(
            _ selectedRanges: [NSValue],
            oldText: String,
            newText: String
        ) -> [NSValue] {
            guard contentByTrimmingTrailingSpacesAndTabs(oldText) == newText else {
                return selectedRangesClampedToTextLength(
                    selectedRanges,
                    textLength: (newText as NSString).length
                )
            }

            let oldNSString = oldText as NSString
            let newNSString = newText as NSString
            guard !selectedRanges.isEmpty else {
                return [NSValue(range: NSRange(location: 0, length: 0))]
            }

            return selectedRanges.map { value in
                let range = value.rangeValue
                guard range.location != NSNotFound else {
                    return NSValue(range: NSRange(location: newNSString.length, length: 0))
                }

                let oldStart = min(max(range.location, 0), oldNSString.length)
                let oldEnd = min(max(NSMaxRange(range), oldStart), oldNSString.length)
                let newStart = locationForMatchingLinePosition(
                    linePosition(for: oldStart, in: oldNSString),
                    in: newNSString
                )
                let newEnd = locationForMatchingLinePosition(
                    linePosition(for: oldEnd, in: oldNSString),
                    in: newNSString
                )
                let location = min(newStart, newEnd)
                let length = max(newEnd - location, 0)
                return NSValue(range: NSRange(location: location, length: length))
            }
        }

        private struct TextLinePosition {
            let line: Int
            let column: Int
        }

        private func linePosition(for location: Int, in text: NSString) -> TextLinePosition {
            let clampedLocation = min(max(location, 0), text.length)
            var line = 0
            var lineStart = 0
            var cursor = 0

            while cursor < clampedLocation {
                if text.character(at: cursor) == 10 {
                    line += 1
                    lineStart = cursor + 1
                }
                cursor += 1
            }

            return TextLinePosition(line: line, column: clampedLocation - lineStart)
        }

        private func locationForMatchingLinePosition(_ position: TextLinePosition, in text: NSString) -> Int {
            var line = 0
            var lineStart = 0
            var cursor = 0

            while line < position.line, cursor < text.length {
                if text.character(at: cursor) == 10 {
                    line += 1
                    lineStart = cursor + 1
                }
                cursor += 1
            }

            guard line == position.line else {
                return text.length
            }

            var lineEnd = lineStart
            while lineEnd < text.length, text.character(at: lineEnd) != 10 {
                lineEnd += 1
            }

            return min(lineStart + position.column, lineEnd)
        }

        private func contentByTrimmingTrailingSpacesAndTabs(_ text: String) -> String {
            text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var end = line.endIndex
                    while end > line.startIndex {
                        let previous = line.index(before: end)
                        guard line[previous] == " " || line[previous] == "\t" else { break }
                        end = previous
                    }
                    return String(line[..<end])
                }
                .joined(separator: "\n")
        }

        private func editedLineRange(for editedRange: NSRange, replacementLength: Int, textLength: Int) -> NSRange {
            guard textLength > 0 else { return NSRange(location: 0, length: 0) }

            let location = min(max(editedRange.location, 0), textLength)
            let length = min(max(replacementLength, 0), textLength - location)
            let text = sourceText as NSString
            return text.lineRange(for: NSRange(location: location, length: length))
        }

        private func fontAttributeRuns(in range: NSRange, excluding excludedRange: NSRange?, storage: NSTextStorage) -> [FontAttributeRun] {
            guard range.length > 0 else { return [] }

            var runs: [FontAttributeRun] = []
            for preservationRange in fontPreservationRanges(in: range, excluding: excludedRange) {
                unsafe storage.enumerateAttribute(.font, in: preservationRange, options: []) { value, effectiveRange, _ in
                    let runRange = NSIntersectionRange(effectiveRange, preservationRange)
                    guard runRange.length > 0 else { return }
                    runs.append(FontAttributeRun(range: runRange, font: value as? NSFont))
                }
            }
            return runs
        }

        private func fontPreservationRanges(in range: NSRange, excluding excludedRange: NSRange?) -> [NSRange] {
            guard let excludedRange else { return [range] }
            let excluded = NSIntersectionRange(range, excludedRange)
            guard excluded.length > 0 else { return [range] }

            var ranges: [NSRange] = []
            if excluded.location > range.location {
                ranges.append(NSRange(location: range.location, length: excluded.location - range.location))
            }

            let excludedEnd = NSMaxRange(excluded)
            let rangeEnd = NSMaxRange(range)
            if excludedEnd < rangeEnd {
                ranges.append(NSRange(location: excludedEnd, length: rangeEnd - excludedEnd))
            }
            return ranges
        }

        private func restoreFontAttributeRuns(_ runs: [FontAttributeRun], in storage: NSTextStorage) {
            for run in runs {
                if let font = run.font {
                    storage.addAttribute(.font, value: font, range: run.range)
                } else {
                    storage.removeAttribute(.font, range: run.range)
                }
            }
        }

        private func syntaxHighlighter() -> SyntaxHighlighting {
            let key = SyntaxHighlighterCacheKey(
                language: language,
                skin: skin,
                editorFontName: editorFont.fontName,
                editorFontSize: editorFont.pointSize,
                semiboldFontName: editorSemiboldFont.fontName,
                semiboldFontSize: editorSemiboldFont.pointSize
            )

            if let cachedSyntaxHighlighter, cachedSyntaxHighlighterKey == key {
                return cachedSyntaxHighlighter
            }

            let highlighter = SyntaxHighlighterFactory.makeHighlighter(
                for: language,
                skin: skin,
                editorFont: editorFont,
                semiboldFont: editorSemiboldFont
            )
            cachedSyntaxHighlighter = highlighter
            cachedSyntaxHighlighterKey = key
            return highlighter
        }

        @objc
        private func handleBoundsDidChange() {
            // Only redraw gutter if scroll position actually changed
            guard let scrollView else { return }
            let origin = scrollView.contentView.bounds.origin
            let didChange = origin != gutterView.lastClipOrigin
            guard didChange else { return }
            if !isRestoringScrollPosition {
                let newPosition = EditorScrollPosition(origin)
                let oldPosition = scrollPosition.wrappedValue
                if abs((oldPosition?.x ?? -1) - newPosition.x) > 0.5 || abs((oldPosition?.y ?? -1) - newPosition.y) > 0.5 {
                    scrollPosition.wrappedValue = newPosition
                }
            }
            gutterView.needsDisplay = true
            guard !isApplyingHighlighting, !isUpdatingDocumentLayout else { return }
            if completionController.isVisible {
                completionController.reposition(anchorRect: completionAnchor()?.rect)
            }
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
            let source = text as NSString
            switch language {
            case .python:
                return pythonCompletionSymbols(in: source)
            case .shell:
                return shellCompletionSymbols(in: source)
            case .powerShell:
                return powerShellCompletionSymbols(in: source)
            default:
                return genericCompletionSymbols(in: source)
            }
        }

        private func genericCompletionSymbols(in text: NSString) -> [String] {
            var seen = Set<String>()
            var results: [String] = []
            var index = 0

            while index < text.length {
                let ch = text.character(at: index)
                guard isIdentifierStart(ch) else {
                    index += 1
                    continue
                }

                let end = identifierEnd(in: text, startingAt: index)
                let candidate = text.substring(with: NSRange(location: index, length: end - index))
                if seen.insert(candidate).inserted {
                    results.append(candidate)
                }
                index = end
            }

            return results
        }

        private func pythonCompletionSymbols(in text: NSString) -> [String] {
            var seen = Set<String>()
            var results: [String] = []
            var index = 0
            var state = PythonCompletionState.normal

            while index < text.length {
                let lineRange = NSRange(location: index, length: lineEnd(in: text, at: index) - index)
                state = scanPythonCompletionLine(in: text, lineRange: lineRange, state: state) { symbol in
                    if seen.insert(symbol).inserted {
                        results.append(symbol)
                    }
                }
                index = NSMaxRange(lineRange)
            }

            return results
        }

        private enum PythonCompletionState {
            case normal
            case tripleSingle
            case tripleDouble
        }

        private func scanPythonCompletionLine(
            in text: NSString,
            lineRange: NSRange,
            state initialState: PythonCompletionState,
            emit: (String) -> Void
        ) -> PythonCompletionState {
            var state = initialState
            var index = lineRange.location
            let end = NSMaxRange(lineRange)

            if state != .normal {
                let quote: unichar = state == .tripleSingle ? 39 : 34
                let stringEnd = pythonTripleStringEnd(in: text, startingAt: index, quote: quote, end: end)
                index = stringEnd.location
                state = stringEnd.closed ? .normal : state
            }

            let first = firstCodeCharacter(in: text, lineRange: lineRange)
            if first < end, startsWord("def", in: text, at: first, end: end) {
                let nameStart = skipWhitespace(in: text, from: first + 3, to: end)
                if nameStart < end, isIdentifierStart(text.character(at: nameStart)) {
                    let nameEnd = identifierEnd(in: text, startingAt: nameStart)
                    emit(text.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart)))
                }
            }

            if first < end, isIdentifierStart(text.character(at: first)) {
                let nameEnd = identifierEnd(in: text, startingAt: first)
                let equals = skipWhitespace(in: text, from: nameEnd, to: end)
                if equals < end,
                   text.character(at: equals) == 61,
                   !(equals + 1 < end && text.character(at: equals + 1) == 61) {
                    emit(text.substring(with: NSRange(location: first, length: nameEnd - first)))
                }
            }

            while index < end {
                let ch = text.character(at: index)
                if ch == 35 || ch == 10 || ch == 13 { break }
                let prefixLength = pythonStringPrefixLength(in: text, at: index, end: end)
                let quoteIndex = index + prefixLength
                if quoteIndex < end {
                    let quote = text.character(at: quoteIndex)
                    if quote == 34 || quote == 39 {
                        if quoteIndex + 2 < end,
                           text.character(at: quoteIndex + 1) == quote,
                           text.character(at: quoteIndex + 2) == quote {
                            let stringEnd = pythonTripleStringEnd(in: text, startingAt: quoteIndex + 3, quote: quote, end: end)
                            state = stringEnd.closed ? .normal : (quote == 34 ? .tripleDouble : .tripleSingle)
                            index = stringEnd.location
                        } else {
                            index = quotedStringEnd(in: text, startingAt: quoteIndex, quote: quote, end: end)
                        }
                        continue
                    }
                }
                index += 1
            }

            return state
        }

        private func shellCompletionSymbols(in text: NSString) -> [String] {
            var seen = Set<String>()
            var results: [String] = []
            var index = 0

            while index < text.length {
                let lineRange = NSRange(location: index, length: lineEnd(in: text, at: index) - index)
                scanShellCompletionLine(in: text, lineRange: lineRange) { symbol in
                    if seen.insert(symbol).inserted {
                        results.append(symbol)
                    }
                }
                index = NSMaxRange(lineRange)
            }

            return results
        }

        private func scanShellCompletionLine(in text: NSString, lineRange: NSRange, emit: (String) -> Void) {
            var index = lineRange.location
            let end = NSMaxRange(lineRange)
            let first = firstCodeCharacter(in: text, lineRange: lineRange)

            if first < end {
                var commandStart = first
                if startsWord("function", in: text, at: first, end: end) {
                    commandStart = skipWhitespace(in: text, from: first + 8, to: end)
                }
                if commandStart < end, isShellIdentifierStart(text.character(at: commandStart)) {
                    let commandEnd = shellIdentifierEnd(in: text, startingAt: commandStart, end: end)
                    let afterCommand = skipWhitespace(in: text, from: commandEnd, to: end)
                    if afterCommand + 2 <= end,
                       text.character(at: afterCommand) == 40,
                       text.character(at: afterCommand + 1) == 41 {
                        emit(text.substring(with: NSRange(location: commandStart, length: commandEnd - commandStart)))
                    } else if afterCommand < end, text.character(at: afterCommand) == 123 {
                        emit(text.substring(with: NSRange(location: commandStart, length: commandEnd - commandStart)))
                    }
                }
            }

            while index < end {
                let ch = text.character(at: index)
                if ch == 35 || ch == 10 || ch == 13 { break }
                if ch == 34 || ch == 39 {
                    index = quotedStringEnd(in: text, startingAt: index, quote: ch, end: end)
                    continue
                }
                if ch == 36 {
                    if let variable = shellVariableName(in: text, startingAt: index, end: end) {
                        emit(variable.name)
                        index = variable.end
                        continue
                    }
                }
                if isIdentifierStart(ch) {
                    let nameEnd = identifierEnd(in: text, startingAt: index)
                    if nameEnd < end, text.character(at: nameEnd) == 61 {
                        emit(text.substring(with: NSRange(location: index, length: nameEnd - index)))
                    }
                    index = nameEnd
                    continue
                }
                index += 1
            }
        }

        private func powerShellCompletionSymbols(in text: NSString) -> [String] {
            var seen = Set<String>()
            var results: [String] = []
            var index = 0

            while index < text.length {
                let lineRange = NSRange(location: index, length: lineEnd(in: text, at: index) - index)
                scanPowerShellCompletionLine(in: text, lineRange: lineRange) { symbol in
                    if seen.insert(symbol).inserted {
                        results.append(symbol)
                    }
                }
                index = NSMaxRange(lineRange)
            }

            return results
        }

        private func scanPowerShellCompletionLine(in text: NSString, lineRange: NSRange, emit: (String) -> Void) {
            var index = lineRange.location
            let end = NSMaxRange(lineRange)
            let first = firstCodeCharacter(in: text, lineRange: lineRange)

            if first < end, startsWord("function", in: text, at: first, end: end, caseInsensitive: true) {
                let nameStart = skipWhitespace(in: text, from: first + 8, to: end)
                if nameStart < end, isShellIdentifierStart(text.character(at: nameStart)) {
                    let nameEnd = shellIdentifierEnd(in: text, startingAt: nameStart, end: end)
                    emit(text.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart)))
                }
            }

            while index < end {
                let ch = text.character(at: index)
                if ch == 35 || ch == 10 || ch == 13 { break }
                if ch == 34 || ch == 39 {
                    index = quotedStringEnd(in: text, startingAt: index, quote: ch, end: end)
                    continue
                }
                if ch == 36 {
                    if let variable = shellVariableName(in: text, startingAt: index, end: end) {
                        emit(variable.name)
                        index = variable.end
                        continue
                    }
                }
                index += 1
            }
        }

        private func lineEnd(in text: NSString, at location: Int) -> Int {
            var index = min(max(location, 0), text.length)
            while index < text.length, text.character(at: index) != 10 {
                index += 1
            }
            if index < text.length {
                index += 1
            }
            return index
        }

        private func firstCodeCharacter(in text: NSString, lineRange: NSRange) -> Int {
            var index = lineRange.location
            let end = NSMaxRange(lineRange)
            while index < end, isWhitespace(text.character(at: index)) {
                index += 1
            }
            return index
        }

        private func skipWhitespace(in text: NSString, from start: Int, to end: Int) -> Int {
            var index = start
            while index < end, isWhitespace(text.character(at: index)) {
                index += 1
            }
            return index
        }

        private func isWhitespace(_ ch: unichar) -> Bool {
            ch == 32 || ch == 9
        }

        private func isIdentifierStart(_ ch: unichar) -> Bool {
            (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95
        }

        private func isIdentifierCharacter(_ ch: unichar) -> Bool {
            isIdentifierStart(ch) || (ch >= 48 && ch <= 57)
        }

        private func identifierEnd(in text: NSString, startingAt start: Int) -> Int {
            var index = start
            guard index < text.length, isIdentifierStart(text.character(at: index)) else { return index }
            index += 1
            while index < text.length, isIdentifierCharacter(text.character(at: index)) {
                index += 1
            }
            return index
        }

        private func isShellIdentifierStart(_ ch: unichar) -> Bool {
            isIdentifierStart(ch) || ch == 46 || ch == 47
        }

        private func isShellIdentifierCharacter(_ ch: unichar) -> Bool {
            isIdentifierCharacter(ch) || ch == 45 || ch == 46 || ch == 47 || ch == 58
        }

        private func shellIdentifierEnd(in text: NSString, startingAt start: Int, end: Int) -> Int {
            var index = start
            while index < end, isShellIdentifierCharacter(text.character(at: index)) {
                index += 1
            }
            return index
        }

        private func startsWord(
            _ word: String,
            in text: NSString,
            at index: Int,
            end: Int,
            caseInsensitive: Bool = false
        ) -> Bool {
            let length = (word as NSString).length
            guard index + length <= end else { return false }
            let candidate = text.substring(with: NSRange(location: index, length: length))
            let matches = caseInsensitive
                ? candidate.caseInsensitiveCompare(word) == .orderedSame
                : candidate == word
            guard matches else { return false }
            let beforeOK = index == 0 || !isIdentifierCharacter(text.character(at: index - 1))
            let afterOK = index + length >= end || !isIdentifierCharacter(text.character(at: index + length))
            return beforeOK && afterOK
        }

        private func quotedStringEnd(in text: NSString, startingAt start: Int, quote: unichar, end: Int) -> Int {
            var index = start + 1
            var escaped = false
            while index < end {
                let ch = text.character(at: index)
                if quote == 34, ch == 92, !escaped {
                    escaped = true
                    index += 1
                    continue
                }
                if ch == quote, !escaped {
                    return index + 1
                }
                escaped = false
                index += 1
            }
            return index
        }

        private func pythonStringPrefixLength(in text: NSString, at index: Int, end: Int) -> Int {
            var cursor = index
            while cursor < end {
                let ch = text.character(at: cursor)
                if ch == 70 || ch == 82 || ch == 66 || ch == 85 || ch == 102 || ch == 114 || ch == 98 || ch == 117 {
                    cursor += 1
                } else {
                    break
                }
            }
            return min(cursor - index, 2)
        }

        private func pythonTripleStringEnd(
            in text: NSString,
            startingAt start: Int,
            quote: unichar,
            end: Int
        ) -> (location: Int, closed: Bool) {
            var index = start
            while index + 2 < end {
                if text.character(at: index) == quote,
                   text.character(at: index + 1) == quote,
                   text.character(at: index + 2) == quote {
                    return (index + 3, true)
                }
                index += 1
            }
            return (end, false)
        }

        private func shellVariableName(in text: NSString, startingAt start: Int, end: Int) -> (name: String, end: Int)? {
            guard start + 1 < end else { return nil }
            if text.character(at: start + 1) == 123 {
                var index = start + 2
                let nameStart = index
                while index < end, text.character(at: index) != 125 {
                    index += 1
                }
                guard index > nameStart else { return nil }
                let name = text.substring(with: NSRange(location: nameStart, length: index - nameStart))
                return (name, index < end ? index + 1 : index)
            }

            let nameStart = start + 1
            guard isIdentifierStart(text.character(at: nameStart)) else { return nil }
            var index = nameStart + 1
            while index < end, isIdentifierCharacter(text.character(at: index)) {
                index += 1
            }
            let name = text.substring(with: NSRange(location: nameStart, length: index - nameStart))
            return (name, index)
        }

        func handleAutocompleteModeChange() {
            if autocompleteMode == .off {
                (textView as? LineClickableTextView)?.cancelPendingCompletionTrigger()
                completionController.hide()
            }
        }

        private func refreshCompletionItems() {
            guard autocompleteMode == .on,
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
            guard autocompleteMode == .on,
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
            let completionSource = completionSearchText(in: source, around: partialRange)
            let candidates = completionCandidates(in: completionSource, partial: partial, excluding: reservedWords)
            guard !candidates.isEmpty, let anchor = completionAnchor() else { return nil }
            return (candidates.map(CompletionItem.init(text:)), anchor.rect, anchor.placement)
        }

        private func completionSearchText(in source: NSString, around partialRange: NSRange) -> String {
            guard source.length > Self.largeFileDeferredBindingThreshold else {
                return source as String
            }

            let start = max(partialRange.location - (Self.largeDocumentCompletionWindow / 2), 0)
            let end = min(NSMaxRange(partialRange) + (Self.largeDocumentCompletionWindow / 2), source.length)
            let boundedRange = source.lineRange(for: NSRange(location: start, length: end - start))
            return source.substring(with: boundedRange)
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
            case .logfile:
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
            case .markdown, .xml, .json:
                return []
            }
        }
    }
}

final class LineClickableTextView: NSTextView {
    private static let minimumCompletionPrefixLength = 2
    private static let completionDelay: TimeInterval = 0.5
    private static let maximumBracketMatchScanLength = 80_000
    // ASCII bracket pairs: (), [], {}.
    private static let bracketPairs: [unichar: unichar] = [
        40: 41,
        91: 93,
        123: 125
    ]

    var lineCommentPrefix: String?
    var editorID: String?
    var language: EditorLanguage = .plainText
    var indentation = EditorIndentationSettings.defaultSpaces(width: 4)
    private var isApplyingAcceptedCompletion = false
    private var completionTimer: Timer?
    var requestCompletionUpdate: (() -> Void)?
    var cancelCompletions: (() -> Void)?
    var isCompletionVisible: (() -> Bool)?
    var moveCompletionSelection: ((Int) -> Bool)?
    var acceptSelectedCompletion: (() -> Bool)?
    var autocompleteModeProvider: (() -> EditorAutocompleteMode)?
    var flushPendingModelSync: (() -> Void)?
    var hasPendingModelSync: (() -> Bool)?
    var didBecomeActive: (() -> Void)?
    private var pendingCompletionTriggerSelection: NSRange?

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

    func replaceAllTextPreservingUndo(with replacement: String, actionName: String) -> Bool {
        guard string != replacement else { return false }

        let currentLength = (string as NSString).length
        let replacementLength = (replacement as NSString).length
        let replacementRange = NSRange(location: 0, length: currentLength)
        let previousSelection = selectedRange()
        guard shouldChangeText(in: replacementRange, replacementString: replacement) else { return false }

        unsafe textStorage?.beginEditing()
        unsafe textStorage?.replaceCharacters(in: replacementRange, with: replacement)
        unsafe textStorage?.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)

        let restoredSelection = NSRange(
            location: min(previousSelection.location, replacementLength),
            length: min(previousSelection.length, max(replacementLength - min(previousSelection.location, replacementLength), 0))
        )
        setSelectedRange(restoredSelection)
        return true
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

        let indentUnit = indentation.insertionText
        let updatedActiveLines = lines.prefix(lineCount).map { line in
            if outdent {
                return outdentedLine(line)
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

    private func outdentedLine(_ line: String) -> String {
        switch indentation.style {
        case .spaces:
            let indentUnit = indentation.insertionText
            if line.hasPrefix(indentUnit) {
                return String(line.dropFirst(indentUnit.count))
            }
            if line.hasPrefix("\t") {
                return String(line.dropFirst())
            }
            let leadingSpaces = line.prefix { $0 == " " }
            let removalCount = min(leadingSpaces.count, indentation.width)
            return String(line.dropFirst(removalCount))
        case .tabs:
            if line.hasPrefix("\t") {
                return String(line.dropFirst())
            }
            let leadingSpaces = line.prefix { $0 == " " }
            let removalCount = min(leadingSpaces.count, indentation.width)
            return String(line.dropFirst(removalCount))
        }
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

    @discardableResult
    func focusEditor() -> Bool {
        guard let window = unsafe self.window else { return false }
        let wasFirstResponder = window.firstResponder === self
        let didFocus = window.makeFirstResponder(self)
        if didFocus, wasFirstResponder {
            ActiveEditorTextViewRegistry.shared.register(self)
            didBecomeActive?()
        }
        return didFocus
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
        let indentation = newLineIndentationForInsertion()
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
        super.insertText(indentation.insertionText, replacementRange: selectedRange())
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
        if deleteSmartIndentationBackward() {
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        super.deleteForward(sender)
    }

    func bracketMatchNearSelection() -> (source: NSRange, match: NSRange)? {
        let selectedRange = selectedRange()
        guard selectedRange.length == 0,
              selectedRange.location != NSNotFound else { return nil }

        let nsText = string as NSString
        let textLength = nsText.length
        guard textLength > 0 else { return nil }

        let caretLocation = min(selectedRange.location, textLength)
        let candidateLocations = [
            caretLocation > 0 ? caretLocation - 1 : nil,
            caretLocation < textLength ? caretLocation : nil
        ].compactMap(\.self)

        for location in candidateLocations {
            guard let bracket = bracketCharacter(at: location, in: nsText),
                  let matchLocation = matchingBracketLocation(
                    for: bracket,
                    at: location,
                    in: nsText
                  ) else { continue }

            return (
                source: NSRange(location: location, length: 1),
                match: NSRange(location: matchLocation, length: 1)
            )
        }

        return nil
    }

    func notePendingCompletionTrigger(replacementString: String?, affectedRange: NSRange) {
        guard autocompleteModeProvider?() != .off else {
            cancelPendingCompletionTrigger()
            cancelCompletions?()
            return
        }

        guard !isApplyingAcceptedCompletion else {
            cancelPendingCompletionTrigger()
            return
        }

        guard affectedRange.length == 0,
              let replacementString,
              replacementString.count == 1,
              let scalar = replacementString.unicodeScalars.first else {
            cancelPendingCompletionTrigger()
            return
        }

        let isValidChar = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar)
        if isValidChar {
            switch autocompleteModeProvider?() ?? .on {
            case .on:
                let insertedLength = (replacementString as NSString).length
                pendingCompletionTriggerSelection = NSRange(location: affectedRange.location + insertedLength, length: 0)
                if isCompletionVisible?() == true {
                    cancelCompletionTimer()
                } else {
                    // Reset debounce timer on each valid character — only show completions after a pause.
                    scheduleCompletion(after: Self.completionDelay)
                }
            case .off:
                cancelPendingCompletionTrigger()
                cancelCompletions?()
            }
        } else {
            cancelPendingCompletionTrigger()
            cancelCompletions?()
        }
    }

    func noteSelectionDidChange() {
        if let pendingSelection = pendingCompletionTriggerSelection {
            pendingCompletionTriggerSelection = nil
            if NSEqualRanges(selectedRange(), pendingSelection) {
                return
            }
        }
        cancelCompletionTimer()
    }

    func cancelPendingCompletionTrigger() {
        pendingCompletionTriggerSelection = nil
        cancelCompletionTimer()
    }

    func performAutomaticCompletionIfNeeded() {
        if isCompletionVisible?() == true {
            requestCompletionUpdate?()
        }
    }

    private func scheduleCompletion(after delay: TimeInterval) {
        cancelCompletionTimer()
        completionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.completionTimer = nil
                if let pendingSelection = self.pendingCompletionTriggerSelection,
                   !NSEqualRanges(self.selectedRange(), pendingSelection) {
                    self.pendingCompletionTriggerSelection = nil
                    return
                }
                self.pendingCompletionTriggerSelection = nil
                self.showCompletionIfReady()
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
              currentPartialWordRange()?.length ?? 0 >= Self.minimumCompletionPrefixLength else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  unsafe self.window?.firstResponder === self,
                  !self.isApplyingAcceptedCompletion,
                  self.currentPartialWordRange()?.length ?? 0 >= Self.minimumCompletionPrefixLength else {
                return
            }
            switch self.autocompleteModeProvider?() ?? .on {
            case .on:
                self.requestCompletionUpdate?()
            case .off:
                self.cancelCompletions?()
            }
        }
    }

    private func newLineIndentationForInsertion() -> String {
        let context = currentLineContextForInsertion()
        guard !context.leadingWhitespace.isEmpty || shouldIncreaseIndent(after: context.codeBeforeCaret) else {
            return ""
        }

        if shouldIncreaseIndent(after: context.codeBeforeCaret) {
            return context.leadingWhitespace + indentation.insertionText
        }

        return context.leadingWhitespace
    }

    private func deleteSmartIndentationBackward() -> Bool {
        let selectedRange = selectedRange()
        guard selectedRange.length == 0,
              selectedRange.location != NSNotFound,
              selectedRange.location > 0 else { return false }

        let nsText = string as NSString
        let caretLocation = min(selectedRange.location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: caretLocation, length: 0))
        guard lineRange.location != NSNotFound,
              caretLocation > lineRange.location else { return false }

        let beforeCaretRange = NSRange(
            location: lineRange.location,
            length: caretLocation - lineRange.location
        )
        let beforeCaret = nsText.substring(with: beforeCaretRange)
        guard !beforeCaret.isEmpty,
              beforeCaret.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }

        let deletionLength = smartIndentationDeletionLength(in: beforeCaret)
        guard deletionLength > 0 else { return false }

        let deletionRange = NSRange(location: caretLocation - deletionLength, length: deletionLength)
        guard shouldChangeText(in: deletionRange, replacementString: "") else { return true }

        unsafe textStorage?.beginEditing()
        unsafe textStorage?.replaceCharacters(in: deletionRange, with: "")
        unsafe textStorage?.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: deletionRange.location, length: 0))
        return true
    }

    private func bracketCharacter(at location: Int, in text: NSString) -> unichar? {
        guard location >= 0, location < text.length else { return nil }
        let codeUnit = text.character(at: location)
        return Self.bracketPairs.keys.contains(codeUnit) || Self.bracketPairs.values.contains(codeUnit)
            ? codeUnit
            : nil
    }

    private func matchingBracketLocation(
        for bracket: unichar,
        at location: Int,
        in text: NSString
    ) -> Int? {
        if let closingBracket = Self.bracketPairs[bracket] {
            return scanForMatchingBracket(
                openingBracket: bracket,
                closingBracket: closingBracket,
                startLocation: location + 1,
                limitLocation: min(text.length, location + Self.maximumBracketMatchScanLength),
                direction: 1,
                in: text
            )
        }

        guard let openingBracket = Self.bracketPairs.first(where: { $0.value == bracket })?.key else {
            return nil
        }
        return scanForMatchingBracket(
            openingBracket: openingBracket,
            closingBracket: bracket,
            startLocation: location - 1,
            limitLocation: max(-1, location - Self.maximumBracketMatchScanLength),
            direction: -1,
            in: text
        )
    }

    private func scanForMatchingBracket(
        openingBracket: unichar,
        closingBracket: unichar,
        startLocation: Int,
        limitLocation: Int,
        direction: Int,
        in text: NSString
    ) -> Int? {
        var depth = 1
        var location = startLocation

        while direction > 0 ? location < limitLocation : location > limitLocation {
            let codeUnit = text.character(at: location)
            if codeUnit == openingBracket {
                depth += direction > 0 ? 1 : -1
            } else if codeUnit == closingBracket {
                depth += direction > 0 ? -1 : 1
            }

            if depth == 0 {
                return location
            }

            location += direction
        }

        return nil
    }

    private func smartIndentationDeletionLength(in leadingWhitespace: String) -> Int {
        if leadingWhitespace.hasSuffix("\t") {
            return 1
        }

        let trailingSpaceCount = leadingWhitespace.reversed().prefix { $0 == " " }.count
        guard trailingSpaceCount > 0 else { return 0 }

        let currentColumn = indentationColumnCount(in: leadingWhitespace)
        let width = max(indentation.width, 1)
        let targetColumn = ((max(currentColumn, 1) - 1) / width) * width
        let preferredRemovalCount = max(currentColumn - targetColumn, 1)
        return min(trailingSpaceCount, preferredRemovalCount)
    }

    private func indentationColumnCount(in leadingWhitespace: String) -> Int {
        let width = max(indentation.width, 1)
        var column = 0

        for character in leadingWhitespace {
            if character == "\t" {
                let remainder = column % width
                column += remainder == 0 ? width : width - remainder
            } else {
                column += 1
            }
        }

        return column
    }

    private func currentLineContextForInsertion() -> (leadingWhitespace: String, codeBeforeCaret: String) {
        let nsText = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound else { return ("", "") }

        let location = min(selection.location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        guard lineRange.location != NSNotFound, lineRange.length > 0 else { return ("", "") }

        let line = nsText.substring(with: lineRange)
        let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
        let lineStart = lineRange.location
        let beforeCaretLength = max(location - lineStart, 0)
        let beforeCaret = nsText.substring(with: NSRange(location: lineStart, length: beforeCaretLength))

        return (
            leadingWhitespace: leadingWhitespace,
            codeBeforeCaret: codeBeforeComment(in: beforeCaret).trimmingCharacters(in: .whitespaces)
        )
    }

    private func shouldIncreaseIndent(after code: String) -> Bool {
        guard !code.isEmpty else { return false }

        switch language {
        case .python:
            return shouldIncreasePythonIndent(after: code)
        case .shell:
            return shouldIncreaseShellIndent(after: code)
        case .powerShell:
            return shouldIncreasePowerShellIndent(after: code)
        case .json:
            return shouldIncreaseJSONIndent(after: code)
        case .xml:
            return shouldIncreaseXMLIndent(after: code)
        case .plainText, .logfile, .markdown, .dotenv:
            return false
        }
    }

    private func shouldIncreasePythonIndent(after code: String) -> Bool {
        code.hasSuffix(":")
    }

    private func shouldIncreaseShellIndent(after code: String) -> Bool {
        let lowercased = code.lowercased()
        if code.hasSuffix("{") || code.hasSuffix("\\") {
            return true
        }

        return lowercased.hasSuffix(" then")
            || lowercased == "then"
            || lowercased.hasSuffix("; then")
            || lowercased.hasSuffix(" do")
            || lowercased == "do"
            || lowercased.hasSuffix("; do")
            || (lowercased.hasPrefix("case ") && lowercased.hasSuffix(" in"))
    }

    private func shouldIncreasePowerShellIndent(after code: String) -> Bool {
        code.hasSuffix("{")
            || code.hasSuffix("(")
            || code.hasSuffix("[")
    }

    private func shouldIncreaseJSONIndent(after code: String) -> Bool {
        code.hasSuffix("{") || code.hasSuffix("[")
    }

    private func shouldIncreaseXMLIndent(after code: String) -> Bool {
        guard code.hasSuffix(">"),
              let tagStart = code.lastIndex(of: "<") else { return false }

        let tag = String(code[tagStart...])
        guard !tag.hasSuffix("/>"),
              !tag.hasSuffix("-->"),
              !tag.hasPrefix("</"),
              !tag.hasPrefix("<!"),
              !tag.hasPrefix("<?") else { return false }

        guard let openingTagRange = tag.range(
            of: #"<[A-Za-z_][A-Za-z0-9_.:-]*(?:\s+[^<>]*)?>"#,
            options: .regularExpression
        ) else { return false }
        return openingTagRange.lowerBound == tag.startIndex
            && openingTagRange.upperBound == tag.endIndex
    }

    private func codeBeforeComment(in line: String) -> String {
        switch language {
        case .python, .shell, .powerShell, .dotenv:
            return String(line.prefixBeforeCommentMarker("#"))
        case .plainText, .logfile, .markdown, .xml, .json:
            return line
        }
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
        case 49:
            cancelCompletions?()
            return false
        case 53:
            cancelCompletions?()
            return true
        default:
            return false
        }
    }

}

private extension String {
    func prefixBeforeCommentMarker(_ marker: Character) -> Substring {
        var cursor = startIndex
        var isInSingleQuotedString = false
        var isInDoubleQuotedString = false
        var isEscapingNextCharacter = false

        while cursor < endIndex {
            let character = self[cursor]

            if isEscapingNextCharacter {
                isEscapingNextCharacter = false
                cursor = index(after: cursor)
                continue
            }

            if character == "\\" || character == "`" {
                isEscapingNextCharacter = isInDoubleQuotedString || !isInSingleQuotedString
                cursor = index(after: cursor)
                continue
            }

            if character == "'", !isInDoubleQuotedString {
                isInSingleQuotedString.toggle()
                cursor = index(after: cursor)
                continue
            }

            if character == "\"", !isInSingleQuotedString {
                isInDoubleQuotedString.toggle()
                cursor = index(after: cursor)
                continue
            }

            if character == marker, !isInSingleQuotedString, !isInDoubleQuotedString {
                return self[..<cursor]
            }

            cursor = index(after: cursor)
        }

        return self[...]
    }
}

final class PaddedEditorDocumentView: NSView {
    private weak var textView: LineClickableTextView?
    private var textViewWidthConstraint: NSLayoutConstraint?
    private var textViewHeightConstraint: NSLayoutConstraint?
    private var intendedTextViewSize: NSSize = .zero
    private var lastMinimumSize: NSSize = .zero
    private var isUpdatingLayout = false
    private var shouldRequestInitialFocus = false

    var backgroundColor: NSColor = .textBackgroundColor {
        didSet {
            needsDisplay = true
            textView?.backgroundColor = backgroundColor
        }
    }

    var bottomPadding: CGFloat = 0 {
        didSet {
            guard abs(bottomPadding - oldValue) > 0.5 else { return }
            updateLayout(minimumSize: lastMinimumSize)
        }
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(textView: LineClickableTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        let leadingConstraint = textView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let topConstraint = textView.topAnchor.constraint(equalTo: topAnchor)
        let widthConstraint = textView.widthAnchor.constraint(equalToConstant: max(textView.frame.width, 0))
        let heightConstraint = textView.heightAnchor.constraint(equalToConstant: max(textView.frame.height, 0))
        textViewWidthConstraint = widthConstraint
        textViewHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            leadingConstraint,
            topConstraint,
            widthConstraint,
            heightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusEditorIfRequested()
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView else {
            super.mouseDown(with: event)
            return
        }

        textView.focusEditor()
        if !textView.frame.contains(convert(event.locationInWindow, from: nil)) {
            textView.moveToEndOfDocument(nil)
            return
        }

        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }

    func requestInitialFocus() {
        shouldRequestInitialFocus = true
        focusEditorIfRequested()
    }

    func updateLayout(minimumSize: NSSize) {
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        defer { isUpdatingLayout = false }

        lastMinimumSize = minimumSize
        guard let textView else { return }

        let currentTextSize = intendedTextViewSize == .zero ? textView.frame.size : intendedTextViewSize
        let textSize = NSSize(
            width: max(currentTextSize.width, minimumSize.width),
            height: max(currentTextSize.height, 0)
        )
        updateTextViewSize(textSize)

        let newSize = NSSize(
            width: textSize.width,
            height: max(textSize.height + bottomPadding, minimumSize.height)
        )
        if abs(frame.width - newSize.width) > 0.5 || abs(frame.height - newSize.height) > 0.5 {
            setFrameSize(newSize)
        }
        needsDisplay = true
    }

    func updateTextViewSize(_ size: NSSize) {
        guard let textView else { return }
        let textSize = NSSize(width: max(size.width, 0), height: max(size.height, 0))
        intendedTextViewSize = textSize
        if textView.frame.origin != .zero || abs(textView.frame.width - textSize.width) > 0.5 || abs(textView.frame.height - textSize.height) > 0.5 {
            textView.frame = NSRect(origin: .zero, size: textSize)
        }
        updateTextViewConstraints(size: textSize)
    }

    private func updateTextViewConstraints(size: NSSize) {
        var didChange = false
        if let textViewWidthConstraint, abs(textViewWidthConstraint.constant - size.width) > 0.5 {
            textViewWidthConstraint.constant = size.width
            didChange = true
        }
        if let textViewHeightConstraint, abs(textViewHeightConstraint.constant - size.height) > 0.5 {
            textViewHeightConstraint.constant = size.height
            didChange = true
        }
        if didChange {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func focusEditorIfRequested() {
        guard shouldRequestInitialFocus,
              let textView,
              let window = unsafe self.window else { return }
        shouldRequestInitialFocus = false

        DispatchQueue.main.async { [weak textView, weak window] in
            guard let textView,
                  let window,
                  unsafe textView.window === window,
                  Self.canClaimInitialFocus(in: window, textView: textView) else {
                return
            }
            textView.focusEditor()
        }
    }

    private static func canClaimInitialFocus(in window: NSWindow, textView: LineClickableTextView) -> Bool {
        guard let firstResponder = window.firstResponder else { return true }
        if firstResponder === textView { return false }
        if firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }
        return true
    }
}

final class EditorContainerView: NSView {
    private let minimumGutterWidth: CGFloat = 56
    private var gutterView: GutterView?
    private var scrollView: NSScrollView?
    private let completionPopupView = CompletionPopupView()
    var onLayout: (() -> Void)?

    private var gutterWidth: CGFloat {
        max(minimumGutterWidth, gutterView?.preferredWidth ?? minimumGutterWidth)
    }

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
        onLayout?()
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
        didSet {
            updatePreferredWidth()
            needsDisplay = true
        }
    }
    private var lineIndex = GutterLineIndex()
    private let minimumWidth: CGFloat = 56
    private(set) var preferredWidth: CGFloat = 56 {
        didSet {
            guard abs(preferredWidth - oldValue) >= 0.5 else { return }
            unsafe superview?.needsLayout = true
            needsDisplay = true
        }
    }
    
    // Cache for scroll offset to avoid redundant redraws
    var lastClipOrigin: CGPoint = .zero

    var lineCount: Int {
        lineIndex.lineCount
    }

    var maximumLineLength: Int {
        lineIndex.maximumLineLength
    }

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
        let textLength = text.length
        let selectedLine = selectedLineNumber(in: textView, textLength: textLength)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        var glyphIndex = visibleGlyphRange.location

        while glyphIndex < NSMaxRange(visibleGlyphRange), glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphRange = NSRange()
            let lineRect = unsafe layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let logicalLineRange = text.lineRange(for: NSRange(location: min(characterIndex, textLength), length: 0))
            let logicalLineStart = logicalLineRange.location
            let lineNumber = lineNumber(atCharacterIndex: logicalLineStart, textLength: textLength)
            let isFirstVisualFragmentForLine = characterIndex == logicalLineStart
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
            if isFirstVisualFragmentForLine {
                let label = NSAttributedString(string: "\(lineNumber)", attributes: attributes)
                label.draw(in: NSRect(x: 12, y: y + 1, width: bounds.width - 18, height: height))
            }

            glyphIndex = NSMaxRange(lineGlyphRange)
        }

        drawExtraLineFragmentIfNeeded(
            layoutManager: layoutManager,
            clipOrigin: clipOrigin,
            selectedLine: selectedLine,
            lineNumber: lineNumber(atCharacterIndex: textLength, textLength: textLength)
        )
        
        // Update cache
        lastClipOrigin = clipOrigin
    }

    func rebuildLineIndex(for text: NSString) {
        lineIndex.rebuild(with: text)
        updatePreferredWidth()
        needsDisplay = true
    }

    func applyLineIndexEdit(range: NSRange, replacement: NSString) {
        lineIndex.applyEdit(range: range, replacement: replacement)
        updatePreferredWidth()
        needsDisplay = true
    }

    private func selectedLineNumber(in textView: NSTextView, textLength: Int) -> Int {
        lineNumber(atCharacterIndex: textView.selectedRange().location, textLength: textLength)
    }

    private func lineNumber(atCharacterIndex characterIndex: Int, textLength: Int) -> Int {
        lineIndex.lineNumber(atCharacterIndex: characterIndex, textLength: textLength)
    }

    func estimatedVisualLineCount(charactersPerLine: Int, textLength: Int) -> Int {
        lineIndex.estimatedVisualLineCount(charactersPerLine: charactersPerLine, textLength: textLength)
    }

    private func updatePreferredWidth() {
        let digitCount = max(String(lineIndex.lineCount).count, 3)
        let sample = String(repeating: "8", count: digitCount) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: theme.font]
        let textWidth = ceil(sample.size(withAttributes: attributes).width)
        preferredWidth = max(minimumWidth, textWidth + 22)
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
        label.draw(in: NSRect(x: 12, y: y + 1, width: bounds.width - 18, height: height))
    }
}
