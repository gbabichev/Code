//
//  SyntaxHighlighterPerformanceTests.swift
//  CodeTests
//

import AppKit
import XCTest
@testable import Code

final class SyntaxHighlighterPerformanceTests: XCTestCase {
    private struct Fixture {
        let language: EditorLanguage
        let text: String
        let ranges: [NSRange]
    }

    @MainActor
    private static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    @MainActor
    private static var semiboldFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    }
    private static let skin = SkinDefinition(
        id: "performance-test",
        name: "Performance Test",
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

    @MainActor
    func testLargeJSONViewportHighlightingPerformance() {
        let fixture = Fixture(language: .json, text: Self.makeLargeJSON(minimumBytes: 2_500_000), ranges: [])
        let ranges = Self.viewportRanges(in: fixture.text, length: 24_000)
        let highlighter = Self.makeHighlighter(for: fixture.language)
        let storage = Self.makeStorage(for: fixture.text)

        highlighter.apply(to: storage, text: fixture.text, in: ranges[0])

        measure(metrics: [XCTClockMetric()]) {
            for range in ranges {
                highlighter.apply(to: storage, text: fixture.text, in: range)
            }
        }

        XCTAssertEqual(storage.length, (fixture.text as NSString).length)
    }

    @MainActor
    func testLargeJSONEditedRangeHighlightingPerformance() {
        let text = Self.makeLargeJSON(minimumBytes: 2_500_000)
        let nsText = text as NSString
        let editedLocation = max(nsText.length - 320_000, 0)
        let editedRange = NSRange(location: editedLocation, length: min(1_000, nsText.length - editedLocation))
        let highlighter = Self.makeHighlighter(for: .json)
        let storage = Self.makeStorage(for: text)

        highlighter.apply(to: storage, text: text, in: editedRange)

        measure(metrics: [XCTClockMetric()]) {
            highlighter.apply(to: storage, text: text, in: editedRange)
        }

        XCTAssertEqual(storage.length, nsText.length)
    }

    @MainActor
    func testLargeLanguageSetViewportHighlightingPerformance() {
        let fixtures = Self.largeLanguageFixtures()
        let cases = fixtures.map { fixture in
            (
                highlighter: Self.makeHighlighter(for: fixture.language),
                storage: Self.makeStorage(for: fixture.text),
                text: fixture.text,
                ranges: fixture.ranges
            )
        }

        for testCase in cases {
            testCase.highlighter.apply(to: testCase.storage, text: testCase.text, in: testCase.ranges[0])
        }

        measure(metrics: [XCTClockMetric()]) {
            for testCase in cases {
                for range in testCase.ranges {
                    testCase.highlighter.apply(to: testCase.storage, text: testCase.text, in: range)
                }
            }
        }

        for testCase in cases {
            XCTAssertEqual(testCase.storage.length, (testCase.text as NSString).length)
        }
    }

    @MainActor
    private static func makeHighlighter(for language: EditorLanguage) -> SyntaxHighlighting {
        SyntaxHighlighterFactory.makeHighlighter(
            for: language,
            skin: skin,
            editorFont: editorFont,
            semiboldFont: semiboldFont
        )
    }

    @MainActor
    private static func makeStorage(for text: String) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: text,
            attributes: [
                .font: editorFont,
                .foregroundColor: NSColor.textColor
            ]
        )
    }

    private static func viewportRanges(in text: String, length: Int) -> [NSRange] {
        let nsText = text as NSString
        let maxLocation = max(nsText.length - 1, 0)
        let locations = [
            0,
            nsText.length / 4,
            nsText.length / 2,
            min((nsText.length * 3) / 4, maxLocation),
            max(nsText.length - length, 0)
        ]

        return locations.map { location in
            NSRange(location: location, length: min(length, nsText.length - location))
        }
    }

    private static func largeLanguageFixtures() -> [Fixture] {
        [
            Fixture(language: .json, text: makeLargeJSON(minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .python, text: repeatLine("""
            def process_item(index, value):
                if value is None:
                    return f"missing:{index}"
                return value * 2  # keep this branch hot

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .shell, text: repeatLine("""
            for file in "$ROOT"/**/*.swift; do
                echo "checking ${file}" # visible work
                grep -n "TODO" "$file" || true
            done

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .powerShell, text: repeatLine("""
            foreach ($File in Get-ChildItem -Recurse -Filter *.swift) {
                Write-Host "Checking $($File.FullName)"
                $Result = Select-String -Path $File.FullName -Pattern "TODO"
            }

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .xml, text: repeatLine("""
            <record id="123" enabled="true">
                <name>Example</name>
                <value type="number">42</value>
            </record>

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .markdown, text: repeatLine("""
            ## Heading
            - Item with `inline code` and [a link](https://example.com)
            > quoted text

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .dotenv, text: repeatLine("""
            API_URL=https://example.com
            ENABLE_FEATURE=true
            SECRET_VALUE="quoted value"

            """, minimumBytes: 1_200_000), ranges: []),
            Fixture(language: .logfile, text: repeatLine("""
            2026-04-23T12:34:56Z INFO request_id=abc123 path="/api/items" duration_ms=42
            Traceback line ignored by normal parser

            """, minimumBytes: 1_200_000), ranges: [])
        ].map { fixture in
            Fixture(language: fixture.language, text: fixture.text, ranges: viewportRanges(in: fixture.text, length: 18_000))
        }
    }

    private static func makeLargeJSON(minimumBytes: Int) -> String {
        var text = "{\n  \"records\": [\n"
        var index = 0
        while text.utf8.count < minimumBytes {
            text += """
                {
                  "id": "\(index)-44FE409F-8F07-4D41-8022-3D47D1E0A28E",
                  "enabled": \(index % 2 == 0 ? "true" : "false"),
                  "count": \(index),
                  "tags": ["alpha", "beta", "gamma"],
                  "metadata": { "owner": "editor", "status": null }
                },

            """
            index += 1
        }
        text += "    { \"id\": \"tail\", \"enabled\": true }\n  ]\n}\n"
        return text
    }

    private static func repeatLine(_ line: String, minimumBytes: Int) -> String {
        var text = ""
        while text.utf8.count < minimumBytes {
            text += line
        }
        return text
    }
}
