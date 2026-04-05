//
//  CodeEditorView.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let isWordWrapEnabled: Bool
    let skin: SkinDefinition
    let language: EditorLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(textBinding: $text, language: language, skin: skin)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let theme = skin.makeTheme(for: language)
        let container = EditorContainerView()
        let textView = NSTextView()

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = SkinTheme.font
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
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.applyTheme(theme)
        context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)
        context.coordinator.applyHighlighting()

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        context.coordinator.language = language
        context.coordinator.skin = skin
        context.coordinator.textBinding = $text

        let theme = skin.makeTheme(for: language)
        context.coordinator.applyTheme(theme)
        context.coordinator.configureLayout(isWordWrapEnabled: isWordWrapEnabled)

        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }

        context.coordinator.applyHighlighting()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var language: EditorLanguage
        var skin: SkinDefinition
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        let gutterView = GutterView(frame: .zero)
        private var isApplyingHighlighting = false

        init(textBinding: Binding<String>, language: EditorLanguage, skin: SkinDefinition) {
            self.textBinding = textBinding
            self.language = language
            self.skin = skin
        }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            gutterView.textView = textView

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
            textBinding.wrappedValue = textView.string
            applyHighlighting()
            gutterView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isApplyingHighlighting { return }
            gutterView.needsDisplay = true
        }

        func configureLayout(isWordWrapEnabled: Bool) {
            guard let textView, let textContainer = unsafe textView.textContainer else { return }

            if isWordWrapEnabled {
                textView.isHorizontallyResizable = false
                textContainer.widthTracksTextView = true
                textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                scrollView?.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textContainer.widthTracksTextView = false
                textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scrollView?.hasHorizontalScroller = true
            }
        }

        func applyTheme(_ theme: SkinTheme) {
            guard let textView else { return }

            textView.font = SkinTheme.font
            textView.textColor = theme.baseColor
            textView.backgroundColor = theme.editorBackgroundColor
            textView.insertionPointColor = theme.baseColor
            textView.selectedTextAttributes = [
                .backgroundColor: theme.selectionColor,
                .foregroundColor: theme.baseColor
            ]
            scrollView?.backgroundColor = theme.editorBackgroundColor
            gutterView.theme = theme
            gutterView.needsDisplay = true
        }

        func applyHighlighting() {
            guard let textView, let textStorage = unsafe textView.textStorage else { return }
            if isApplyingHighlighting { return }

            isApplyingHighlighting = true
            let selectedRanges = textView.selectedRanges
            textStorage.beginEditing()
            SyntaxHighlighterFactory.makeHighlighter(for: language, skin: skin)
                .apply(to: textStorage, text: textView.string)
            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
            textView.needsDisplay = true
            gutterView.needsDisplay = true
            isApplyingHighlighting = false
        }

        @objc
        private func handleBoundsDidChange() {
            gutterView.needsDisplay = true
        }
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
            let height = max(lineRect.height, layoutManager.defaultLineHeight(for: textView.font ?? SkinTheme.font))

            if lineNumber == selectedLine {
                theme.gutterCurrentLineColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: SkinTheme.font,
                .foregroundColor: lineNumber == selectedLine ? theme.gutterCurrentLineNumberColor : theme.gutterTextColor,
                .paragraphStyle: paragraph
            ]
            let label = NSAttributedString(string: "\(lineNumber)", attributes: attributes)
            label.draw(in: NSRect(x: 0, y: y + 1, width: bounds.width - 8, height: height))

            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNumber += lineCount(in: lineRange, text: text)
        }
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
}
