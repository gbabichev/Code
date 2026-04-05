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
    let language: EditorLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(textBinding: $text, language: language)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = SyntaxTheme.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.language = language
        context.coordinator.textBinding = $text

        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var language: EditorLanguage
        weak var textView: NSTextView?

        init(textBinding: Binding<String>, language: EditorLanguage) {
            self.textBinding = textBinding
            self.language = language
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textBinding.wrappedValue = textView.string
            applyHighlighting()
        }

        func applyHighlighting() {
            guard let textView, let textStorage = textView.textStorage else { return }

            let selectedRanges = textView.selectedRanges
            textStorage.beginEditing()
            SyntaxHighlighterFactory.makeHighlighter(for: language)
                .apply(to: textStorage, text: textView.string)
            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
        }
    }
}
