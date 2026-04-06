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

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let isWordWrapEnabled: Bool
    let skin: SkinDefinition
    let language: EditorLanguage
    let indentWidth: Int
    let editorFont: NSFont
    let editorSemiboldFont: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(
            textBinding: $text,
            language: language,
            skin: skin,
            indentWidth: indentWidth,
            editorFont: editorFont,
            editorSemiboldFont: editorSemiboldFont
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
        context.coordinator.indentWidth = indentWidth
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
        var indentWidth: Int
        var editorFont: NSFont
        var editorSemiboldFont: NSFont
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        let gutterView = GutterView(frame: .zero)
        private var isApplyingHighlighting = false
        private var sourceText: String
        private(set) var requiresHighlightRefresh = true

        init(textBinding: Binding<String>, language: EditorLanguage, skin: SkinDefinition, indentWidth: Int, editorFont: NSFont, editorSemiboldFont: NSFont) {
            self.textBinding = textBinding
            self.language = language
            self.skin = skin
            self.indentWidth = indentWidth
            self.editorFont = editorFont
            self.editorSemiboldFont = editorSemiboldFont
            self.sourceText = textBinding.wrappedValue
        }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            gutterView.textView = textView
            ActiveEditorTextViewRegistry.shared.register(textView)

            if let lineClickableTextView = textView as? LineClickableTextView {
                lineClickableTextView.lineCommentPrefix = language.lineCommentPrefix
                lineClickableTextView.indentWidth = indentWidth
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
            let editedRange = unsafe textView.textStorage?.editedRange
            sourceText = textView.string
            textBinding.wrappedValue = sourceText
            applyHighlighting(in: editedRange)
            textView.needsDisplay = true
            gutterView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
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
                lineClickableTextView.indentWidth = indentWidth
            }
            scrollView?.backgroundColor = theme.editorBackgroundColor
            gutterView.theme = theme
            gutterView.needsDisplay = true
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
    var lineCommentPrefix: String?
    var indentWidth = 4

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        ActiveEditorTextViewRegistry.shared.register(self)

        if event.type == .leftMouseDown,
           event.clickCount == 1,
           beginTrailingLineSelectionIfNeeded(event: event) {
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
        }
        return didBecomeFirstResponder
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
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

    @discardableResult
    func moveInsertionPointToClosestLine(for pointInSelf: NSPoint) -> Bool {
        guard let selectionIndex = selectionIndexForClosestLine(for: pointInSelf) else {
            return false
        }

        unsafe window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: selectionIndex, length: 0))
        return true
    }

    private func selectionIndexForClosestLine(for pointInSelf: NSPoint) -> Int? {
        guard let layoutManager = unsafe layoutManager,
              let textContainer = unsafe textContainer else {
            return nil
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
            return nil
        }
        return selectionIndex
    }

    @discardableResult
    func beginTrailingLineSelectionIfNeeded(event: NSEvent) -> Bool {
        guard unsafe layoutManager != nil,
              unsafe textContainer != nil else {
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let anchorIndex = selectionIndexForClosestLine(for: point) else {
            return false
        }

        unsafe window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: anchorIndex, length: 0))
        trackSelectionDrag(from: anchorIndex, initialEvent: event)
        return true
    }

    private func trackSelectionDrag(from anchorIndex: Int, initialEvent: NSEvent) {
        guard let window = unsafe window else { return }

        var lastSelectionIndex = anchorIndex

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(nextEvent.locationInWindow, from: nil)
            if let selectionIndex = selectionIndexForClosestLine(for: point) {
                lastSelectionIndex = selectionIndex
                let location = min(anchorIndex, selectionIndex)
                let length = abs(selectionIndex - anchorIndex)
                setSelectedRange(NSRange(location: location, length: length))
            }

            if nextEvent.type == .leftMouseUp {
                if lastSelectionIndex == anchorIndex {
                    setSelectedRange(NSRange(location: anchorIndex, length: 0))
                }
                break
            }
        }
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
        let translatedEvent = NSEvent.mouseEvent(
            with: event.type,
            location: textView.convert(textPoint, to: nil),
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event

        if textView.beginTrailingLineSelectionIfNeeded(event: translatedEvent) {
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
