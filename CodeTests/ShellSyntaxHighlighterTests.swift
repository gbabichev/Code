//
//  ShellSyntaxHighlighterTests.swift
//  CodeTests
//

import AppKit
import XCTest
@testable import Code

final class ShellSyntaxHighlighterTests: XCTestCase {
    @MainActor
    func testQuotedAssignmentValuesHighlightThroughSpaces() {
        let text = #"""
        declare -A labels=(
          [single]="single quoted"
          [double]="double quoted"
          [ansi]="ansi-c quoted"
        )

        test="this is a test"
        ansi=$'single quote: \' and space'
        """#
        let highlighter = ShellSyntaxHighlighter(theme: Self.theme)
        let storage = Self.makeStorage(for: text)

        highlighter.apply(to: storage, text: text, in: nil)

        assertStringColor(#""single quoted""#, in: text, storage: storage)
        assertStringColor(#""double quoted""#, in: text, storage: storage)
        assertStringColor(#""ansi-c quoted""#, in: text, storage: storage)
        assertStringColor(#""this is a test""#, in: text, storage: storage)
        assertStringColor(#"$'single quote: \' and space'"#, in: text, storage: storage)
    }

    @MainActor
    private static var theme: SkinTheme {
        SkinDefinition(
            id: "shell-test",
            name: "Shell Test",
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
            for: .shell,
            editorFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            semiboldFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        )
    }

    @MainActor
    private static func makeStorage(for text: String) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: text,
            attributes: theme.baseAttributes
        )
    }

    @MainActor
    private func assertStringColor(
        _ needle: String,
        in text: String,
        storage: NSMutableAttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (text as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing test range \(needle)", file: file, line: line)
        guard range.location != NSNotFound else { return }

        for location in range.location..<NSMaxRange(range) {
            let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
            XCTAssertTrue(
                color?.isEqual(Self.theme.stringColor) == true,
                "Expected string color for \(needle) at UTF-16 offset \(location)",
                file: file,
                line: line
            )
        }
    }
}
