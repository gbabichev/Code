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
    static func makeHighlighter(for language: EditorLanguage, skin: SkinDefinition, editorFont: NSFont, semiboldFont: NSFont) -> SyntaxHighlighting {
        let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: semiboldFont)

        switch language {
        case .shell:
            return ShellSyntaxHighlighter(theme: theme)
        case .plainText:
            return PlainTextHighlighter(theme: theme)
        }
    }
}

struct SkinTheme {
    static let fallback = SkinDefinition(
        schemaVersion: 1,
        id: "classic",
        name: "Classic",
        editor: .init(
            background: .init(light: "#FFFFFF", dark: "#1E1E1E"),
            foreground: .init(light: "#111111", dark: "#E6E6E6")
        ),
        tokens: .init(
            keyword: .init(light: "#FF2D92", dark: "#FF7ABD"),
            builtin: .init(light: "#0A84FF", dark: "#6DB7FF"),
            variable: .init(light: "#FF9F0A", dark: "#FFC457"),
            string: .init(light: "#2DA44E", dark: "#7BDC8B"),
            comment: .init(light: "#6E6E73", dark: "#8E8E93"),
            command: .init(light: "#AF52DE", dark: "#D69CFF")
        ),
        languageOverrides: [:]
    ).makeTheme(
        for: .plainText,
        editorFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        semiboldFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    )

    let font: NSFont
    let semiboldFont: NSFont
    let editorBackgroundColor: NSColor
    let baseColor: NSColor
    let keywordColor: NSColor
    let builtinColor: NSColor
    let variableColor: NSColor
    let stringColor: NSColor
    let commentColor: NSColor
    let commandColor: NSColor
    let currentLineColor: NSColor
    let selectionColor: NSColor
    let gutterBackgroundColor: NSColor
    let gutterBorderColor: NSColor
    let gutterTextColor: NSColor
    let gutterCurrentLineColor: NSColor
    let gutterCurrentLineNumberColor: NSColor

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: baseColor
        ]
    }

    var keywordAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: keywordColor
        ]
    }

    var builtinAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: builtinColor
        ]
    }

    var variableAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: variableColor
        ]
    }

    var stringAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: stringColor
        ]
    }

    var commentAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: commentColor
        ]
    }

    var commandAttributes: [NSAttributedString.Key: Any] {
        [
            .font: semiboldFont,
            .foregroundColor: commandColor
        ]
    }
}
