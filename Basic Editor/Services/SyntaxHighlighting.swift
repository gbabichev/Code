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
    let theme: SkinTheme

    func apply(to textStorage: NSTextStorage, text: String) {
        let range = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(theme.baseAttributes, range: range)
    }
}

struct ShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

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
        textStorage.setAttributes(theme.baseAttributes, range: fullRange)

        for match in commentRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(theme.commentAttributes, range: match.range)
        }

        for match in stringRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(theme.stringAttributes, range: match.range)
        }

        for match in variableRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in commandRegex.matches(in: text, range: fullRange) where match.numberOfRanges > 1 {
            textStorage.addAttributes(theme.commandAttributes, range: match.range(at: 1))
        }
    }
}

enum SyntaxHighlighterFactory {
    static func makeHighlighter(for language: EditorLanguage, skin: SkinDefinition) -> SyntaxHighlighting {
        let theme = skin.makeTheme(for: language)

        switch language {
        case .shell:
            return ShellSyntaxHighlighter(theme: theme)
        case .plainText:
            return PlainTextHighlighter(theme: theme)
        }
    }
}

struct SkinTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let semiboldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    let editorBackgroundColor: NSColor
    let baseColor: NSColor
    let keywordColor: NSColor
    let builtinColor: NSColor
    let variableColor: NSColor
    let stringColor: NSColor
    let commentColor: NSColor
    let commandColor: NSColor

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: baseColor
        ]
    }

    var keywordAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: keywordColor
        ]
    }

    var builtinAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: builtinColor
        ]
    }

    var variableAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: variableColor
        ]
    }

    var stringAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: stringColor
        ]
    }

    var commentAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: commentColor
        ]
    }

    var commandAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.semiboldFont,
            .foregroundColor: commandColor
        ]
    }
}
