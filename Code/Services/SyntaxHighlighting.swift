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

private func applyAttributes(
    _ attributes: [NSAttributedString.Key: Any],
    range: NSRange,
    visibleIn visibleRange: NSRange,
    to storage: NSMutableAttributedString
) {
    let effectiveRange = NSIntersectionRange(range, visibleRange)
    guard effectiveRange.length > 0 else { return }
    storage.addAttributes(attributes, range: effectiveRange)
}

private func isWhitespace(_ ch: unichar) -> Bool {
    ch == 32 || ch == 9
}

private func isIdentifierStart(_ ch: unichar) -> Bool {
    (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95
}

private func isIdentifierCharacter(_ ch: unichar) -> Bool {
    isIdentifierStart(ch) || (ch >= 48 && ch <= 57)
}

private func isDigit(_ ch: unichar) -> Bool {
    ch >= 48 && ch <= 57
}

private func isShellWordStart(_ ch: unichar) -> Bool {
    isIdentifierStart(ch) || ch == 46 || ch == 47 || ch == 45
}

private func quotedStringEnd(in text: NSString, startingAt index: Int, quote: unichar, lineEnd: Int) -> Int {
    var cursor = index + 1
    var escaped = false
    while cursor < lineEnd {
        let ch = text.character(at: cursor)
        if quote == 34, ch == 92, !escaped {
            escaped = true
            cursor += 1
            continue
        }
        if ch == quote, !escaped {
            return cursor + 1
        }
        escaped = false
        cursor += 1
    }
    return cursor
}

private func identifierEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
    var cursor = index
    guard cursor < lineEnd, isIdentifierStart(text.character(at: cursor)) else { return cursor }
    cursor += 1
    while cursor < lineEnd, isIdentifierCharacter(text.character(at: cursor)) {
        cursor += 1
    }
    return cursor
}

private func dottedIdentifierEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
    var cursor = index
    var consumedIdentifier = false
    while cursor < lineEnd {
        guard isIdentifierStart(text.character(at: cursor)) else { break }
        consumedIdentifier = true
        cursor = identifierEnd(in: text, startingAt: cursor, lineEnd: lineEnd)
        if cursor < lineEnd, text.character(at: cursor) == 46 {
            cursor += 1
        } else {
            break
        }
    }
    return consumedIdentifier ? cursor : index
}

private func firstCodeCharacter(in text: NSString, lineRange: NSRange) -> Int {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    while cursor < end, isWhitespace(text.character(at: cursor)) {
        cursor += 1
    }
    return cursor
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

    private enum State {
        case normal
        case fence(String)
        case htmlComment
    }

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText, expansion: 32_768)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var state = range == nil ? State.normal : stateBefore(scanRange.location, in: nsText)
        var lineLocation = scanRange.location
        let scanEnd = NSMaxRange(scanRange)
        while lineLocation < scanEnd {
            let lineRange = NSRange(location: lineLocation, length: lineEnd(in: nsText, at: lineLocation) - lineLocation)
            state = scanLine(in: nsText, lineRange: lineRange, visibleRange: highlightRange, state: state, storage: storage)
            lineLocation = NSMaxRange(lineRange)
        }
    }

    private func scanLine(
        in text: NSString,
        lineRange: NSRange,
        visibleRange: NSRange,
        state initialState: State,
        storage: NSMutableAttributedString
    ) -> State {
        let state = initialState
        let end = NSMaxRange(lineRange)
        let first = firstCodeCharacter(in: text, lineRange: lineRange)

        switch state {
        case .fence(let delimiter):
            applyAttributes(theme.stringAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
            return lineHasPrefix(delimiter, in: text, at: first, lineEnd: end) ? .normal : state
        case .htmlComment:
            let tokenEnd = markdownHTMLCommentEnd(in: text, startingAt: lineRange.location, lineEnd: end)
            applyAttributes(theme.commentAttributes, range: NSRange(location: lineRange.location, length: tokenEnd.location - lineRange.location), visibleIn: visibleRange, to: storage)
            if tokenEnd.closed {
                scanInline(in: text, range: NSRange(location: tokenEnd.location, length: end - tokenEnd.location), visibleRange: visibleRange, storage: storage)
                return .normal
            }
            return .htmlComment
        case .normal:
            break
        }

        if lineHasPrefix("```", in: text, at: first, lineEnd: end) {
            applyAttributes(theme.stringAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
            return .fence("```")
        }
        if lineHasPrefix("~~~", in: text, at: first, lineEnd: end) {
            applyAttributes(theme.stringAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
            return .fence("~~~")
        }
        if lineHasPrefix("<!--", in: text, at: first, lineEnd: end) {
            let tokenEnd = markdownHTMLCommentEnd(in: text, startingAt: first + 4, lineEnd: end)
            applyAttributes(theme.commentAttributes, range: NSRange(location: first, length: tokenEnd.location - first), visibleIn: visibleRange, to: storage)
            if !tokenEnd.closed { return .htmlComment }
        }

        if first < end, text.character(at: first) == 35 {
            var cursor = first
            while cursor < end, text.character(at: cursor) == 35 {
                cursor += 1
            }
            if cursor > first, cursor - first <= 6, cursor < end, isWhitespace(text.character(at: cursor)) {
                applyAttributes(theme.commandAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
                applyAttributes(theme.keywordAttributes, range: NSRange(location: first, length: cursor - first), visibleIn: visibleRange, to: storage)
                scanInline(in: text, range: NSRange(location: cursor, length: end - cursor), visibleRange: visibleRange, storage: storage)
                return .normal
            }
        }

        if first < end, text.character(at: first) == 62 {
            applyAttributes(theme.commentAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
            return .normal
        }

        if let markerRange = listMarkerRange(in: text, first: first, lineEnd: end) {
            applyAttributes(theme.keywordAttributes, range: markerRange, visibleIn: visibleRange, to: storage)
        }

        scanInline(in: text, range: lineRange, visibleRange: visibleRange, storage: storage)
        return .normal
    }

    private func scanInline(in text: NSString, range: NSRange, visibleRange: NSRange, storage: NSMutableAttributedString) {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let ch = text.character(at: index)
            if ch == 96 {
                var cursor = index + 1
                while cursor < end, text.character(at: cursor) != 96 {
                    cursor += 1
                }
                if cursor < end {
                    applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: cursor - index + 1), visibleIn: visibleRange, to: storage)
                    index = cursor + 1
                    continue
                }
            }
            if ch == 91, let linkEnd = markdownLinkEnd(in: text, startingAt: index, lineEnd: end) {
                applyAttributes(theme.builtinAttributes, range: NSRange(location: index, length: linkEnd - index), visibleIn: visibleRange, to: storage)
                index = linkEnd
                continue
            }
            if index + 3 < end,
               ch == 60,
               text.character(at: index + 1) == 33,
               text.character(at: index + 2) == 45,
               text.character(at: index + 3) == 45 {
                let tokenEnd = markdownHTMLCommentEnd(in: text, startingAt: index + 4, lineEnd: end)
                applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
                index = tokenEnd.location
                continue
            }
            index += 1
        }
    }

    private func stateBefore(_ location: Int, in text: NSString) -> State {
        guard location > 0 else { return .normal }
        let start = max(location - 65_536, 0)
        var lineLocation = lineStart(in: text, at: start)
        var state = State.normal
        while lineLocation < location {
            let lineRange = NSRange(location: lineLocation, length: min(lineEnd(in: text, at: lineLocation), location) - lineLocation)
            state = markdownStateOnly(in: text, lineRange: lineRange, state: state)
            lineLocation = NSMaxRange(lineRange)
        }
        return state
    }

    private func markdownStateOnly(in text: NSString, lineRange: NSRange, state initialState: State) -> State {
        let end = NSMaxRange(lineRange)
        let first = firstCodeCharacter(in: text, lineRange: lineRange)
        switch initialState {
        case .fence(let delimiter):
            return lineHasPrefix(delimiter, in: text, at: first, lineEnd: end) ? .normal : initialState
        case .htmlComment:
            let tokenEnd = markdownHTMLCommentEnd(in: text, startingAt: lineRange.location, lineEnd: end)
            return tokenEnd.closed ? .normal : .htmlComment
        case .normal:
            if lineHasPrefix("```", in: text, at: first, lineEnd: end) { return .fence("```") }
            if lineHasPrefix("~~~", in: text, at: first, lineEnd: end) { return .fence("~~~") }
            if lineHasPrefix("<!--", in: text, at: first, lineEnd: end) {
                let tokenEnd = markdownHTMLCommentEnd(in: text, startingAt: first + 4, lineEnd: end)
                return tokenEnd.closed ? .normal : .htmlComment
            }
            return .normal
        }
    }

    private func listMarkerRange(in text: NSString, first: Int, lineEnd: Int) -> NSRange? {
        guard first < lineEnd else { return nil }
        let ch = text.character(at: first)
        if ch == 45 || ch == 42 || ch == 43 {
            if first + 1 < lineEnd, isWhitespace(text.character(at: first + 1)) {
                return NSRange(location: first, length: 1)
            }
            return nil
        }
        guard isDigit(ch) else { return nil }
        var cursor = first
        while cursor < lineEnd, isDigit(text.character(at: cursor)) {
            cursor += 1
        }
        if cursor < lineEnd, text.character(at: cursor) == 46,
           cursor + 1 < lineEnd, isWhitespace(text.character(at: cursor + 1)) {
            return NSRange(location: first, length: cursor - first + 1)
        }
        return nil
    }

    private func markdownLinkEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int? {
        var cursor = index + 1
        while cursor < lineEnd, text.character(at: cursor) != 93 {
            cursor += 1
        }
        guard cursor + 1 < lineEnd, text.character(at: cursor) == 93, text.character(at: cursor + 1) == 40 else {
            return nil
        }
        cursor += 2
        while cursor < lineEnd, text.character(at: cursor) != 41 {
            cursor += 1
        }
        return cursor < lineEnd ? cursor + 1 : nil
    }

    private func markdownHTMLCommentEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> (location: Int, closed: Bool) {
        var cursor = index
        while cursor + 2 < lineEnd {
            if text.character(at: cursor) == 45,
               text.character(at: cursor + 1) == 45,
               text.character(at: cursor + 2) == 62 {
                return (cursor + 3, true)
            }
            cursor += 1
        }
        return (lineEnd, false)
    }

    private func lineHasPrefix(_ prefix: String, in text: NSString, at index: Int, lineEnd: Int) -> Bool {
        let length = (prefix as NSString).length
        guard index + length <= lineEnd else { return false }
        return text.substring(with: NSRange(location: index, length: length)) == prefix
    }
}

struct ShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "function", "in", "select", "until", "time"
    ]
    private static let builtins: Set<String> = [
        "export", "local", "readonly", "return", "shift", "unset", "eval",
        "exec", "source", "alias", "trap", "cd", "exit", "echo", "printf"
    ]

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var lineLocation = highlightRange.location
        let scanEnd = NSMaxRange(highlightRange)
        while lineLocation < scanEnd {
            let lineRange = NSRange(location: lineLocation, length: lineEnd(in: nsText, at: lineLocation) - lineLocation)
            scanLine(in: nsText, lineRange: lineRange, visibleRange: highlightRange, storage: storage)
            lineLocation = NSMaxRange(lineRange)
        }
    }

    private func scanLine(
        in text: NSString,
        lineRange: NSRange,
        visibleRange: NSRange,
        storage: NSMutableAttributedString
    ) {
        var index = lineRange.location
        let end = NSMaxRange(lineRange)
        var expectsCommand = true

        while index < end {
            let ch = text.character(at: index)

            if ch == 10 || ch == 13 { break }
            if isWhitespace(ch) {
                index += 1
                continue
            }

            if ch == 35, isShellCommentStart(in: text, at: index, lineStart: lineRange.location) {
                applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: end - index), visibleIn: visibleRange, to: storage)
                break
            }

            if ch == 34 || ch == 39 {
                let tokenEnd = quotedStringEnd(in: text, startingAt: index, quote: ch, lineEnd: end)
                applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                index = tokenEnd
                expectsCommand = false
                continue
            }

            if ch == 36 {
                let tokenEnd = shellVariableEnd(in: text, startingAt: index, lineEnd: end)
                if tokenEnd > index + 1 {
                    applyAttributes(theme.variableAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                    index = tokenEnd
                    expectsCommand = false
                    continue
                }
            }

            if isShellWordStart(ch) {
                let tokenEnd = shellWordEnd(in: text, startingAt: index, lineEnd: end)
                let word = text.substring(with: NSRange(location: index, length: tokenEnd - index))
                let tokenRange = NSRange(location: index, length: tokenEnd - index)
                if Self.keywords.contains(word) {
                    applyAttributes(theme.keywordAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if Self.builtins.contains(word) {
                    applyAttributes(theme.builtinAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if expectsCommand {
                    applyAttributes(theme.commandAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                }
                index = tokenEnd
                expectsCommand = false
                continue
            }

            if ch == 59 || ch == 124 || ch == 38 {
                expectsCommand = true
            }
            index += 1
        }
    }

    private func isShellCommentStart(in text: NSString, at index: Int, lineStart: Int) -> Bool {
        guard index > lineStart else { return true }
        let previous = text.character(at: index - 1)
        return isWhitespace(previous) || previous == 59 || previous == 124 || previous == 38
    }

    private func shellVariableEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        guard index + 1 < lineEnd else { return index }
        if text.character(at: index + 1) == 123 {
            var cursor = index + 2
            while cursor < lineEnd, text.character(at: cursor) != 125 {
                cursor += 1
            }
            return cursor < lineEnd ? cursor + 1 : cursor
        }

        var cursor = index + 1
        guard cursor < lineEnd, isIdentifierStart(text.character(at: cursor)) else { return index }
        cursor += 1
        while cursor < lineEnd, isIdentifierCharacter(text.character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    private func shellWordEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        var cursor = index
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isWhitespace(ch) || ch == 10 || ch == 13 || ch == 59 || ch == 124 || ch == 38 || ch == 40 || ch == 41 {
                break
            }
            cursor += 1
        }
        return cursor
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

    private enum State {
        case normal
        case tripleSingle
        case tripleDouble
    }

    private static let keywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "case", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise",
        "return", "try", "while", "with", "yield"
    ]
    private static let builtins: Set<String> = [
        "abs", "all", "any", "bool", "breakpoint", "bytearray", "bytes",
        "callable", "chr", "classmethod", "compile", "dict", "dir", "enumerate",
        "filter", "float", "format", "frozenset", "getattr", "hasattr", "hash",
        "hex", "input", "int", "isinstance", "issubclass", "iter", "len", "list",
        "map", "max", "min", "next", "object", "open", "ord", "pow", "print",
        "property", "range", "repr", "reversed", "round", "set", "setattr",
        "slice", "sorted", "staticmethod", "str", "sum", "super", "tuple",
        "type", "vars", "zip"
    ]

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var index = scanRange.location
        let scanEnd = NSMaxRange(scanRange)
        var state = range == nil ? State.normal : stateBefore(scanRange.location, in: nsText)

        while index < scanEnd {
            let lineRange = NSRange(location: index, length: lineEnd(in: nsText, at: index) - index)
            state = scanLine(
                in: nsText,
                lineRange: lineRange,
                visibleRange: highlightRange,
                state: state,
                storage: storage
            )
            index = NSMaxRange(lineRange)
        }
    }

    private func scanLine(
        in text: NSString,
        lineRange: NSRange,
        visibleRange: NSRange,
        state initialState: State,
        storage: NSMutableAttributedString
    ) -> State {
        var state = initialState
        var index = lineRange.location
        let end = NSMaxRange(lineRange)

        if state != .normal {
            let delimiter = state == .tripleSingle ? "'''" : "\"\"\""
            let tokenEnd = tripleStringEnd(in: text, startingAt: index, lineEnd: end, delimiter: delimiter)
            applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
            index = tokenEnd.location
            state = tokenEnd.closed ? .normal : state
        }

        let firstNonWhitespace = firstCodeCharacter(in: text, lineRange: lineRange)
        if firstNonWhitespace < end, text.character(at: firstNonWhitespace) == 64 {
            let decoratorEnd = dottedIdentifierEnd(in: text, startingAt: firstNonWhitespace + 1, lineEnd: end)
            if decoratorEnd > firstNonWhitespace + 1 {
                applyAttributes(theme.commandAttributes, range: NSRange(location: firstNonWhitespace, length: decoratorEnd - firstNonWhitespace), visibleIn: visibleRange, to: storage)
            }
        }

        while index < end {
            let ch = text.character(at: index)

            if ch == 10 || ch == 13 { break }
            if isWhitespace(ch) {
                index += 1
                continue
            }

            if ch == 35 {
                applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: end - index), visibleIn: visibleRange, to: storage)
                break
            }

            let stringPrefixLength = pythonStringPrefixLength(in: text, at: index, lineEnd: end)
            let quoteIndex = index + stringPrefixLength
            if quoteIndex < end {
                let quote = text.character(at: quoteIndex)
                if quote == 34 || quote == 39 {
                    if hasTripleQuote(in: text, at: quoteIndex, quote: quote, lineEnd: end) {
                        let delimiter = quote == 34 ? "\"\"\"" : "'''"
                        let tokenEnd = tripleStringEnd(in: text, startingAt: quoteIndex + 3, lineEnd: end, delimiter: delimiter)
                        applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
                        state = tokenEnd.closed ? .normal : (quote == 34 ? .tripleDouble : .tripleSingle)
                        index = tokenEnd.location
                    } else {
                        let tokenEnd = quotedStringEnd(in: text, startingAt: quoteIndex, quote: quote, lineEnd: end)
                        applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                        index = tokenEnd
                    }
                    continue
                }
            }

            if isIdentifierStart(ch) {
                let tokenEnd = identifierEnd(in: text, startingAt: index, lineEnd: end)
                let word = text.substring(with: NSRange(location: index, length: tokenEnd - index))
                let tokenRange = NSRange(location: index, length: tokenEnd - index)
                if word == "self" || word == "cls" {
                    applyAttributes(theme.variableAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if Self.keywords.contains(word) {
                    applyAttributes(theme.keywordAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if Self.builtins.contains(word) {
                    applyAttributes(theme.builtinAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                }
                index = tokenEnd
                continue
            }

            index += 1
        }

        return state
    }

    private func stateBefore(_ location: Int, in text: NSString) -> State {
        guard location > 0 else { return .normal }
        let start = max(location - 65_536, 0)
        var index = start
        var state = State.normal
        while index < location {
            let end = min(lineEnd(in: text, at: index), location)
            state = scanStateOnly(in: text, range: NSRange(location: index, length: end - index), state: state)
            index = end
        }
        return state
    }

    private func scanStateOnly(in text: NSString, range: NSRange, state initialState: State) -> State {
        let state = initialState
        var index = range.location
        let end = NSMaxRange(range)
        if state != .normal {
            let delimiter = state == .tripleSingle ? "'''" : "\"\"\""
            let tokenEnd = tripleStringEnd(in: text, startingAt: index, lineEnd: end, delimiter: delimiter)
            return tokenEnd.closed ? .normal : state
        }
        while index < end {
            let ch = text.character(at: index)
            if ch == 35 || ch == 10 || ch == 13 { return state }
            let prefixLength = pythonStringPrefixLength(in: text, at: index, lineEnd: end)
            let quoteIndex = index + prefixLength
            if quoteIndex < end {
                let quote = text.character(at: quoteIndex)
                if quote == 34 || quote == 39 {
                    if hasTripleQuote(in: text, at: quoteIndex, quote: quote, lineEnd: end) {
                        let delimiter = quote == 34 ? "\"\"\"" : "'''"
                        let tokenEnd = tripleStringEnd(in: text, startingAt: quoteIndex + 3, lineEnd: end, delimiter: delimiter)
                        if !tokenEnd.closed { return quote == 34 ? .tripleDouble : .tripleSingle }
                        index = tokenEnd.location
                        continue
                    }
                    index = quotedStringEnd(in: text, startingAt: quoteIndex, quote: quote, lineEnd: end)
                    continue
                }
            }
            index += 1
        }
        return state
    }

    private func pythonStringPrefixLength(in text: NSString, at index: Int, lineEnd: Int) -> Int {
        var cursor = index
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if ch == 70 || ch == 82 || ch == 66 || ch == 85 || ch == 102 || ch == 114 || ch == 98 || ch == 117 {
                cursor += 1
            } else {
                break
            }
        }
        return min(cursor - index, 2)
    }

    private func hasTripleQuote(in text: NSString, at index: Int, quote: unichar, lineEnd: Int) -> Bool {
        index + 2 < lineEnd && text.character(at: index + 1) == quote && text.character(at: index + 2) == quote
    }

    private func tripleStringEnd(in text: NSString, startingAt index: Int, lineEnd: Int, delimiter: String) -> (location: Int, closed: Bool) {
        let searchRange = NSRange(location: index, length: max(0, lineEnd - index))
        let found = text.range(of: delimiter, options: [], range: searchRange)
        if found.location == NSNotFound {
            return (lineEnd, false)
        }
        return (found.location + 3, true)
    }
}

struct PowerShellSyntaxHighlighter: SyntaxHighlighting {
    let theme: SkinTheme

    private enum State {
        case normal
        case blockComment
        case doubleHereString
        case singleHereString
    }

    private static let keywords: Set<String> = [
        "begin", "break", "catch", "class", "continue", "data", "default", "do",
        "dynamicparam", "else", "elseif", "end", "enum", "exit", "filter",
        "finally", "for", "foreach", "from", "function", "if", "in", "param",
        "process", "return", "switch", "throw", "trap", "try", "until", "using",
        "while", "workflow"
    ]
    private static let builtins: Set<String> = [
        "write-host", "write-output", "write-error", "write-warning", "write-verbose",
        "write-debug", "write-information", "read-host", "foreach-object",
        "where-object", "select-object", "sort-object", "group-object",
        "measure-object", "get-item", "set-item", "new-item", "remove-item",
        "copy-item", "move-item", "test-path", "join-path", "split-path",
        "resolve-path", "import-module", "export-modulemember",
        "invoke-expression", "start-process", "stop-process", "get-process",
        "get-service", "start-service", "stop-service", "set-location",
        "get-location", "clear-host", "out-file", "set-content", "add-content",
        "get-content"
    ]

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var index = scanRange.location
        let scanEnd = NSMaxRange(scanRange)
        var state = range == nil ? State.normal : stateBefore(scanRange.location, in: nsText)

        while index < scanEnd {
            let lineRange = NSRange(location: index, length: lineEnd(in: nsText, at: index) - index)
            state = scanLine(in: nsText, lineRange: lineRange, visibleRange: highlightRange, state: state, storage: storage)
            index = NSMaxRange(lineRange)
        }
    }

    private func scanLine(
        in text: NSString,
        lineRange: NSRange,
        visibleRange: NSRange,
        state initialState: State,
        storage: NSMutableAttributedString
    ) -> State {
        var state = initialState
        var index = lineRange.location
        let end = NSMaxRange(lineRange)

        if state == .blockComment {
            let tokenEnd = powershellBlockCommentEnd(in: text, startingAt: index, lineEnd: end)
            applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
            index = tokenEnd.location
            state = tokenEnd.closed ? .normal : .blockComment
        } else if state == .doubleHereString || state == .singleHereString {
            let delimiter = state == .doubleHereString ? "\"@" : "'@"
            let tokenEnd = powershellHereStringEnd(in: text, startingAt: index, lineEnd: end, delimiter: delimiter)
            applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
            index = tokenEnd.location
            state = tokenEnd.closed ? .normal : state
        }

        while index < end {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 { break }
            if isWhitespace(ch) {
                index += 1
                continue
            }

            if ch == 35 {
                applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: end - index), visibleIn: visibleRange, to: storage)
                break
            }

            if index + 1 < end, ch == 60, text.character(at: index + 1) == 35 {
                let tokenEnd = powershellBlockCommentEnd(in: text, startingAt: index + 2, lineEnd: end)
                applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
                state = tokenEnd.closed ? .normal : .blockComment
                index = tokenEnd.location
                continue
            }

            if index + 1 < end, ch == 64, text.character(at: index + 1) == 34 {
                let tokenEnd = powershellHereStringEnd(in: text, startingAt: index + 2, lineEnd: end, delimiter: "\"@")
                applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
                state = tokenEnd.closed ? .normal : .doubleHereString
                index = tokenEnd.location
                continue
            }

            if index + 1 < end, ch == 64, text.character(at: index + 1) == 39 {
                let tokenEnd = powershellHereStringEnd(in: text, startingAt: index + 2, lineEnd: end, delimiter: "'@")
                applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd.location - index), visibleIn: visibleRange, to: storage)
                state = tokenEnd.closed ? .normal : .singleHereString
                index = tokenEnd.location
                continue
            }

            if ch == 34 || ch == 39 {
                let tokenEnd = quotedStringEnd(in: text, startingAt: index, quote: ch, lineEnd: end)
                applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                index = tokenEnd
                continue
            }

            if ch == 36 {
                let tokenEnd = powershellVariableEnd(in: text, startingAt: index, lineEnd: end)
                if tokenEnd > index + 1 {
                    applyAttributes(theme.variableAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                    index = tokenEnd
                    continue
                }
            }

            if isIdentifierStart(ch) {
                let tokenEnd = powershellWordEnd(in: text, startingAt: index, lineEnd: end)
                let word = text.substring(with: NSRange(location: index, length: tokenEnd - index))
                let lower = word.lowercased()
                let tokenRange = NSRange(location: index, length: tokenEnd - index)
                if Self.keywords.contains(lower) {
                    applyAttributes(theme.keywordAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if Self.builtins.contains(lower) {
                    applyAttributes(theme.builtinAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                } else if lower.contains("-") {
                    applyAttributes(theme.commandAttributes, range: tokenRange, visibleIn: visibleRange, to: storage)
                }
                index = tokenEnd
                continue
            }

            index += 1
        }

        return state
    }

    private func stateBefore(_ location: Int, in text: NSString) -> State {
        guard location > 0 else { return .normal }
        let start = max(location - 65_536, 0)
        var index = start
        var state = State.normal
        while index < location {
            let end = min(lineEnd(in: text, at: index), location)
            state = scanStateOnly(in: text, range: NSRange(location: index, length: end - index), state: state)
            index = end
        }
        return state
    }

    private func scanStateOnly(in text: NSString, range: NSRange, state initialState: State) -> State {
        var state = initialState
        var index = range.location
        let end = NSMaxRange(range)
        if state == .blockComment {
            let tokenEnd = powershellBlockCommentEnd(in: text, startingAt: index, lineEnd: end)
            return tokenEnd.closed ? .normal : .blockComment
        }
        if state == .doubleHereString || state == .singleHereString {
            let delimiter = state == .doubleHereString ? "\"@" : "'@"
            let tokenEnd = powershellHereStringEnd(in: text, startingAt: index, lineEnd: end, delimiter: delimiter)
            return tokenEnd.closed ? .normal : state
        }
        while index < end {
            let ch = text.character(at: index)
            if ch == 35 || ch == 10 || ch == 13 { return state }
            if index + 1 < end, ch == 60, text.character(at: index + 1) == 35 {
                let tokenEnd = powershellBlockCommentEnd(in: text, startingAt: index + 2, lineEnd: end)
                state = tokenEnd.closed ? .normal : .blockComment
                index = tokenEnd.location
                continue
            }
            if index + 1 < end, ch == 64, text.character(at: index + 1) == 34 {
                let tokenEnd = powershellHereStringEnd(in: text, startingAt: index + 2, lineEnd: end, delimiter: "\"@")
                state = tokenEnd.closed ? .normal : .doubleHereString
                index = tokenEnd.location
                continue
            }
            if index + 1 < end, ch == 64, text.character(at: index + 1) == 39 {
                let tokenEnd = powershellHereStringEnd(in: text, startingAt: index + 2, lineEnd: end, delimiter: "'@")
                state = tokenEnd.closed ? .normal : .singleHereString
                index = tokenEnd.location
                continue
            }
            if ch == 34 || ch == 39 {
                index = quotedStringEnd(in: text, startingAt: index, quote: ch, lineEnd: end)
                continue
            }
            index += 1
        }
        return state
    }

    private func powershellBlockCommentEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> (location: Int, closed: Bool) {
        var cursor = index
        while cursor + 1 < lineEnd {
            if text.character(at: cursor) == 35, text.character(at: cursor + 1) == 62 {
                return (cursor + 2, true)
            }
            cursor += 1
        }
        return (lineEnd, false)
    }

    private func powershellHereStringEnd(in text: NSString, startingAt index: Int, lineEnd: Int, delimiter: String) -> (location: Int, closed: Bool) {
        let found = text.range(of: delimiter, options: [], range: NSRange(location: index, length: max(0, lineEnd - index)))
        if found.location == NSNotFound {
            return (lineEnd, false)
        }
        return (found.location + 2, true)
    }

    private func powershellVariableEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        guard index + 1 < lineEnd else { return index }
        if text.character(at: index + 1) == 123 {
            var cursor = index + 2
            while cursor < lineEnd, text.character(at: cursor) != 125 {
                cursor += 1
            }
            return cursor < lineEnd ? cursor + 1 : cursor
        }
        var cursor = index + 1
        guard cursor < lineEnd, isIdentifierStart(text.character(at: cursor)) else { return index }
        cursor += 1
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isIdentifierCharacter(ch) || ch == 58 {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
    }

    private func powershellWordEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        var cursor = index
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isIdentifierCharacter(ch) || ch == 45 {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
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

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : contextualScanRange(for: highlightRange, in: nsText)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var index = scanRange.location
        let scanEnd = NSMaxRange(scanRange)
        while index < scanEnd {
            let ch = nsText.character(at: index)
            if ch == 60 {
                if index + 3 < nsText.length,
                   nsText.character(at: index + 1) == 33,
                   nsText.character(at: index + 2) == 45,
                   nsText.character(at: index + 3) == 45 {
                    let tokenEnd = xmlCommentEnd(in: nsText, startingAt: index + 4, scanEnd: scanEnd)
                    applyAttributes(theme.commentAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: highlightRange, to: storage)
                    index = tokenEnd
                    continue
                }

                index = scanTag(in: nsText, startingAt: index, scanEnd: scanEnd, visibleRange: highlightRange, storage: storage)
                continue
            }

            if isDigit(ch) || ch == 45 {
                if let tokenEnd = xmlNumberEnd(in: nsText, startingAt: index, scanEnd: scanEnd) {
                    applyAttributes(theme.builtinAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: highlightRange, to: storage)
                    index = tokenEnd
                    continue
                }
            }

            if isIdentifierStart(ch) {
                let tokenEnd = identifierEnd(in: nsText, startingAt: index, lineEnd: scanEnd)
                let word = nsText.substring(with: NSRange(location: index, length: tokenEnd - index))
                if word == "true" || word == "false" {
                    applyAttributes(theme.builtinAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: highlightRange, to: storage)
                }
                index = tokenEnd
                continue
            }

            index += 1
        }
    }

    private func scanTag(
        in text: NSString,
        startingAt index: Int,
        scanEnd: Int,
        visibleRange: NSRange,
        storage: NSMutableAttributedString
    ) -> Int {
        var cursor = index
        let end = min(scanEnd, text.length)
        guard cursor < end, text.character(at: cursor) == 60 else { return index + 1 }

        cursor += 1
        if cursor < end, text.character(at: cursor) == 47 {
            cursor += 1
        }

        if cursor < end, isXMLNameStart(text.character(at: cursor)) {
            let nameEnd = xmlNameEnd(in: text, startingAt: cursor, scanEnd: end)
            applyAttributes(theme.keywordAttributes, range: NSRange(location: index, length: nameEnd - index), visibleIn: visibleRange, to: storage)
            cursor = nameEnd
        } else {
            applyAttributes(theme.keywordAttributes, range: NSRange(location: index, length: 1), visibleIn: visibleRange, to: storage)
        }

        while cursor < end {
            let ch = text.character(at: cursor)
            if ch == 34 || ch == 39 {
                let tokenEnd = quotedStringEnd(in: text, startingAt: cursor, quote: ch, lineEnd: end)
                applyAttributes(theme.stringAttributes, range: NSRange(location: cursor, length: tokenEnd - cursor), visibleIn: visibleRange, to: storage)
                cursor = tokenEnd
                continue
            }
            if ch == 62 {
                applyAttributes(theme.keywordAttributes, range: NSRange(location: cursor, length: 1), visibleIn: visibleRange, to: storage)
                return cursor + 1
            }
            if cursor + 1 < end, ch == 47, text.character(at: cursor + 1) == 62 {
                applyAttributes(theme.keywordAttributes, range: NSRange(location: cursor, length: 2), visibleIn: visibleRange, to: storage)
                return cursor + 2
            }
            if isXMLNameStart(ch) {
                let nameEnd = xmlNameEnd(in: text, startingAt: cursor, scanEnd: end)
                var probe = nameEnd
                while probe < end, isWhitespace(text.character(at: probe)) {
                    probe += 1
                }
                if probe < end, text.character(at: probe) == 61 {
                    applyAttributes(theme.variableAttributes, range: NSRange(location: cursor, length: nameEnd - cursor), visibleIn: visibleRange, to: storage)
                }
                cursor = nameEnd
                continue
            }
            cursor += 1
        }
        return cursor
    }

    private func xmlCommentEnd(in text: NSString, startingAt index: Int, scanEnd: Int) -> Int {
        var cursor = index
        while cursor + 2 < scanEnd {
            if text.character(at: cursor) == 45,
               text.character(at: cursor + 1) == 45,
               text.character(at: cursor + 2) == 62 {
                return cursor + 3
            }
            cursor += 1
        }
        return scanEnd
    }

    private func xmlNameEnd(in text: NSString, startingAt index: Int, scanEnd: Int) -> Int {
        var cursor = index
        while cursor < scanEnd {
            let ch = text.character(at: cursor)
            if isXMLNameStart(ch) || isDigit(ch) || ch == 45 || ch == 46 {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
    }

    private func xmlNumberEnd(in text: NSString, startingAt index: Int, scanEnd: Int) -> Int? {
        var cursor = index
        if text.character(at: cursor) == 45 {
            cursor += 1
        }
        guard cursor < scanEnd, isDigit(text.character(at: cursor)) else { return nil }
        while cursor < scanEnd, isDigit(text.character(at: cursor)) {
            cursor += 1
        }
        if cursor < scanEnd, text.character(at: cursor) == 46 {
            cursor += 1
            while cursor < scanEnd, isDigit(text.character(at: cursor)) {
                cursor += 1
            }
        }
        return cursor
    }

    private func isXMLNameStart(_ ch: unichar) -> Bool {
        isIdentifierStart(ch) || ch == 58
    }
}

// MARK: - JSON Highlighter
final class JSONSyntaxHighlighter: SyntaxHighlighting {
    private static let maxCachedLines = 2_000
    private static let maxCachedLineLength = 20_000
    private static let contextualScanExpansion = 2_048

    let theme: SkinTheme

    init(theme: SkinTheme) {
        self.theme = theme
    }

    private enum LineState: Hashable {
        case normal
        case blockComment
    }

    private enum TokenKind {
        case key
        case string
        case number
        case boolean
        case null
        case comment
    }

    private struct CacheKey: Hashable {
        let text: String
        let initialState: LineState
    }

    private struct CacheValue {
        let tokens: [Token]
        let endState: LineState
    }

    private struct Token {
        let kind: TokenKind
        let range: NSRange
    }

    private var lineCache: [CacheKey: CacheValue] = [:]

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = clampedRange(range, in: nsText, fallback: fullRange)
        let scanRange = range == nil ? highlightRange : lineBoundedScanRange(for: characterScanRange(for: highlightRange, in: nsText), in: nsText)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var state = range == nil ? LineState.normal : lineStateBefore(scanRange.location, in: nsText)
        var lineLocation = scanRange.location
        let scanEnd = min(NSMaxRange(scanRange), nsText.length)

        while lineLocation < scanEnd {
            let lineRange = NSRange(location: lineLocation, length: lineEnd(in: nsText, at: lineLocation) - lineLocation)
            let cacheValue: CacheValue

            if lineRange.length <= Self.maxCachedLineLength {
                let line = nsText.substring(with: lineRange)
                let cacheKey = CacheKey(text: line, initialState: state)
                if let cached = lineCache[cacheKey] {
                    cacheValue = cached
                } else {
                    cacheValue = jsonTokens(in: line as NSString, initialState: state)
                    lineCache[cacheKey] = cacheValue
                    trimCacheIfNeeded()
                }
            } else {
                let line = nsText.substring(with: lineRange)
                cacheValue = jsonTokens(in: line as NSString, initialState: state)
            }

            for token in cacheValue.tokens {
                let absoluteRange = NSRange(location: lineRange.location + token.range.location, length: token.range.length)
                apply(token.kind, absoluteRange: absoluteRange, visibleIn: highlightRange, to: storage)
            }

            state = cacheValue.endState
            lineLocation = NSMaxRange(lineRange)
        }
    }

    private func clampedRange(_ range: NSRange?, in text: NSString, fallback: NSRange) -> NSRange {
        guard let range,
              range.location != NSNotFound,
              range.location <= text.length else {
            return fallback
        }

        let length = min(range.length, text.length - range.location)
        return NSRange(location: range.location, length: length)
    }

    private func characterScanRange(for range: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }

        let start = max(range.location - Self.contextualScanExpansion, 0)
        let end = min(NSMaxRange(range) + Self.contextualScanExpansion, text.length)
        return NSRange(location: start, length: end - start)
    }

    private func lineBoundedScanRange(for range: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }

        let startLocation = min(max(range.location, 0), text.length)
        let endLocation = min(max(NSMaxRange(range), startLocation), text.length)
        let startLine = text.lineRange(for: NSRange(location: startLocation, length: 0))
        let endLine = text.lineRange(for: NSRange(location: endLocation, length: 0))
        let start = startLine.location
        let end = max(NSMaxRange(endLine), start)
        return NSRange(location: start, length: min(end, text.length) - start)
    }

    private func lineStateBefore(_ location: Int, in text: NSString) -> LineState {
        guard location > 0 else { return .normal }

        let searchStart = max(location - 65_536, 0)
        let searchRange = NSRange(location: searchStart, length: location - searchStart)
        let lastBlockStart = text.range(of: "/*", options: [.backwards], range: searchRange)
        guard lastBlockStart.location != NSNotFound else { return .normal }

        let lastBlockEnd = text.range(of: "*/", options: [.backwards], range: searchRange)
        if lastBlockEnd.location == NSNotFound {
            return .blockComment
        }
        return lastBlockStart.location > lastBlockEnd.location ? .blockComment : .normal
    }

    private func jsonTokens(in text: NSString, initialState: LineState) -> CacheValue {
        var tokens: [Token] = []
        var index = 0
        var state = initialState

        if state == .blockComment {
            let end = blockCommentEnd(in: text, searchingFrom: index)
            tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end.location - index)))
            index = end.location
            state = end.state
        }

        while index < text.length {
            let ch = text.character(at: index)

            if index + 1 < text.length, ch == 47, text.character(at: index + 1) == 47 {
                let end = text.length
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end - index)))
                break
            }

            if index + 1 < text.length, ch == 47, text.character(at: index + 1) == 42 {
                let end = blockCommentEnd(in: text, searchingFrom: index + 2)
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end.location - index)))
                index = end.location
                state = end.state
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

        return CacheValue(tokens: tokens, endState: state)
    }

    private func apply(
        _ kind: TokenKind,
        absoluteRange: NSRange,
        visibleIn highlightRange: NSRange,
        to storage: NSMutableAttributedString
    ) {
        let visibleRange = NSIntersectionRange(absoluteRange, highlightRange)
        guard visibleRange.length > 0 else { return }

        switch kind {
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

    private func blockCommentEnd(in text: NSString, searchingFrom index: Int) -> (location: Int, state: LineState) {
        let searchStart = min(index, text.length)
        let searchRange = NSRange(location: searchStart, length: text.length - searchStart)
        let endRange = text.range(of: "*/", options: [], range: searchRange)
        if endRange.location == NSNotFound {
            return (text.length, .blockComment)
        }
        return (endRange.location + 2, .normal)
    }

    private func trimCacheIfNeeded() {
        if lineCache.count > Self.maxCachedLines {
            lineCache.removeAll(keepingCapacity: true)
        }
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

    private static let levels: Set<String> = [
        "trace", "debug", "info", "notice", "warn", "warning", "error", "err",
        "critical", "fatal", "panic"
    ]

    func apply(to storage: NSMutableAttributedString, text: String, in range: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let nsText = text as NSString
        let highlightRange = highlightedRange(for: range, in: nsText, fallback: fullRange)

        storage.setAttributes(theme.baseAttributes, range: highlightRange)

        var lineLocation = highlightRange.location
        let scanEnd = NSMaxRange(highlightRange)
        while lineLocation < scanEnd {
            let lineRange = NSRange(location: lineLocation, length: lineEnd(in: nsText, at: lineLocation) - lineLocation)
            scanLine(in: nsText, lineRange: lineRange, visibleRange: highlightRange, storage: storage)
            lineLocation = NSMaxRange(lineRange)
        }
    }

    private func scanLine(in text: NSString, lineRange: NSRange, visibleRange: NSRange, storage: NSMutableAttributedString) {
        let first = firstCodeCharacter(in: text, lineRange: lineRange)
        let end = NSMaxRange(lineRange)
        if isStackTraceLine(in: text, firstCodeCharacter: first, lineEnd: end) {
            applyAttributes(theme.commentAttributes, range: lineRange, visibleIn: visibleRange, to: storage)
            return
        }

        if let timestampRange = timestampRange(in: text, lineRange: lineRange) {
            applyAttributes(theme.commandAttributes, range: timestampRange, visibleIn: visibleRange, to: storage)
        }

        var index = lineRange.location
        while index < end {
            let ch = text.character(at: index)
            if ch == 10 || ch == 13 { break }
            if ch == 34 || ch == 39 {
                let tokenEnd = quotedStringEnd(in: text, startingAt: index, quote: ch, lineEnd: end)
                applyAttributes(theme.stringAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                index = tokenEnd
                continue
            }
            if ch == 91 {
                let tokenEnd = bracketContextEnd(in: text, startingAt: index, lineEnd: end)
                if tokenEnd > index {
                    applyAttributes(theme.variableAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                    index = tokenEnd
                    continue
                }
            }
            if isIdentifierStart(ch) {
                let tokenEnd = logWordEnd(in: text, startingAt: index, lineEnd: end)
                let word = text.substring(with: NSRange(location: index, length: tokenEnd - index))
                let lower = word.lowercased()
                if Self.levels.contains(lower) {
                    applyAttributes(theme.keywordAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                } else {
                    var probe = tokenEnd
                    while probe < end, isWhitespace(text.character(at: probe)) {
                        probe += 1
                    }
                    if probe < end, text.character(at: probe) == 61 {
                        applyAttributes(theme.variableAttributes, range: NSRange(location: index, length: tokenEnd - index), visibleIn: visibleRange, to: storage)
                    }
                }
                index = tokenEnd
                continue
            }
            index += 1
        }
    }

    private func isStackTraceLine(in text: NSString, firstCodeCharacter: Int, lineEnd: Int) -> Bool {
        guard firstCodeCharacter < lineEnd else { return false }
        let line = text.substring(with: NSRange(location: firstCodeCharacter, length: lineEnd - firstCodeCharacter))
        return line.hasPrefix("at ")
            || line.hasPrefix("File ")
            || line.hasPrefix("Caused by:")
            || line.hasPrefix("Traceback")
    }

    private func timestampRange(in text: NSString, lineRange: NSRange) -> NSRange? {
        let start = firstCodeCharacter(in: text, lineRange: lineRange)
        let end = NSMaxRange(lineRange)
        if start + 19 <= end,
           isDigitRun(in: text, start: start, count: 4),
           text.character(at: start + 4) == 45,
           isDigitRun(in: text, start: start + 5, count: 2),
           text.character(at: start + 7) == 45,
           isDigitRun(in: text, start: start + 8, count: 2),
           (text.character(at: start + 10) == 32 || text.character(at: start + 10) == 84),
           isTime(in: text, start: start + 11, end: end) {
            return NSRange(location: start, length: timestampEnd(in: text, startingAt: start + 19, lineEnd: end) - start)
        }
        if start + 8 <= end, isTime(in: text, start: start, end: end) {
            return NSRange(location: start, length: timestampEnd(in: text, startingAt: start + 8, lineEnd: end) - start)
        }
        if start + 15 <= end {
            let month = text.substring(with: NSRange(location: start, length: min(3, end - start)))
            if ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].contains(month) {
                var cursor = start + 3
                while cursor < end, isWhitespace(text.character(at: cursor)) { cursor += 1 }
                while cursor < end, isDigit(text.character(at: cursor)) { cursor += 1 }
                while cursor < end, isWhitespace(text.character(at: cursor)) { cursor += 1 }
                if isTime(in: text, start: cursor, end: end) {
                    return NSRange(location: start, length: min(cursor + 8, end) - start)
                }
            }
        }
        return nil
    }

    private func timestampEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        var cursor = index
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isDigit(ch) || ch == 46 || ch == 44 || ch == 90 || ch == 43 || ch == 45 || ch == 58 {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
    }

    private func isTime(in text: NSString, start: Int, end: Int) -> Bool {
        start + 8 <= end
            && isDigitRun(in: text, start: start, count: 2)
            && text.character(at: start + 2) == 58
            && isDigitRun(in: text, start: start + 3, count: 2)
            && text.character(at: start + 5) == 58
            && isDigitRun(in: text, start: start + 6, count: 2)
    }

    private func isDigitRun(in text: NSString, start: Int, count: Int) -> Bool {
        guard start + count <= text.length else { return false }
        for offset in 0..<count where !isDigit(text.character(at: start + offset)) {
            return false
        }
        return true
    }

    private func bracketContextEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        var cursor = index + 1
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if ch == 93 {
                return cursor + 1
            }
            if !(isIdentifierCharacter(ch) || ch == 46 || ch == 58 || ch == 47 || ch == 35 || ch == 45) {
                return index
            }
            cursor += 1
        }
        return index
    }

    private func logWordEnd(in text: NSString, startingAt index: Int, lineEnd: Int) -> Int {
        var cursor = index
        while cursor < lineEnd {
            let ch = text.character(at: cursor)
            if isIdentifierCharacter(ch) || ch == 46 || ch == 45 {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
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
