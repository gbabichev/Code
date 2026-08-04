//
//  SyntaxHighlighterCorrectnessTests.swift
//  CodeTests
//

import AppKit
import XCTest
@testable import Code

final class SyntaxHighlighterCorrectnessTests: XCTestCase {
    @MainActor
    func testMarkdownFenceRequiresMatchingDelimiterLength() {
        let text = """
        ````
        first
        ```
        still fenced
        ````
        plain text
        """

        assertColor(\SkinTheme.stringColor, for: "still fenced", in: text, language: .markdown)
        assertColor(\SkinTheme.baseColor, for: "plain text", in: text, language: .markdown)
    }

    @MainActor
    func testShellSpecialParametersAreVariables() {
        let text = "printf '%s' $? $@ $1 $$"

        assertColor(\SkinTheme.variableColor, for: "$?", in: text, language: .shell)
        assertColor(\SkinTheme.variableColor, for: "$@", in: text, language: .shell)
        assertColor(\SkinTheme.variableColor, for: "$1", in: text, language: .shell)
        assertColor(\SkinTheme.variableColor, for: "$$", in: text, language: .shell)
    }

    @MainActor
    func testDotEnvCommentOffsetUsesUTF16Coordinates() {
        let text = "VALUE=😀 # comment"

        assertColor(\SkinTheme.stringColor, for: "😀 ", in: text, language: .dotenv)
        assertColor(\SkinTheme.commentColor, for: "# comment", in: text, language: .dotenv)
    }

    @MainActor
    func testPythonCompleteBuiltinSetIncludesModernAndPreviouslyMissingNames() {
        let text = "memoryview(data); aiter(items); __import__('module')"

        assertColor(\SkinTheme.builtinColor, for: "memoryview", in: text, language: .python)
        assertColor(\SkinTheme.builtinColor, for: "aiter", in: text, language: .python)
        assertColor(\SkinTheme.builtinColor, for: "__import__", in: text, language: .python)
    }

    @MainActor
    func testPowerShellEscapesAndLiteralVariables() {
        let text = #"""
        $message = "quoted: `" # still a string"
        $literal = 'can''t # still a string'
        $enabled = $true
        """#

        assertColor(\SkinTheme.stringColor, for: #""quoted: `" # still a string""#, in: text, language: .powerShell)
        assertColor(\SkinTheme.stringColor, for: #"'can''t # still a string'"#, in: text, language: .powerShell)
        assertColor(\SkinTheme.builtinColor, for: "$true", in: text, language: .powerShell)
    }

    @MainActor
    func testPowerShellHereStringOnlyClosesAtLineStart() {
        let text = #"""
        $message = @"
        body
        embedded "@ does not close
        "@
        Write-Host $message
        """#

        assertColor(\SkinTheme.stringColor, for: "does not close", in: text, language: .powerShell)
        assertColor(\SkinTheme.builtinColor, for: "Write-Host", in: text, language: .powerShell)
    }

    @MainActor
    func testQuotedYAMLKeysKeepKeyColor() {
        let text = #"""
        "true": false
        'display name': value
        """#

        assertColor(\SkinTheme.variableColor, for: #""true""#, in: text, language: .yaml)
        assertColor(\SkinTheme.variableColor, for: "'display name'", in: text, language: .yaml)
        assertColor(\SkinTheme.builtinColor, for: "false", in: text, language: .yaml)
    }

    @MainActor
    func testBracketedLogLevelUsesLevelColor() {
        let text = "2026-08-04T12:34:56Z [ERROR] request failed"

        assertColor(\SkinTheme.keywordColor, for: "[ERROR]", in: text, language: .logfile)
    }

    @MainActor
    func testCarriageReturnOnlyFilesHighlightEveryLine() {
        let text = "INFO first\rERROR second"

        assertColor(\SkinTheme.keywordColor, for: "ERROR", in: text, language: .logfile)
    }

    @MainActor
    private func assertColor(
        _ color: KeyPath<SkinTheme, NSColor>,
        for needle: String,
        in text: String,
        language: EditorLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let theme = Self.theme(for: language)
        let storage = NSMutableAttributedString(string: text, attributes: theme.baseAttributes)
        Self.highlighter(for: language, theme: theme).apply(to: storage, text: text, in: nil)

        let range = (text as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing test range \(needle)", file: file, line: line)
        guard range.location != NSNotFound else { return }

        for location in range.location..<NSMaxRange(range) {
            let actual = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
            XCTAssertTrue(
                actual?.isEqual(theme[keyPath: color]) == true,
                "Unexpected color for \(needle) at UTF-16 offset \(location)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private static func theme(for language: EditorLanguage) -> SkinTheme {
        skin.makeTheme(for: language, editorFont: editorFont, semiboldFont: semiboldFont)
    }

    @MainActor
    private static func highlighter(for language: EditorLanguage, theme: SkinTheme) -> SyntaxHighlighting {
        switch language {
        case .plainText: PlainTextHighlighter(theme: theme)
        case .logfile: LogfileSyntaxHighlighter(theme: theme)
        case .markdown: MarkdownSyntaxHighlighter(theme: theme)
        case .shell: ShellSyntaxHighlighter(theme: theme)
        case .dotenv: DotEnvSyntaxHighlighter(theme: theme)
        case .python: PythonSyntaxHighlighter(theme: theme)
        case .powerShell: PowerShellSyntaxHighlighter(theme: theme)
        case .xml: XMLSyntaxHighlighter(theme: theme)
        case .json: JSONSyntaxHighlighter(theme: theme)
        case .yaml: YAMLSyntaxHighlighter(theme: theme)
        }
    }

    @MainActor
    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @MainActor
    private static let semiboldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    private static let skin = SkinDefinition(
        id: "syntax-correctness-test",
        name: "Syntax Correctness Test",
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
    )
}
