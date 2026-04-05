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
    let skin: SyntaxSkin

    func apply(to textStorage: NSTextStorage, text: String) {
        let range = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(skin.baseAttributes, range: range)
    }
}

struct ShellSyntaxHighlighter: SyntaxHighlighting {
    let skin: SyntaxSkin

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
        textStorage.setAttributes(skin.baseAttributes, range: fullRange)

        for match in commentRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(skin.commentAttributes, range: match.range)
        }

        for match in stringRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(skin.stringAttributes, range: match.range)
        }

        for match in variableRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(skin.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(skin.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange) {
            textStorage.addAttributes(skin.builtinAttributes, range: match.range)
        }

        for match in commandRegex.matches(in: text, range: fullRange) where match.numberOfRanges > 1 {
            textStorage.addAttributes(skin.commandAttributes, range: match.range(at: 1))
        }
    }
}

enum SyntaxHighlighterFactory {
    static func makeHighlighter(for language: EditorLanguage, skin: SyntaxHighlightingSkin) -> SyntaxHighlighting {
        let syntaxSkin = SyntaxSkin.make(for: skin)

        switch language {
        case .shell:
            return ShellSyntaxHighlighter(skin: syntaxSkin)
        case .plainText:
            return PlainTextHighlighter(skin: syntaxSkin)
        }
    }
}

struct SyntaxSkin {
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

    static func make(for skin: SyntaxHighlightingSkin) -> SyntaxSkin {
        switch skin {
        case .classic:
            SyntaxSkin(
                editorBackgroundColor: .textBackgroundColor,
                baseColor: .textColor,
                keywordColor: .systemPink,
                builtinColor: .systemBlue,
                variableColor: .systemOrange,
                stringColor: .systemGreen,
                commentColor: .secondaryLabelColor,
                commandColor: .systemPurple
            )
        case .forest:
            SyntaxSkin(
                editorBackgroundColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.10, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.90, alpha: 1)
                },
                baseColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.82, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.16, alpha: 1)
                },
                keywordColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.52, green: 0.86, blue: 0.77, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.00, green: 0.43, blue: 0.38, alpha: 1)
                },
                builtinColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.46, green: 0.72, blue: 0.95, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.58, alpha: 1)
                },
                variableColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.41, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.64, green: 0.34, blue: 0.04, alpha: 1)
                },
                stringColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.67, green: 0.88, blue: 0.52, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.17, green: 0.46, blue: 0.10, alpha: 1)
                },
                commentColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.48, green: 0.57, blue: 0.48, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.40, green: 0.48, blue: 0.38, alpha: 1)
                },
                commandColor: NSColor(name: nil) { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor(calibratedRed: 0.83, green: 0.60, blue: 0.96, alpha: 1)
                    }
                    return NSColor(calibratedRed: 0.42, green: 0.18, blue: 0.55, alpha: 1)
                }
            )
        }
    }
}
