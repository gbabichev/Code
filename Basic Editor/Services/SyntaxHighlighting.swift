//
//  SyntaxHighlighting.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import AppKit
import Foundation

protocol SyntaxHighlighting {
    func apply(to textStorage: NSTextStorage, text: String)
}

struct PlainTextHighlighter: SyntaxHighlighting {
    func apply(to textStorage: NSTextStorage, text: String) {
        let range = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(SyntaxTheme.baseAttributes, range: range)
    }
}

struct ShellSyntaxHighlighter: SyntaxHighlighting {
    private let keywordRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|in|select|until|time)\b"#
    )
    private let builtInRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(export|local|readonly|return|shift|unset|eval|exec|source|alias|trap|cd|exit|echo|printf)\b"#
    )
    private let variableRegex = try! NSRegularExpression(
        pattern: #"\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}"#
    )
    private let stringRegex = try! NSRegularExpression(
        pattern: #""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#
    )
    private let commentRegex = try! NSRegularExpression(
        pattern: #"(?m)#.*$"#
    )
    private let commandRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*([A-Za-z_./-][A-Za-z0-9_./-]*)"#
    )

    func apply(to textStorage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(SyntaxTheme.baseAttributes, range: fullRange)

        for match in commentRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(SyntaxTheme.commentAttributes, range: match.range)
        }

        for match in stringRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(SyntaxTheme.stringAttributes, range: match.range)
        }

        for match in variableRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(SyntaxTheme.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(SyntaxTheme.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(SyntaxTheme.builtinAttributes, range: match.range)
        }

        for match in commandRegex.matches(in: text, range: fullRange) where match.numberOfRanges > 1 {
            textStorage.addAttributes(SyntaxTheme.commandAttributes, range: match.range(at: 1))
        }
    }
}

enum SyntaxHighlighterFactory {
    static func makeHighlighter(for language: EditorLanguage) -> SyntaxHighlighting {
        switch language {
        case .shell:
            ShellSyntaxHighlighter()
        case .plainText:
            PlainTextHighlighter()
        }
    }
}

enum SyntaxTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.textColor
    ]

    static let keywordAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.systemPink
    ]

    static let builtinAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.systemBlue
    ]

    static let variableAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.systemOrange
    ]

    static let stringAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.systemGreen
    ]

    static let commentAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.secondaryLabelColor
    ]

    static let commandAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.systemPurple
    ]
}
