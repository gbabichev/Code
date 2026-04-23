//
//  SyntaxHighlighting.swift
//  Code
//

import AppKit
import Foundation

protocol SyntaxHighlighting {
    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?)
}

/// Maximum document size for full highlighting (10KB ~ 200 lines)
/// Beyond this, only the visible/edited range is highlighted
private let maxFullHighlightSize = 10_000

private func intersects(_ range: NSRange, with ranges: [NSRange]) -> Bool {
    ranges.contains { NSIntersectionRange(range, $0).length > 0 }
}

struct PlainTextHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        // For large files, limit highlighting to max 5000 chars if no range specified
        let maxRange = storage.length > maxFullHighlightSize ? 5000 : fullRange.length
        let effectiveRange: NSRange
        if let range {
            effectiveRange = highlightedRange(for: range, in: text as NSString, fallback: fullRange)
        } else if storage.length > maxFullHighlightSize {
            effectiveRange = NSRange(location: 0, length: min(maxRange, fullRange.length))
        } else {
            effectiveRange = fullRange
        }
        storage.setAttributes(theme.baseAttributes, range: effectiveRange)
    }
}

struct MarkdownSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"(?m)^(#{1,6}\s+.*)$"#
    )
    private static let headingMarkerRegex = try! NSRegularExpression(
        pattern: #"(?m)^(#{1,6})"#
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*>.*$"#
    )
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"(?m)^(\s*(?:[-*+]|\d+\.)\s+)"#
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[[^\]\n]+\]\([^) \n]+(?: [^)]+)?\)"#
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: #"`[^`\n]+`"#
    )
    private static let htmlCommentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#
    )

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText, expansion: 32_768)

        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        let fencedCodeRanges = fencedCodeBlockRanges(in: nsText, within: scanRange)
        let htmlCommentRanges = Self.htmlCommentRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { NSIntersectionRange($0, highlightRange).length > 0 }

        for fencedRange in fencedCodeRanges {
            let visibleRange = NSIntersectionRange(fencedRange, highlightRange)
            guard visibleRange.length > 0 else { continue }
            storage.addAttributes(theme.stringAttributes, range: visibleRange)
        }

        for commentRange in htmlCommentRanges
        where !intersects(commentRange, with: fencedCodeRanges) {
            storage.addAttributes(theme.commentAttributes, range: commentRange)
        }

        for match in Self.headingRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: fencedCodeRanges) {
            storage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for match in Self.headingMarkerRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: fencedCodeRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.blockquoteRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: fencedCodeRanges) {
            storage.addAttributes(theme.commentAttributes, range: match.range)
        }

        for match in Self.listMarkerRegex.matches(in: text, range: highlightRange)
        where match.numberOfRanges > 1 && !intersects(match.range(at: 1), with: fencedCodeRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range(at: 1))
        }

        for match in Self.linkRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: fencedCodeRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in Self.inlineCodeRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: fencedCodeRanges) {
            storage.addAttributes(theme.stringAttributes, range: match.range)
        }
    }

    private func fencedCodeBlockRanges(in text: NSString, within range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = lineStart(in: text, at: range.location)
        var fenceStart: Int?
        var fenceDelimiter: String?

        while index < NSMaxRange(range) {
            let lineRange = NSRange(location: index, length: max(0, lineEnd(in: text, at: index) - index))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if fenceStart == nil {
                if trimmed.hasPrefix("```") {
                    fenceStart = index
                    fenceDelimiter = "```"
                } else if trimmed.hasPrefix("~~~") {
                    fenceStart = index
                    fenceDelimiter = "~~~"
                }
            } else if let activeFenceStart = fenceStart,
                      let activeFenceDelimiter = fenceDelimiter,
                      trimmed.hasPrefix(activeFenceDelimiter) {
                ranges.append(NSRange(location: activeFenceStart, length: NSMaxRange(lineRange) - activeFenceStart))
                fenceStart = nil
                fenceDelimiter = nil
            }

            index = NSMaxRange(lineRange)
        }

        if let fenceStart {
            ranges.append(NSRange(location: fenceStart, length: NSMaxRange(range) - fenceStart))
        }

        return ranges
    }
}

struct ShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|in|select|until|time)\b"#
    )
    private static let builtInRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(export|local|readonly|return|shift|unset|eval|exec|source|alias|trap|cd|exit|echo|printf)\b"#
    )
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}"#
    )
    private static let commandRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*([A-Za-z_./-][A-Za-z0-9_./-]*)"#
    )

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = highlightedRange(for: range, in: text as NSString, fallback: fullRange)
        
        // Only limit range when a specific edit range was provided (not during force/full highlighting)
        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }
        
        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        let (stringRanges, commentRanges) = shellStringAndCommentRanges(in: text as NSString, within: highlightRange)

        for range in stringRanges {
            storage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in Self.variableRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in Self.keywordRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.builtInRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in Self.commandRegex.matches(in: text, range: highlightRange)
        where match.numberOfRanges > 1 && !intersects(match.range(at: 1), with: commentRanges + stringRanges) {
            storage.addAttributes(theme.commandAttributes, range: match.range(at: 1))
        }

        for range in commentRanges {
            storage.addAttributes(theme.commentAttributes, range: range)
        }
    }

    private func shellStringAndCommentRanges(in text: NSString, within range: NSRange) -> ([NSRange], [NSRange]) {
        var stringRanges: [NSRange] = []
        var commentRanges: [NSRange] = []
        var index = range.location
        var activeQuote: unichar?
        var quoteStart: Int?
        var isEscaped = false

        while index < NSMaxRange(range) {
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
            stringRanges.append(NSRange(location: quoteStart, length: NSMaxRange(range) - quoteStart))
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

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = highlightedRange(for: range, in: text as NSString, fallback: fullRange)

        // Only limit range when a specific edit range was provided (not during force/full highlighting)
        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        let nsText = text as NSString
        unsafe nsText.enumerateSubstrings(in: highlightRange, options: [.byLines, .substringNotRequired]) { _, substringRange, enclosingRange, _ in
            let line = nsText.substring(with: substringRange)
            self.highlightLine(line, in: storage, lineRange: substringRange)
            if enclosingRange.length > substringRange.length {
                let newlineRange = NSRange(location: NSMaxRange(substringRange), length: enclosingRange.length - substringRange.length)
                storage.setAttributes(self.theme.baseAttributes, range: newlineRange)
            }
        }
    }

    private func highlightLine(_ line: String, in storage: NSMutableAttributedString, lineRange: NSRange) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("#") {
            storage.addAttributes(theme.commentAttributes, range: lineRange)
            return
        }

        let nsLine = line as NSString
        guard let equalsIndex = line.firstIndex(of: "=") else { return }

        let keyLength = line.distance(from: line.startIndex, to: equalsIndex)
        let keyRange = NSRange(location: lineRange.location, length: keyLength)
        if keyRange.length > 0 {
            storage.addAttributes(theme.variableAttributes, range: keyRange)
        }

        let valueStart = keyLength + 1
        guard valueStart < nsLine.length else { return }

        let valueString = nsLine.substring(from: valueStart)
        let commentOffset = inlineCommentOffset(in: valueString)

        if let commentOffset {
            let commentRange = NSRange(location: lineRange.location + valueStart + commentOffset, length: nsLine.length - valueStart - commentOffset)
            storage.addAttributes(theme.commentAttributes, range: commentRange)

            if commentOffset > 0 {
                let valueRange = NSRange(location: lineRange.location + valueStart, length: commentOffset)
                storage.addAttributes(theme.stringAttributes, range: valueRange)
            }
        } else {
            let valueRange = NSRange(location: lineRange.location + valueStart, length: nsLine.length - valueStart)
            storage.addAttributes(theme.stringAttributes, range: valueRange)
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

    private static let commentRegex = try! NSRegularExpression(
        pattern: #"(?m)#.*$"#
    )
    private static let stringRegex = try! NSRegularExpression(
        pattern: #"\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|(?<![A-Za-z0-9])f\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])f'([^\n'\\]|\\.)*'|(?<![A-Za-z0-9])r\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])r'([^\n'\\]|\\.)*'|(?<![A-Za-z0-9])b\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])b'([^\n'\\]|\\.)*'|(?<![A-Za-z0-9])u\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])u'([^\n'\\]|\\.)*'|(?<![A-Za-z0-9])\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])'([^\n'\\]|\\.)*'"#
    )
    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(False|None|True|and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#
    )
    private static let builtInRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(abs|all|any|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|dict|dir|enumerate|filter|float|format|frozenset|getattr|hasattr|hash|hex|input|int|isinstance|issubclass|iter|len|list|map|max|min|next|object|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip)\b"#
    )
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(self|cls)\b"#
    )
    private static let decoratorRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*@[A-Za-z_][A-Za-z0-9_\.]*"#
    )

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        // Only limit range when a specific edit range was provided (not during force/full highlighting)
        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        // Detect comments FIRST so quotes inside comments don't get matched as strings
        let commentRanges = Self.commentRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { NSIntersectionRange($0, highlightRange).length > 0 }

        let stringRanges = Self.stringRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { range in
                NSIntersectionRange(range, highlightRange).length > 0
                    && !intersects(range, with: commentRanges)
            }

        for range in stringRanges {
            storage.addAttributes(theme.stringAttributes, range: range)
        }

        for range in commentRanges {
            storage.addAttributes(theme.commentAttributes, range: range)
        }

        for match in Self.decoratorRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for match in Self.variableRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in Self.keywordRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.builtInRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }
    }
}

struct PowerShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let blockCommentRegex = try! NSRegularExpression(
        pattern: #"(?s)<#.*?#>"#
    )
    private static let lineCommentRegex = try! NSRegularExpression(
        pattern: #"(?m)#.*$"#
    )
    private static let stringRegex = try! NSRegularExpression(
        pattern: #"@\"[\s\S]*?\"@|@'[\s\S]*?'@|(?<![A-Za-z0-9])\"([^\n\"\\]|\\.)*\"|(?<![A-Za-z0-9])'([^\n'\\]|\\.)*'"#
    )
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"\$[A-Za-z_][A-Za-z0-9_:]*|\$\{[^}]+\}"#
    )
    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b(begin|break|catch|class|continue|data|default|do|dynamicparam|else|elseif|end|enum|exit|filter|finally|for|foreach|from|function|if|in|param|process|return|switch|throw|trap|try|until|using|while|workflow)\b"#
    )
    private static let builtInRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b(Write-Host|Write-Output|Write-Error|Write-Warning|Write-Verbose|Write-Debug|Write-Information|Read-Host|ForEach-Object|Where-Object|Select-Object|Sort-Object|Group-Object|Measure-Object|Get-Item|Set-Item|New-Item|Remove-Item|Copy-Item|Move-Item|Test-Path|Join-Path|Split-Path|Resolve-Path|Import-Module|Export-ModuleMember|Invoke-Expression|Start-Process|Stop-Process|Get-Process|Get-Service|Start-Service|Stop-Service|Set-Location|Get-Location|Clear-Host|Out-File|Set-Content|Add-Content|Get-Content)\b"#
    )
    private static let commandRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b[A-Za-z][A-Za-z0-9]*-[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*\b"#
    )

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        // Only limit range when a specific edit range was provided (not during force/full highlighting)
        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        // Detect comments FIRST so quotes inside comments don't get matched as strings
        let blockCommentRanges = Self.blockCommentRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { NSIntersectionRange($0, highlightRange).length > 0 }
        let lineCommentRanges = Self.lineCommentRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { NSIntersectionRange($0, highlightRange).length > 0 }
        let commentRanges = blockCommentRanges + lineCommentRanges

        // Detect strings, excluding anything inside comments
        let stringRanges = Self.stringRegex.matches(in: text, range: scanRange)
            .map(\.range)
            .filter { range in
                NSIntersectionRange(range, highlightRange).length > 0
                    && !intersects(range, with: commentRanges)
            }

        for range in stringRanges {
            storage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in Self.variableRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in Self.keywordRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.builtInRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in Self.commandRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for range in commentRanges {
            storage.addAttributes(theme.commentAttributes, range: range)
        }
    }
}

private func highlightedRange(for editedRange: NSRange?, in text: NSString, fallback: NSRange) -> NSRange {
    guard let editedRange,
          editedRange.location != NSNotFound,
          editedRange.location <= text.length else {
        return fallback
    }

    let clampedLength = min(editedRange.length, text.length - editedRange.location)
    let clampedRange = NSRange(location: editedRange.location, length: clampedLength)
    return expandedLineRange(for: clampedRange, in: text)
}

private func contextualScanRange(for range: NSRange, in text: NSString, expansion: Int = 4_096) -> NSRange {
    guard text.length > 0 else { return NSRange(location: 0, length: 0) }

    let start = max(range.location - expansion, 0)
    let end = min(NSMaxRange(range) + expansion, text.length)
    let expandedRange = NSRange(location: start, length: end - start)
    return expandedLineRange(for: expandedRange, in: text)
}

private func expandedLineRange(for range: NSRange, in text: NSString) -> NSRange {
    guard text.length > 0 else { return NSRange(location: 0, length: 0) }

    let startLineStart = lineStart(in: text, at: range.location)
    let endLocation = min(NSMaxRange(range), text.length)
    let endLineEnd = lineEnd(in: text, at: endLocation)
    return NSRange(location: startLineStart, length: endLineEnd - startLineStart)
}

// MARK: - XML / PList Highlighter
struct XMLSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let tagRegex = try! NSRegularExpression(pattern: #"<\/?[A-Za-z_:][A-Za-z0-9_:\.-]*"#)
    private static let tagDelimiterRegex = try! NSRegularExpression(pattern: #"/?>"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"\s([A-Za-z_:][A-Za-z0-9_:\.-]*)\s*="#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b-?\d+\.?\d*\b"#)
    private static let booleanRegex = try! NSRegularExpression(pattern: #"(?m)\b(true|false)\b"#)

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = highlightedRange(for: range, in: text as NSString, fallback: fullRange)

        // Only limit range when a specific edit range was provided (not during force/full highlighting)
        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        let (stringRanges, commentRanges) = xmlStringsAndComments(in: text as NSString, within: highlightRange)

        for range in stringRanges {
            storage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in Self.tagRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.tagDelimiterRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.attributeRegex.matches(in: text, range: highlightRange)
        where match.numberOfRanges > 1 && !intersects(match.range(at: 1), with: commentRanges + stringRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range(at: 1))
        }

        for match in Self.numberRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for match in Self.booleanRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: commentRanges + stringRanges) {
            storage.addAttributes(theme.builtinAttributes, range: match.range)
        }

        for range in commentRanges {
            storage.addAttributes(theme.commentAttributes, range: range)
        }
    }

    private func xmlStringsAndComments(in text: NSString, within range: NSRange) -> ([NSRange], [NSRange]) {
        var stringRanges: [NSRange] = []
        var commentRanges: [NSRange] = []
        var index = range.location

        while index < NSMaxRange(range) {
            let remaining = text.substring(from: index)
            let nsRange = NSRange(remaining.startIndex..., in: remaining)
            if nsRange.length == 0 { break }

            let substring = text.substring(with: NSRange(location: index, length: min(4, text.length - index)))

            // Comment: <!--
            if substring.hasPrefix("<!--") {
                let searchRange = NSRange(location: index, length: text.length - index)
                let endIdx = text.range(of: "-->", options: [], range: searchRange)
                if endIdx.location != NSNotFound {
                    let commentEnd = endIdx.location + 3
                    commentRanges.append(NSRange(location: index, length: commentEnd - index))
                    index = commentEnd
                } else {
                    commentRanges.append(NSRange(location: index, length: text.length - index))
                    break
                }
                continue
            }

            // String in quotes
            if text.character(at: index) == 34 { // "
                var end = index + 1
                var escaped = false
                while end < text.length {
                    let ch = text.character(at: end)
                    if ch == 92 { // backslash
                        escaped = !escaped
                        end += 1
                        continue
                    }
                    if ch == 34 && !escaped {
                        end += 1
                        break
                    }
                    escaped = false
                    end += 1
                }
                stringRanges.append(NSRange(location: index, length: end - index))
                index = end
                continue
            }

            index += 1
        }

        return (stringRanges, commentRanges)
    }
}

// MARK: - JSON Highlighter
struct JSONSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private enum TokenKind {
        case key
        case string
        case number
        case boolean
        case null
        case comment
    }

    private struct Token {
        let kind: TokenKind
        let range: NSRange
    }

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        for token in jsonTokens(in: nsText, within: scanRange) {
            let visibleRange = NSIntersectionRange(token.range, highlightRange)
            guard visibleRange.length > 0 else { continue }

            switch token.kind {
            case .key:
                storage.addAttributes(theme.variableAttributes, range: visibleRange)
            case .string:
                storage.addAttributes(theme.stringAttributes, range: visibleRange)
            case .number, .boolean:
                storage.addAttributes(theme.builtinAttributes, range: visibleRange)
            case .null:
                storage.addAttributes(theme.keywordAttributes, range: visibleRange)
            case .comment:
                storage.addAttributes(theme.commentAttributes, range: visibleRange)
            }
        }
    }

    private func jsonTokens(in text: NSString, within range: NSRange) -> [Token] {
        var tokens: [Token] = []
        var index = range.location
        let scanEnd = min(NSMaxRange(range), text.length)

        while index < scanEnd {
            let ch = text.character(at: index)

            if index + 1 < text.length, ch == 47, text.character(at: index + 1) == 47 {
                let end = lineEnd(in: text, at: index)
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            if index + 1 < text.length, ch == 47, text.character(at: index + 1) == 42 {
                let searchRange = NSRange(location: index + 2, length: text.length - index - 2)
                let endRange = text.range(of: "*/", options: [], range: searchRange)
                let end = endRange.location == NSNotFound ? text.length : endRange.location + 2
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            if ch == 34 {
                let end = stringEnd(in: text, startingAt: index)
                let tokenRange = NSRange(location: index, length: end - index)
                let kind: TokenKind = isObjectKey(in: text, afterStringEndingAt: end) ? .key : .string
                tokens.append(Token(kind: kind, range: tokenRange))
                index = end
                continue
            }

            if let end = numberEnd(in: text, startingAt: index) {
                tokens.append(Token(kind: .number, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            if matchesLiteral("true", in: text, at: index) {
                tokens.append(Token(kind: .boolean, range: NSRange(location: index, length: 4)))
                index += 4
                continue
            }

            if matchesLiteral("false", in: text, at: index) {
                tokens.append(Token(kind: .boolean, range: NSRange(location: index, length: 5)))
                index += 5
                continue
            }

            if matchesLiteral("null", in: text, at: index) {
                tokens.append(Token(kind: .null, range: NSRange(location: index, length: 4)))
                index += 4
                continue
            }

            index += 1
        }

        return tokens
    }

    private func stringEnd(in text: NSString, startingAt index: Int) -> Int {
        var end = index + 1
        while end < text.length {
            let ch = text.character(at: end)
            if ch == 92 {
                end = min(end + 2, text.length)
                continue
            }
            end += 1
            if ch == 34 {
                break
            }
        }
        return end
    }

    private func isObjectKey(in text: NSString, afterStringEndingAt end: Int) -> Bool {
        var index = end
        while index < text.length {
            let ch = text.character(at: index)
            if !isWhitespace(ch) {
                return ch == 58
            }
            index += 1
        }
        return false
    }

    private func numberEnd(in text: NSString, startingAt index: Int) -> Int? {
        var cursor = index
        if text.character(at: cursor) == 45 {
            cursor += 1
            guard cursor < text.length else { return nil }
        }

        guard cursor < text.length, isDigit(text.character(at: cursor)) else { return nil }

        if text.character(at: cursor) == 48 {
            cursor += 1
        } else {
            while cursor < text.length, isDigit(text.character(at: cursor)) {
                cursor += 1
            }
        }

        if cursor < text.length, text.character(at: cursor) == 46 {
            let fractionStart = cursor
            cursor += 1
            guard cursor < text.length, isDigit(text.character(at: cursor)) else {
                return fractionStart == index ? nil : fractionStart
            }
            while cursor < text.length, isDigit(text.character(at: cursor)) {
                cursor += 1
            }
        }

        if cursor < text.length, isExponentMarker(text.character(at: cursor)) {
            let exponentStart = cursor
            cursor += 1
            if cursor < text.length, isSign(text.character(at: cursor)) {
                cursor += 1
            }
            guard cursor < text.length, isDigit(text.character(at: cursor)) else {
                return exponentStart == index ? nil : exponentStart
            }
            while cursor < text.length, isDigit(text.character(at: cursor)) {
                cursor += 1
            }
        }

        guard !isIdentifierBoundaryViolation(in: text, start: index, end: cursor) else { return nil }
        return cursor
    }

    private func matchesLiteral(_ literal: String, in text: NSString, at index: Int) -> Bool {
        let literalLength = (literal as NSString).length
        guard index + literalLength <= text.length else { return false }
        guard text.substring(with: NSRange(location: index, length: literalLength)) == literal else { return false }
        return !isIdentifierBoundaryViolation(in: text, start: index, end: index + literalLength)
    }

    private func isIdentifierBoundaryViolation(in text: NSString, start: Int, end: Int) -> Bool {
        if start > 0, isIdentifierCharacter(text.character(at: start - 1)) {
            return true
        }
        if end < text.length, isIdentifierCharacter(text.character(at: end)) {
            return true
        }
        return false
    }

    private func isWhitespace(_ ch: unichar) -> Bool {
        ch == 32 || ch == 9 || ch == 10 || ch == 13
    }

    private func isDigit(_ ch: unichar) -> Bool {
        ch >= 48 && ch <= 57
    }

    private func isExponentMarker(_ ch: unichar) -> Bool {
        ch == 69 || ch == 101
    }

    private func isSign(_ ch: unichar) -> Bool {
        ch == 43 || ch == 45
    }

    private func isIdentifierCharacter(_ ch: unichar) -> Bool {
        (ch >= 48 && ch <= 57)
            || (ch >= 65 && ch <= 90)
            || (ch >= 97 && ch <= 122)
            || ch == 95
    }
}

struct LogfileSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"""
        (?xmi)
        \b
        (?:
            \d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{3,6})?(?:Z|[+-]\d{2}:?\d{2})?
            |
            \d{2}:\d{2}:\d{2}(?:[.,]\d{3,6})?
            |
            [A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}
        )
        \b
        """#
    )
    private static let levelRegex = try! NSRegularExpression(
        pattern: #"(?mi)\b(trace|debug|info|notice|warn|warning|error|err|critical|fatal|panic)\b"#
    )
    private static let bracketContextRegex = try! NSRegularExpression(
        pattern: #"\[[A-Za-z0-9_.:/#-]+\]"#
    )
    private static let keyRegex = try! NSRegularExpression(
        pattern: #"(?m)\b([A-Za-z_][A-Za-z0-9_.-]*)="#
    )
    private static let quotedStringRegex = try! NSRegularExpression(
        pattern: #"\"([^\n\"\\]|\\.)*\"|'([^\n'\\]|\\.)*'"#
    )
    private static let stackTraceRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s+(?:at\b|File\b|Caused by:|Traceback\b).*$"#
    )

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = highlightedRange(for: range, in: text as NSString, fallback: fullRange)

        if range != nil, highlightRange.length >= maxFullHighlightSize {
            storage.setAttributes(theme.baseAttributes, range: highlightRange)
            return
        }

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        let stringRanges = Self.quotedStringRegex.matches(in: text, range: highlightRange).map(\.range)
        let stackTraceRanges = Self.stackTraceRegex.matches(in: text, range: highlightRange).map(\.range)

        for range in stringRanges {
            storage.addAttributes(theme.stringAttributes, range: range)
        }

        for match in Self.timestampRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: stringRanges) {
            storage.addAttributes(theme.commandAttributes, range: match.range)
        }

        for match in Self.levelRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: stringRanges) {
            storage.addAttributes(theme.keywordAttributes, range: match.range)
        }

        for match in Self.bracketContextRegex.matches(in: text, range: highlightRange)
        where !intersects(match.range, with: stringRanges + stackTraceRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range)
        }

        for match in Self.keyRegex.matches(in: text, range: highlightRange)
        where match.numberOfRanges > 1 && !intersects(match.range(at: 1), with: stringRanges + stackTraceRanges) {
            storage.addAttributes(theme.variableAttributes, range: match.range(at: 1))
        }

        for range in stackTraceRanges {
            storage.addAttributes(theme.commentAttributes, range: range)
        }
    }
}

private func lineStart(in text: NSString, at location: Int) -> Int {
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

enum SyntaxHighlighterFactory {
    static func makeHighlighter(for language: EditorLanguage, skin: SkinDefinition, editorFont: NSFont, semiboldFont: NSFont) -> SyntaxHighlighting {
        let theme = skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: semiboldFont)

        switch language {
        case .logfile:
            return LogfileSyntaxHighlighter(theme: theme)
        case .markdown:
            return MarkdownSyntaxHighlighter(theme: theme)
        case .shell:
            return ShellSyntaxHighlighter(theme: theme)
        case .dotenv:
            return DotEnvSyntaxHighlighter(theme: theme)
        case .python:
            return PythonSyntaxHighlighter(theme: theme)
        case .powerShell:
            return PowerShellSyntaxHighlighter(theme: theme)
        case .xml:
            return XMLSyntaxHighlighter(theme: theme)
        case .json:
            return JSONSyntaxHighlighter(theme: theme)
        case .plainText:
            return PlainTextHighlighter(theme: theme)
        }
    }
}

struct SkinTheme {
    static let fallback = SkinDefinition(
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
