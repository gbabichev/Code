//
//  CodeEditorView.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
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

private struct SourceLine {
    let index: Int
    let content: String
    let fullText: String
    let indentation: Int
    let leadingWhitespace: String

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespaces)
    }

    var isBlank: Bool {
        trimmedContent.isEmpty
    }
}

private struct CodeFoldRegion: Identifiable {
    let id: String
    let startLineIndex: Int
    let endLineIndex: Int
    let placeholderLeadingWhitespace: String
}

struct ProjectedFoldRegion {
    let id: String
    let visibleHeaderLineNumber: Int
    let isCollapsed: Bool
}

private struct FoldProjection {
    let displayText: String
    let projectedRegions: [ProjectedFoldRegion]
}

private enum CodeFoldDetector {
    private static let pythonHeaderPattern = try! NSRegularExpression(
        pattern: #"^\s*(async\s+def|def|class)\b.*:\s*(#.*)?$"#
    )
    private static let shellFunctionSignaturePattern = try! NSRegularExpression(
        pattern: #"^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_.:-]*\s*(?:\(\s*\))?\s*(?:\{\s*)?$"#
    )
    private static let powerShellHeaderPattern = try! NSRegularExpression(
        pattern: #"^\s*(function|filter|class)\b.*\{"#
    )

    static func regions(in text: String, language: EditorLanguage) -> [CodeFoldRegion] {
        let lines = sourceLines(from: text)
        guard !lines.isEmpty else { return [] }

        let rawRegions: [CodeFoldRegion]
        switch language {
        case .python:
            rawRegions = pythonRegions(in: lines)
        case .shell:
            rawRegions = shellRegions(in: lines)
        case .powerShell:
            rawRegions = braceRegions(in: lines, headerPattern: powerShellHeaderPattern)
        case .plainText, .dotenv:
            rawRegions = []
        }

        return filterNested(rawRegions)
    }

    static func project(text: String, regions: [CodeFoldRegion], collapsedRegionIDs: Set<String>) -> FoldProjection {
        let lines = sourceLines(from: text)
        guard !lines.isEmpty else {
            return FoldProjection(displayText: text, projectedRegions: [])
        }

        let regionsByStart = Dictionary(uniqueKeysWithValues: regions.map { ($0.startLineIndex, $0) })
        var projectedRegions: [ProjectedFoldRegion] = []
        var displayText = ""
        var sourceLineIndex = 0
        var visibleLineNumber = 1

        while sourceLineIndex < lines.count {
            let line = lines[sourceLineIndex]
            displayText += line.fullText

            if let region = regionsByStart[sourceLineIndex] {
                let isCollapsed = collapsedRegionIDs.contains(region.id)
                projectedRegions.append(
                    ProjectedFoldRegion(
                        id: region.id,
                        visibleHeaderLineNumber: visibleLineNumber,
                        isCollapsed: isCollapsed
                    )
                )

                if isCollapsed {
                    let placeholder = region.placeholderLeadingWhitespace + "..."
                    let collapsesToEOF = region.endLineIndex == lines.count - 1
                    displayText += collapsesToEOF ? placeholder : placeholder + "\n"
                    visibleLineNumber += 2
                    sourceLineIndex = region.endLineIndex + 1
                    continue
                }
            }

            visibleLineNumber += 1
            sourceLineIndex += 1
        }

        return FoldProjection(displayText: displayText, projectedRegions: projectedRegions)
    }

    private static func pythonRegions(in lines: [SourceLine]) -> [CodeFoldRegion] {
        var regions: [CodeFoldRegion] = []

        for line in lines {
            guard isMatch(pythonHeaderPattern, text: line.content),
                  let bodyStartIndex = nextNonBlankLine(after: line.index, in: lines),
                  lines[bodyStartIndex].indentation > line.indentation else {
                continue
            }

            var endIndex = bodyStartIndex
            var probe = bodyStartIndex + 1

            while probe < lines.count {
                let candidate = lines[probe]
                if candidate.isBlank {
                    endIndex = probe
                    probe += 1
                    continue
                }

                if candidate.indentation <= line.indentation {
                    break
                }

                endIndex = probe
                probe += 1
            }

            if endIndex > line.index {
                regions.append(
                    CodeFoldRegion(
                        id: "python:\(line.index):\(endIndex)",
                        startLineIndex: line.index,
                        endLineIndex: endIndex,
                        placeholderLeadingWhitespace: lines[bodyStartIndex].leadingWhitespace
                    )
                )
            }
        }

        return regions
    }

    private static func shellRegions(in lines: [SourceLine]) -> [CodeFoldRegion] {
        var regions: [CodeFoldRegion] = []

        for line in lines where isMatch(shellFunctionSignaturePattern, text: line.content) {
            let braceLineIndex: Int
            if braceDelta(in: line.content) > 0 {
                braceLineIndex = line.index
            } else if let nextLineIndex = nextNonBlankLine(after: line.index, in: lines),
                      lines[nextLineIndex].trimmedContent == "{" {
                braceLineIndex = nextLineIndex
            } else {
                continue
            }

            var balance = 0
            var probe = braceLineIndex
            var endIndex: Int?

            while probe < lines.count {
                balance += braceDelta(in: lines[probe].content)
                if balance <= 0, probe > braceLineIndex {
                    endIndex = probe
                    break
                }
                probe += 1
            }

            guard let endIndex, endIndex > line.index else { continue }
            let bodyStartIndex = min(braceLineIndex + 1, endIndex)
            regions.append(
                CodeFoldRegion(
                    id: "shell:\(line.index):\(endIndex)",
                    startLineIndex: line.index,
                    endLineIndex: endIndex,
                    placeholderLeadingWhitespace: lines[bodyStartIndex].leadingWhitespace
                )
            )
        }

        return regions
    }

    private static func braceRegions(in lines: [SourceLine], headerPattern: NSRegularExpression) -> [CodeFoldRegion] {
        var regions: [CodeFoldRegion] = []

        for line in lines where isMatch(headerPattern, text: line.content) {
            let headerBalance = braceDelta(in: line.content)
            guard headerBalance > 0 else { continue }

            var balance = headerBalance
            var probe = line.index + 1
            var endIndex: Int?

            while probe < lines.count {
                balance += braceDelta(in: lines[probe].content)
                if balance <= 0 {
                    endIndex = probe
                    break
                }
                probe += 1
            }

            guard let endIndex, endIndex > line.index else { continue }
            let bodyStartIndex = min(line.index + 1, endIndex)
            regions.append(
                CodeFoldRegion(
                    id: "brace:\(line.index):\(endIndex)",
                    startLineIndex: line.index,
                    endLineIndex: endIndex,
                    placeholderLeadingWhitespace: lines[bodyStartIndex].leadingWhitespace
                )
            )
        }

        return regions
    }

    private static func sourceLines(from text: String) -> [SourceLine] {
        guard !text.isEmpty else { return [] }

        var lines: [SourceLine] = []
        var startIndex = text.startIndex
        var lineIndex = 0

        while startIndex < text.endIndex {
            if let newlineIndex = text[startIndex...].firstIndex(of: "\n") {
                let content = String(text[startIndex..<newlineIndex])
                let fullText = String(text[startIndex...newlineIndex])
                let leadingWhitespace = String(content.prefix { $0 == " " || $0 == "\t" })
                lines.append(
                    SourceLine(
                        index: lineIndex,
                        content: content,
                        fullText: fullText,
                        indentation: indentationWidth(for: leadingWhitespace),
                        leadingWhitespace: leadingWhitespace
                    )
                )
                startIndex = text.index(after: newlineIndex)
            } else {
                let content = String(text[startIndex...])
                let leadingWhitespace = String(content.prefix { $0 == " " || $0 == "\t" })
                lines.append(
                    SourceLine(
                        index: lineIndex,
                        content: content,
                        fullText: content,
                        indentation: indentationWidth(for: leadingWhitespace),
                        leadingWhitespace: leadingWhitespace
                    )
                )
                break
            }

            lineIndex += 1
        }

        return lines
    }

    private static func nextNonBlankLine(after lineIndex: Int, in lines: [SourceLine]) -> Int? {
        var probe = lineIndex + 1
        while probe < lines.count {
            if !lines[probe].isBlank {
                return probe
            }
            probe += 1
        }
        return nil
    }

    private static func filterNested(_ regions: [CodeFoldRegion]) -> [CodeFoldRegion] {
        let sorted = regions.sorted {
            if $0.startLineIndex == $1.startLineIndex {
                return $0.endLineIndex < $1.endLineIndex
            }
            return $0.startLineIndex < $1.startLineIndex
        }

        var filtered: [CodeFoldRegion] = []
        for region in sorted {
            if let previous = filtered.last,
               region.startLineIndex > previous.startLineIndex,
               region.endLineIndex <= previous.endLineIndex {
                continue
            }
            filtered.append(region)
        }
        return filtered
    }

    private static func indentationWidth(for whitespace: String) -> Int {
        whitespace.reduce(into: 0) { width, character in
            width += character == "\t" ? 4 : 1
        }
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var isInSingleQuote = false
        var isInDoubleQuote = false
        var isEscaped = false

        for character in line {
            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "'" && !isInDoubleQuote {
                isInSingleQuote.toggle()
                continue
            }

            if character == "\"" && !isInSingleQuote {
                isInDoubleQuote.toggle()
                continue
            }

            if isInSingleQuote || isInDoubleQuote {
                continue
            }

            if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }

        return delta
    }

    private static func isMatch(_ regex: NSRegularExpression, text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let isWordWrapEnabled: Bool
    let skin: SkinDefinition
    let language: EditorLanguage
    let editorFont: NSFont
    let editorSemiboldFont: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(textBinding: $text, language: language, skin: skin, editorFont: editorFont, editorSemiboldFont: editorSemiboldFont)
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
        let clipView = EditorClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !isWordWrapEnabled
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = theme.editorBackgroundColor
        scrollView.drawsBackground = true
        scrollView.contentView = clipView
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        container.embed(gutterView: context.coordinator.gutterView, scrollView: scrollView)
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.applyTheme(theme)
        context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)
        _ = context.coordinator.syncWithBindingText(text)
        context.coordinator.applyHighlighting(force: true)

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let didLanguageChange = context.coordinator.language != language
        let didSkinChange = context.coordinator.skin != skin
        let didFontChange = context.coordinator.editorFont.fontName != editorFont.fontName
            || context.coordinator.editorFont.pointSize != editorFont.pointSize
            || context.coordinator.editorSemiboldFont.fontName != editorSemiboldFont.fontName
            || context.coordinator.editorSemiboldFont.pointSize != editorSemiboldFont.pointSize

        context.coordinator.language = language
        context.coordinator.skin = skin
        context.coordinator.textBinding = $text
        context.coordinator.editorFont = editorFont
        context.coordinator.editorSemiboldFont = editorSemiboldFont

        if didLanguageChange || didSkinChange || didFontChange {
            let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: editorSemiboldFont)
            context.coordinator.applyTheme(theme)
        }
        context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)

        guard let textView = context.coordinator.textView else { return }
        ActiveEditorTextViewRegistry.shared.register(textView)
        let didTextChange = context.coordinator.syncWithBindingText(text)
        if didLanguageChange || didSkinChange || didFontChange || didTextChange || context.coordinator.requiresHighlightRefresh {
            context.coordinator.applyHighlighting(force: true)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var language: EditorLanguage
        var skin: SkinDefinition
        var editorFont: NSFont
        var editorSemiboldFont: NSFont
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        let gutterView = GutterView(frame: .zero)
        private var isApplyingHighlighting = false
        private var isApplyingProjection = false
        private var sourceText: String
        private var detectedFoldRegions: [CodeFoldRegion] = []
        private var projectedFoldRegions: [ProjectedFoldRegion] = []
        private var collapsedRegionIDs: Set<String> = []
        private(set) var requiresHighlightRefresh = true
        private var pendingRefreshWorkItem: DispatchWorkItem?
        private var pendingFoldRefresh = false

        init(textBinding: Binding<String>, language: EditorLanguage, skin: SkinDefinition, editorFont: NSFont, editorSemiboldFont: NSFont) {
            self.textBinding = textBinding
            self.language = language
            self.skin = skin
            self.editorFont = editorFont
            self.editorSemiboldFont = editorSemiboldFont
            self.sourceText = textBinding.wrappedValue
        }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            gutterView.textView = textView
            gutterView.onToggleFold = { [weak self] regionID in
                self?.toggleFold(regionID: regionID)
            }
            ActiveEditorTextViewRegistry.shared.register(textView)

            if let lineClickableTextView = textView as? LineClickableTextView {
                lineClickableTextView.beforeEditingHandler = { [weak self] in
                    self?.expandAllFoldsIfNeeded()
                }
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
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
            guard let textView, !isApplyingProjection else { return }
            let editedRange = unsafe textView.textStorage?.editedRange
            sourceText = textView.string
            textBinding.wrappedValue = sourceText
            applyHighlighting(in: editedRange)
            textView.needsDisplay = true
            gutterView.needsDisplay = true
            if pendingFoldRefresh {
                pendingFoldRefresh = false
                scheduleDeferredEditorRefresh()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            pendingFoldRefresh = pendingFoldRefresh || editRequiresFoldRefresh(
                in: textView.string,
                affectedCharRange: affectedCharRange,
                replacementString: replacementString
            )
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isApplyingHighlighting { return }
            textView?.needsDisplay = true
            gutterView.needsDisplay = true
        }

        func configureLayout(isWordWrapEnabled: Bool) {
            guard let textView, let textContainer = unsafe textView.textContainer else { return }

            textContainer.heightTracksTextView = false

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

            unsafe textView.layoutManager?.ensureLayout(for: textContainer)
            textView.sizeToFit()
            let minimumWidth = max((scrollView?.contentSize.width ?? textView.bounds.width), 0)
            if textView.frame.width < minimumWidth {
                textView.frame.size.width = minimumWidth
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
            }
            scrollView?.backgroundColor = theme.editorBackgroundColor
            gutterView.theme = theme
            gutterView.needsDisplay = true
        }

        func syncWithBindingText(_ text: String) -> Bool {
            if sourceText != text {
                sourceText = text
            }
            return recalculateFolds()
        }

        func applyHighlighting(force: Bool = false, in editedRange: NSRange? = nil) {
            guard let textView, let textStorage = unsafe textView.textStorage else { return }
            if isApplyingHighlighting { return }
            if !force, editedRange == nil, textView.string == textBinding.wrappedValue { return }

            isApplyingHighlighting = true
            let selectedRanges = textView.selectedRanges
            textStorage.beginEditing()
            SyntaxHighlighterFactory.makeHighlighter(
                for: language,
                skin: skin,
                editorFont: editorFont,
                semiboldFont: editorSemiboldFont
            )
            .apply(to: textStorage, text: textView.string, in: force ? nil : editedRange)
            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
            textView.needsDisplay = true
            gutterView.needsDisplay = true
            isApplyingHighlighting = false
            requiresHighlightRefresh = false
        }

        private func recalculateFolds() -> Bool {
            guard let textView else { return false }

            detectedFoldRegions = CodeFoldDetector.regions(in: sourceText, language: language)
            let validRegionIDs = Set(detectedFoldRegions.map(\.id))
            collapsedRegionIDs = collapsedRegionIDs.intersection(validRegionIDs)

            let projection = CodeFoldDetector.project(
                text: sourceText,
                regions: detectedFoldRegions,
                collapsedRegionIDs: collapsedRegionIDs
            )
            projectedFoldRegions = projection.projectedRegions
            gutterView.projectedFoldRegions = projectedFoldRegions

            var didChange = false
            if textView.string != projection.displayText {
                isApplyingProjection = true
                textView.string = projection.displayText
                isApplyingProjection = false
                didChange = true
                requiresHighlightRefresh = true
            }

            if let layoutManager = unsafe textView.layoutManager,
               let textContainer = unsafe textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }

            return didChange
        }

        private func toggleFold(regionID: String) {
            cancelDeferredEditorRefresh()
            if collapsedRegionIDs.contains(regionID) {
                collapsedRegionIDs.remove(regionID)
            } else {
                collapsedRegionIDs.insert(regionID)
            }

            _ = recalculateFolds()
            applyHighlighting(force: true)
            textView?.needsDisplay = true
            gutterView.needsDisplay = true
        }

        private func expandAllFoldsIfNeeded() {
            guard !collapsedRegionIDs.isEmpty else { return }
            cancelDeferredEditorRefresh()
            collapsedRegionIDs.removeAll()
            _ = recalculateFolds()
            applyHighlighting(force: true)
        }

        private func scheduleDeferredEditorRefresh() {
            pendingRefreshWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRefreshWorkItem = nil
                let didChangeProjection = self.recalculateFolds()
                if didChangeProjection || self.requiresHighlightRefresh {
                    self.applyHighlighting(force: true)
                }
            }

            pendingRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func cancelDeferredEditorRefresh() {
            pendingRefreshWorkItem?.cancel()
            pendingRefreshWorkItem = nil
        }

        private func editRequiresFoldRefresh(in currentText: String, affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard language != .plainText, language != .dotenv else { return false }
            guard let replacementString else { return true }

            let nsText = currentText as NSString
            let safeLocation = min(max(affectedCharRange.location, 0), nsText.length)
            let safeLength = min(max(affectedCharRange.length, 0), nsText.length - safeLocation)
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            let removedText = safeRange.length > 0 ? nsText.substring(with: safeRange) : ""

            if containsFoldStructuralToken(replacementString) || containsFoldStructuralToken(removedText) {
                return true
            }

            if language == .python, editTouchesPythonIndentation(in: nsText, affectedCharRange: safeRange) {
                return true
            }

            return false
        }

        private func containsFoldStructuralToken(_ text: String) -> Bool {
            switch language {
            case .python:
                return text.contains("\n") || text.contains(":")
            case .shell, .powerShell:
                return text.contains("\n") || text.contains("{") || text.contains("}")
            case .plainText, .dotenv:
                return false
            }
        }

        private func editTouchesPythonIndentation(in text: NSString, affectedCharRange: NSRange) -> Bool {
            let lineStart = lineStartIndex(in: text, for: affectedCharRange.location)
            let lineEnd = lineEndIndex(in: text, from: lineStart)

            var firstNonWhitespace = lineStart
            while firstNonWhitespace < lineEnd {
                let character = text.character(at: firstNonWhitespace)
                if character != 32 && character != 9 {
                    break
                }
                firstNonWhitespace += 1
            }

            return affectedCharRange.location <= firstNonWhitespace
        }

        private func lineStartIndex(in text: NSString, for location: Int) -> Int {
            guard text.length > 0 else { return 0 }
            var index = min(max(location, 0), text.length)
            if index == text.length, index > 0 {
                index -= 1
            }
            while index > 0, text.character(at: index - 1) != 10 {
                index -= 1
            }
            return index
        }

        private func lineEndIndex(in text: NSString, from location: Int) -> Int {
            var index = min(max(location, 0), text.length)
            while index < text.length, text.character(at: index) != 10 {
                index += 1
            }
            return index
        }

        @objc
        private func handleBoundsDidChange() {
            gutterView.needsDisplay = true
        }
    }
}

final class LineClickableTextView: NSTextView {
    var currentLineHighlightColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var beforeEditingHandler: (() -> Void)?
    var lineCommentPrefix: String?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        ActiveEditorTextViewRegistry.shared.register(self)

        if event.type == .leftMouseDown,
           event.clickCount == 1,
           moveInsertionPointToClickedLineIfNeeded(event: event) {
            return
        }

        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        ActiveEditorTextViewRegistry.shared.register(self)
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
        if !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            beforeEditingHandler?()
        }
        super.keyDown(with: event)
    }

    func toggleLineComment() {
        guard let lineCommentPrefix else { return }
        beforeEditingHandler?()

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
        beforeEditingHandler?()

        let nsText = string as NSString
        let selectedRange = selectedRange()
        let lineRange = nsText.lineRange(for: selectedRange)
        let block = nsText.substring(with: lineRange)
        let originalHasTrailingNewline = block.hasSuffix("\n")
        let lines = block.components(separatedBy: "\n")
        let lineCount = originalHasTrailingNewline ? max(lines.count - 1, 0) : lines.count
        guard lineCount > 0 else { return }

        let indentUnit = "    "
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
        }
        return didBecomeFirstResponder
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        beforeEditingHandler?()
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        beforeEditingHandler?()
        super.paste(sender)
    }

    override func cut(_ sender: Any?) {
        beforeEditingHandler?()
        super.cut(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        beforeEditingHandler?()
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        beforeEditingHandler?()
        super.deleteForward(sender)
    }

    @discardableResult
    func moveInsertionPointToClosestLine(for pointInSelf: NSPoint) -> Bool {
        guard let layoutManager = unsafe layoutManager,
              let textContainer = unsafe textContainer else {
            return false
        }

        let containerPoint = NSPoint(
            x: pointInSelf.x - textContainerInset.width,
            y: pointInSelf.y - textContainerInset.height
        )

        guard let selectionIndex = insertionIndexForTrailingLineClick(
            point: pointInSelf,
            containerPoint: containerPoint,
            layoutManager: layoutManager,
            textContainer: textContainer
        ) else {
            return false
        }

        unsafe window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: selectionIndex, length: 0))
        return true
    }

    @discardableResult
    private func moveInsertionPointToClickedLineIfNeeded(event: NSEvent) -> Bool {
        guard unsafe layoutManager != nil,
              unsafe textContainer != nil else {
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard moveInsertionPointToClosestLine(for: point) else {
            return false
        }
        return true
    }

    private func insertionIndexForExtraLineClick(
        point: NSPoint,
        containerPoint: NSPoint,
        layoutManager: NSLayoutManager
    ) -> Int? {
        let extraLineRect = layoutManager.extraLineFragmentRect
        guard !extraLineRect.isEmpty else { return nil }
        guard containerPoint.y >= extraLineRect.minY, containerPoint.y <= extraLineRect.maxY else { return nil }

        let usedRect = layoutManager.extraLineFragmentUsedRect
        let visualMaxX = textContainerInset.width + max(usedRect.maxX, 0)
        guard point.x >= visualMaxX else { return nil }

        return string.count
    }

    private func insertionIndexForTrailingLineClick(
        point: NSPoint,
        containerPoint: NSPoint,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> Int? {
        if let extraLineSelection = insertionIndexForExtraLineClick(
            point: point,
            containerPoint: containerPoint,
            layoutManager: layoutManager
        ) {
            return extraLineSelection
        }

        guard let lineHit = lineHitTest(at: containerPoint, layoutManager: layoutManager, textContainer: textContainer) else {
            return nil
        }

        let visualMaxX = textContainerInset.width + lineHit.usedRect.maxX
        guard point.x >= visualMaxX else { return nil }

        var insertionIndex = NSMaxRange(lineHit.characterRange)
        let text = string as NSString
        if insertionIndex > 0,
           insertionIndex <= text.length,
           text.character(at: insertionIndex - 1) == 10 {
            insertionIndex -= 1
        }

        return insertionIndex
    }

    private func lineHitTest(
        at containerPoint: NSPoint,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> (usedRect: NSRect, characterRange: NSRange)? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }

        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphRange = NSRange()
            let lineRect = unsafe layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )

            if containerPoint.y >= lineRect.minY, containerPoint.y <= lineRect.maxY {
                let usedRect = unsafe layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil,
                    withoutAdditionalLayout: true
                )
                let characterRange = unsafe layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                return (usedRect, characterRange)
            }

            glyphIndex = NSMaxRange(lineGlyphRange)
        }

        return nil
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        guard currentLineHighlightColor.alphaComponent > 0,
              let layoutManager = unsafe layoutManager,
              let textContainer = unsafe textContainer else {
            return
        }

        let highlightRect = currentLineHighlightRect(
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard highlightRect.intersects(dirtyRect) else { return }

        currentLineHighlightColor.setFill()
        highlightRect.fill()
    }

    private func currentLineHighlightRect(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect {
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

final class EditorClipView: NSClipView {
    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? LineClickableTextView else {
            super.mouseDown(with: event)
            return
        }

        let clipPoint = convert(event.locationInWindow, from: nil)
        let textPoint = convert(clipPoint, to: textView)
        if textView.moveInsertionPointToClosestLine(for: textPoint) {
            return
        }

        super.mouseDown(with: event)
    }
}

final class EditorContainerView: NSView {
    private let gutterWidth: CGFloat = 56
    private var gutterView: GutterView?
    private var scrollView: NSScrollView?

    func embed(gutterView: GutterView, scrollView: NSScrollView) {
        self.gutterView?.removeFromSuperview()
        self.scrollView?.removeFromSuperview()

        self.gutterView = gutterView
        self.scrollView = scrollView

        addSubview(gutterView)
        addSubview(scrollView)
    }

    override func layout() {
        super.layout()

        guard let gutterView, let scrollView else { return }
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
    }
}

final class GutterView: NSView {
    weak var textView: NSTextView?
    var projectedFoldRegions: [ProjectedFoldRegion] = [] {
        didSet { needsDisplay = true }
    }
    var onToggleFold: ((String) -> Void)?
    var theme = SkinTheme.fallback {
        didSet { needsDisplay = true }
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
        let selectedLine = selectedLineNumber(in: textView)
        let foldRegionByLine = Dictionary(uniqueKeysWithValues: projectedFoldRegions.map { ($0.visibleHeaderLineNumber, $0) })

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

            if let foldRegion = foldRegionByLine[lineNumber] {
                drawFoldIndicator(
                    isCollapsed: foldRegion.isCollapsed,
                    in: NSRect(x: 8, y: y + 4, width: 10, height: 10)
                )
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
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= 20,
              let lineNumber = lineNumber(atY: point.y),
              let foldRegion = projectedFoldRegions.first(where: { $0.visibleHeaderLineNumber == lineNumber }) else {
            super.mouseDown(with: event)
            return
        }

        onToggleFold?(foldRegion.id)
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

    private func lineNumber(atY yPosition: CGFloat) -> Int? {
        guard let textView,
              let layoutManager = unsafe textView.layoutManager,
              let scrollView = textView.enclosingScrollView else {
            return nil
        }

        let clipOrigin = scrollView.contentView.bounds.origin
        let targetY = yPosition + clipOrigin.y - textView.textContainerInset.height
        let text = textView.string as NSString

        if !layoutManager.extraLineFragmentRect.isEmpty,
           targetY >= layoutManager.extraLineFragmentRect.minY,
           targetY <= layoutManager.extraLineFragmentRect.maxY {
            return lineNumber(atCharacterIndex: text.length, text: text)
        }

        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphRange = NSRange()
            let lineRect = unsafe layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            if targetY >= lineRect.minY, targetY <= lineRect.maxY {
                return lineNumber(atGlyphIndex: glyphIndex, layoutManager: layoutManager, text: text)
            }
            glyphIndex = NSMaxRange(lineGlyphRange)
        }

        return nil
    }

    private func drawFoldIndicator(isCollapsed: Bool, in rect: NSRect) {
        let path = NSBezierPath()
        if isCollapsed {
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 1))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 1))
        } else {
            path.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + 2))
            path.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 2))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
        }
        path.close()
        theme.gutterTextColor.setFill()
        path.fill()
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
