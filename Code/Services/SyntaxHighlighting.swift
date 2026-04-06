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

private func isLocation(_ location: Int, containedIn ranges: [NSRange]) -> Bool {
    ranges.contains { NSLocationInRange(location, $0) }
}

private func intersects(_ range: NSRange, with ranges: [NSRange]) -> Bool {
    ranges.contains { NSIntersectionRange(range, $0).length > 0 }
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
    private let commandRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*([A-Za-z_./-][A-Za-z0-9_./-]*)"#
    )

    func apply(to textStorage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(theme.baseAttributes, range: fullRange)

        let (stringRanges, commentRanges) = shellStringAndCommentRanges(in: text as NSString)

        for range in stringRanges {
            textStorage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in variableRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in commandRegex.matches(in: text, range: fullRange)
        where match.numberOfRanges > 1 && !intersects(match.range(at: 1), with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.commandAttributes, range: match.range(at: 1))
        }

        for range in commentRanges {
            textStorage.addAttributes(theme.commentAttributes, range: range)
        }
    }

    private func shellStringAndCommentRanges(in text: NSString) -> ([NSRange], [NSRange]) {
        var stringRanges: [NSRange] = []
        var commentRanges: [NSRange] = []
        var index = 0
        var activeQuote: unichar?
        var quoteStart: Int?
        var isEscaped = false

        while index < text.length {
            let character = text.character(at: index)

            if let activeQuoteValue = activeQuote {
                if activeQuoteValue == 34 {
                    if character == 92, !isEscaped {
                        isEscaped = true
                        index += 1
                        continue
                    }

                    if character == 34, !isEscaped, let quoteStartValue = quoteStart {
                        stringRanges.append(NSRange(location: quoteStartValue, length: index - quoteStartValue + 1))
                        activeQuote = nil
                        quoteStart = nil
                        isEscaped = false
                        index += 1
                        continue
                    }

                    isEscaped = false
                } else if character == 39, let quoteStartValue = quoteStart {
                    stringRanges.append(NSRange(location: quoteStartValue, length: index - quoteStartValue + 1))
                    activeQuote = nil
                    quoteStart = nil
                    isEscaped = false
                    index += 1
                    continue
                }

                index += 1
                continue
            }

            if character == 35, isShellCommentStart(in: text, at: index) {
                let lineEnd = lineEndIndex(in: text, startingAt: index)
                commentRanges.append(NSRange(location: index, length: lineEnd - index))
                index = lineEnd
                continue
            }

            if character == 34 || character == 39 {
                activeQuote = character
                quoteStart = index
                isEscaped = false
                index += 1
                continue
            }

            index += 1
        }

        if let quoteStart {
            stringRanges.append(NSRange(location: quoteStart, length: text.length - quoteStart))
        }

        return (stringRanges, commentRanges)
    }
    private func isShellCommentStart(in text: NSString, at index: Int) -> Bool {
        guard index == 0 else {
            let previousCharacter = text.character(at: index - 1)
            return CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(previousCharacter)!)
                || previousCharacter == 59
                || previousCharacter == 124
                || previousCharacter == 38
        }

        return true
    }

    private func lineEndIndex(in text: NSString, startingAt index: Int) -> Int {
        var probe = index
        while probe < text.length, text.character(at: probe) != 10 {
            probe += 1
        }
        return probe
    }
}

struct DotEnvSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    func apply(to textStorage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(theme.baseAttributes, range: fullRange)

        let lines = text.components(separatedBy: "\n")
        var location = 0

        for line in lines {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: location, length: lineLength)
            highlightLine(line, in: textStorage, lineRange: lineRange)
            location += lineLength + 1
        }
    }

    private func highlightLine(_ line: String, in textStorage: NSTextStorage, lineRange: NSRange) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("#") {
            textStorage.addAttributes(theme.commentAttributes, range: lineRange)
            return
        }

        let nsLine = line as NSString
        guard let equalsIndex = line.firstIndex(of: "=") else { return }

        let keyLength = line.distance(from: line.startIndex, to: equalsIndex)
        let keyRange = NSRange(location: lineRange.location, length: keyLength)
        if keyRange.length > 0 {
            textStorage.addAttributes(theme.variableAttributes, range: keyRange)
        }

        let valueStart = keyLength + 1
        guard valueStart < nsLine.length else { return }

        let valueString = nsLine.substring(from: valueStart)
        let commentOffset = inlineCommentOffset(in: valueString)

        if let commentOffset {
            let commentRange = NSRange(location: lineRange.location + valueStart + commentOffset, length: valueString.count - commentOffset)
            textStorage.addAttributes(theme.commentAttributes, range: commentRange)

            if commentOffset > 0 {
                let valueRange = NSRange(location: lineRange.location + valueStart, length: commentOffset)
                textStorage.addAttributes(theme.stringAttributes, range: valueRange)
            }
        } else {
            let valueRange = NSRange(location: lineRange.location + valueStart, length: nsLine.length - valueStart)
            textStorage.addAttributes(theme.stringAttributes, range: valueRange)
        }
    }

    private func inlineCommentOffset(in value: String) -> Int? {
        var inDoubleQuotes = false
        var inSingleQuotes = false
        var previousCharacter: Character?

        for (offset, character) in value.enumerated() {
            if character == "\"" && previousCharacter != "\\" && !inSingleQuotes {
                inDoubleQuotes.toggle()
            } else if character == "'" && previousCharacter != "\\" && !inDoubleQuotes {
                inSingleQuotes.toggle()
            } else if character == "#", !inDoubleQuotes, !inSingleQuotes {
                return offset
            }

            previousCharacter = character
        }

        return nil
    }
}

struct PythonSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private let commentRegex = try! NSRegularExpression(
        pattern: #"(?m)#.*$"#
    )
    private let stringRegex = try! NSRegularExpression(
        pattern: #"(?s)(\"\"\".*?\"\"\"|'''.*?'''|f\"([^\"\\]|\\.)*\"|f'([^'\\]|\\.)*'|r\"([^\"\\]|\\.)*\"|r'([^'\\]|\\.)*'|b\"([^\"\\]|\\.)*\"|b'([^'\\]|\\.)*'|u\"([^\"\\]|\\.)*\"|u'([^'\\]|\\.)*'|\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*')"#
    )
    private let keywordRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(False|None|True|and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#
    )
    private let builtInRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(abs|all|any|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|dict|dir|enumerate|filter|float|format|frozenset|getattr|hasattr|hash|hex|input|int|isinstance|issubclass|iter|len|list|map|max|min|next|object|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip)\b"#
    )
    private let variableRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(self|cls)\b"#
    )
    private let decoratorRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*@[A-Za-z_][A-Za-z0-9_\.]*"#
    )

    func apply(to textStorage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(theme.baseAttributes, range: fullRange)

        let stringRanges = stringRegex.matches(in: text, range: fullRange).map(\.range)
        let commentRanges = commentRegex.matches(in: text, range: fullRange)
            .map(\.range)
            .filter { !isLocation($0.location, containedIn: stringRanges) }

        for range in stringRanges {
            textStorage.addAttributes(theme.stringAttributes, range: range)
        }

        for range in commentRanges {
            textStorage.addAttributes(theme.commentAttributes, range: range)
        }

        for match in decoratorRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for match in variableRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.builtinAttributes, range: match.range)
        }
    }
}

struct PowerShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private let blockCommentRegex = try! NSRegularExpression(
        pattern: #"(?s)<#.*?#>"#
    )
    private let lineCommentRegex = try! NSRegularExpression(
        pattern: #"(?m)#.*$"#
    )
    private let stringRegex = try! NSRegularExpression(
        pattern: #"(?s)@\".*?\"@|@'.*?'@|\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'"#
    )
    private let variableRegex = try! NSRegularExpression(
        pattern: #"\$[A-Za-z_][A-Za-z0-9_:]*|\$\{[^}]+\}"#
    )
    private let keywordRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b(begin|break|catch|class|continue|data|default|do|dynamicparam|else|elseif|end|enum|exit|filter|finally|for|foreach|from|function|if|in|param|process|return|switch|throw|trap|try|until|using|while|workflow)\b"#
    )
    private let builtInRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b(Write-Host|Write-Output|Write-Error|Write-Warning|Write-Verbose|Write-Debug|Write-Information|Read-Host|ForEach-Object|Where-Object|Select-Object|Sort-Object|Group-Object|Measure-Object|Get-Item|Set-Item|New-Item|Remove-Item|Copy-Item|Move-Item|Test-Path|Join-Path|Split-Path|Resolve-Path|Import-Module|Export-ModuleMember|Invoke-Expression|Start-Process|Stop-Process|Get-Process|Get-Service|Start-Service|Stop-Service|Set-Location|Get-Location|Clear-Host|Out-File|Set-Content|Add-Content|Get-Content)\b"#
    )
    private let commandRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b[A-Z][A-Za-z0-9]*-[A-Z][A-Za-z0-9]*(?:-[A-Z][A-Za-z0-9]*)*\b"#
    )

    func apply(to textStorage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.setAttributes(theme.baseAttributes, range: fullRange)

        let blockCommentRanges = blockCommentRegex.matches(in: text, range: fullRange).map(\.range)
        let stringRanges = stringRegex.matches(in: text, range: fullRange)
            .map(\.range)
            .filter { !isLocation($0.location, containedIn: blockCommentRanges) }
        let commentRanges = blockCommentRanges + lineCommentRegex.matches(in: text, range: fullRange)
            .map(\.range)
            .filter { !isLocation($0.location, containedIn: stringRanges + blockCommentRanges) }

        for range in stringRanges {
            textStorage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in variableRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in keywordRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in builtInRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in commandRegex.matches(in: text, range: fullRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            textStorage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for range in commentRanges {
            textStorage.addAttributes(theme.commentAttributes, range: range)
        }
    }
}

enum SyntaxHighlighterFactory {
    static func makeHighlighter(for language: EditorLanguage, skin: SkinDefinition, editorFont: NSFont, semiboldFont: NSFont) -> SyntaxHighlighting {
        let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: semiboldFont)

        switch language {
        case .shell:
            return ShellSyntaxHighlighter(theme: theme)
        case .dotenv:
            return DotEnvSyntaxHighlighter(theme: theme)
        case .python:
            return PythonSyntaxHighlighter(theme: theme)
        case .powerShell:
            return PowerShellSyntaxHighlighter(theme: theme)
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
