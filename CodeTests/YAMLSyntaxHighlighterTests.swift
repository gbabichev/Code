//
//  YAMLSyntaxHighlighterTests.swift
//  CodeTests
//

import AppKit
import XCTest
@testable import Code

final class YAMLSyntaxHighlighterTests: XCTestCase {
    @MainActor
    func testCommonYAMLTokensAreHighlighted() {
        let text = """
        ---
        service: &defaults
          enabled: true
          retries: 3
          image: "nginx:latest" # pinned image
          command: |
            echo hello
        copy: *defaults
        """
        let theme = Self.theme
        let storage = NSMutableAttributedString(string: text, attributes: theme.baseAttributes)

        YAMLSyntaxHighlighter(theme: theme).apply(to: storage, text: text, in: nil)

        assertColor(theme.keywordColor, for: "---", in: text, storage: storage)
        assertColor(theme.variableColor, for: "service", in: text, storage: storage)
        assertColor(theme.builtinColor, for: "&defaults", in: text, storage: storage)
        assertColor(theme.builtinColor, for: "true", in: text, storage: storage)
        assertColor(theme.builtinColor, for: "3", in: text, storage: storage)
        assertColor(theme.stringColor, for: "\"nginx:latest\"", in: text, storage: storage)
        assertColor(theme.commentColor, for: "# pinned image", in: text, storage: storage)
        assertColor(theme.stringColor, for: "echo hello", in: text, storage: storage)
        assertColor(theme.builtinColor, for: "*defaults", in: text, storage: storage)
    }

    func testYAMLExtensionsAreDetected() {
        XCTAssertEqual(EditorLanguage.infer(from: URL(fileURLWithPath: "/tmp/config.yaml")), .yaml)
        XCTAssertEqual(EditorLanguage.infer(from: URL(fileURLWithPath: "/tmp/config.yml")), .yaml)
    }

    @MainActor
    private static var theme: SkinTheme {
        SkinDefinition(
            id: "yaml-test",
            name: "YAML Test",
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
            for: .yaml,
            editorFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            semiboldFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        )
    }

    @MainActor
    private func assertColor(
        _ expected: NSColor,
        for needle: String,
        in text: String,
        storage: NSMutableAttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (text as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }
        for location in range.location..<NSMaxRange(range) {
            let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
            XCTAssertTrue(color?.isEqual(expected) == true, "Unexpected color for \(needle)", file: file, line: line)
        }
    }
}
