//
//  IndentationAnalyzer.swift
//  Code
//

import Foundation

enum IndentationAnalyzer {
    static func inferSettings(in text: String, fallbackWidth: Int) -> EditorIndentationSettings {
        let fallbackWidth = clampedWidth(fallbackWidth)
        let analysis = indentationAnalysis(in: text)

        let inferredStyle: EditorIndentationStyle
        if analysis.spaceOnlyLineCount == 0
            && analysis.tabOnlyLineCount == 0
            && analysis.mixedLineCount == 0 {
            inferredStyle = .spaces
        } else if analysis.tabOnlyLineCount > analysis.spaceOnlyLineCount {
            inferredStyle = .tabs
        } else {
            inferredStyle = .spaces
        }

        let width = inferredSpaceWidth(from: analysis.spaceOnlyIndentCounts, fallbackWidth: fallbackWidth)

        return EditorIndentationSettings(
            style: inferredStyle,
            width: width,
            isInferred: analysis.hasEvidence,
            hasMixedIndentation: analysis.hasMixedIndentation,
            hasUnevenIndentation: analysis.hasUnevenIndentation(
                style: inferredStyle,
                width: width,
                toleratedOutlierCount: outlierTolerance(forSampleCount: analysis.spaceOnlyIndentCounts.count)
            )
        )
    }

    static func explicitSettings(
        style: EditorIndentationStyle,
        width: Int,
        in text: String
    ) -> EditorIndentationSettings {
        let width = clampedWidth(width)
        let analysis = indentationAnalysis(in: text)

        return EditorIndentationSettings(
            style: style,
            width: width,
            isInferred: false,
            hasMixedIndentation: analysis.hasMixedIndentation,
            hasUnevenIndentation: analysis.hasUnevenIndentation(
                style: style,
                width: width,
                toleratedOutlierCount: 0
            )
        )
    }

    static func normalizedContent(_ text: String, using settings: EditorIndentationSettings) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizedLine(String($0), using: settings) }
            .joined(separator: "\n")
    }

    private static func normalizedLine(_ line: String, using settings: EditorIndentationSettings) -> String {
        let prefix = leadingIndentation(in: line[...])
        guard !prefix.isEmpty else { return line }

        let columns = indentationColumnCount(in: prefix, tabWidth: settings.width)
        let normalizedColumns: Int
        switch settings.style {
        case .spaces:
            let roundedLevel = Int((Double(columns) / Double(settings.width)).rounded())
            normalizedColumns = max(roundedLevel, 1) * settings.width
        case .tabs:
            normalizedColumns = columns
        }
        let replacement = indentationPrefix(forColumnCount: normalizedColumns, using: settings)
        return replacement + line[prefix.endIndex...]
    }

    private static func leadingIndentation(in line: Substring) -> Substring {
        let end = line.firstIndex { character in
            character != " " && character != "\t"
        } ?? line.endIndex
        return line[..<end]
    }

    private static func indentationAnalysis(in text: String) -> IndentationAnalysis {
        var analysis = IndentationAnalysis()

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let prefix = leadingIndentation(in: Substring(line))
            guard !prefix.isEmpty,
                  line[prefix.endIndex...].contains(where: { !$0.isWhitespace }) else { continue }

            let hasSpaces = prefix.contains(" ")
            let hasTabs = prefix.contains("\t")

            if hasSpaces && hasTabs {
                analysis.mixedLineCount += 1
            } else if hasTabs {
                analysis.tabOnlyLineCount += 1
            } else if hasSpaces {
                analysis.spaceOnlyLineCount += 1
                analysis.spaceOnlyIndentCounts.append(prefix.count)
            }
        }

        return analysis
    }

    private static func indentationColumnCount(in prefix: Substring, tabWidth: Int) -> Int {
        let tabWidth = clampedWidth(tabWidth)
        var columns = 0

        for character in prefix {
            if character == "\t" {
                let remainder = columns % tabWidth
                columns += remainder == 0 ? tabWidth : tabWidth - remainder
            } else {
                columns += 1
            }
        }

        return columns
    }

    private static func indentationPrefix(
        forColumnCount columns: Int,
        using settings: EditorIndentationSettings
    ) -> String {
        switch settings.style {
        case .spaces:
            return String(repeating: " ", count: max(columns, 0))
        case .tabs:
            let tabCount = max(columns, 0) / settings.width
            let spaceCount = max(columns, 0) % settings.width
            return String(repeating: "\t", count: tabCount)
                + String(repeating: " ", count: spaceCount)
        }
    }

    private static func inferredSpaceWidth(from counts: [Int], fallbackWidth: Int) -> Int {
        guard !counts.isEmpty else { return fallbackWidth }

        let candidates = Array(EditorIndentationSettings.minimumWidth...EditorIndentationSettings.maximumWidth)
        let scored = candidates.map { candidate in
            let divisibleCount = counts.filter { $0 % candidate == 0 }.count
            let exactCount = counts.filter { $0 == candidate }.count
            let remainderPenalty = counts.reduce(0) { $0 + ($1 % candidate) }
            return (
                candidate: candidate,
                divisibleCount: divisibleCount,
                exactCount: exactCount,
                remainderPenalty: remainderPenalty
            )
        }

        let maximumDivisibleCount = scored.map { $0.divisibleCount }.max() ?? 0
        let outlierTolerance = outlierTolerance(forSampleCount: counts.count)
        let viableScores = scored.filter {
            $0.divisibleCount >= maximumDivisibleCount - outlierTolerance
        }

        // Prefer the smallest viable width that occurs directly or matches the user's
        // fallback. A real indent unit normally appears on at least one line, while
        // larger values are nested levels. Allowing a small number of outliers keeps
        // aligned continuation lines from making width 1 win automatically.
        var preferredWidths = viableScores
            .filter { score in score.exactCount > 0 }
            .map { score in score.candidate }
        if viableScores.contains(where: { $0.candidate == fallbackWidth }) {
            preferredWidths.append(fallbackWidth)
        }
        if let preferredWidth = preferredWidths.min() {
            return preferredWidth
        }

        return viableScores.max { lhs, rhs in
            if lhs.divisibleCount != rhs.divisibleCount {
                return lhs.divisibleCount < rhs.divisibleCount
            }
            if lhs.remainderPenalty != rhs.remainderPenalty {
                return lhs.remainderPenalty > rhs.remainderPenalty
            }
            return lhs.candidate < rhs.candidate
        }?.candidate ?? fallbackWidth
    }

    private static func outlierTolerance(forSampleCount count: Int) -> Int {
        max(1, count / 20)
    }

    private static func clampedWidth(_ width: Int) -> Int {
        min(
            max(width, EditorIndentationSettings.minimumWidth),
            EditorIndentationSettings.maximumWidth
        )
    }

    private struct IndentationAnalysis {
        var spaceOnlyIndentCounts: [Int] = []
        var spaceOnlyLineCount = 0
        var tabOnlyLineCount = 0
        var mixedLineCount = 0

        var hasEvidence: Bool {
            spaceOnlyLineCount > 0 || tabOnlyLineCount > 0 || mixedLineCount > 0
        }

        var hasMixedIndentation: Bool {
            mixedLineCount > 0 || (spaceOnlyLineCount > 0 && tabOnlyLineCount > 0)
        }

        func hasUnevenIndentation(
            style: EditorIndentationStyle,
            width: Int,
            toleratedOutlierCount: Int
        ) -> Bool {
            guard style == .spaces else { return false }
            let unevenCount = spaceOnlyIndentCounts.count { $0 % width != 0 }
            return unevenCount > toleratedOutlierCount
        }
    }
}
