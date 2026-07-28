//
//  IndentationAnalyzerTests.swift
//  CodeTests
//

import XCTest
@testable import Code

final class IndentationAnalyzerTests: XCTestCase {
    func testFourSpaceIndentationSurvivesSingleAlignmentOutlier() {
        let text = ([
            "def convert():",
            "    try:",
            "        encode()",
            "    data = {'fileName': name,",
            "            'runtime': runtime,",
            "               }"
        ] + Array(repeating: "    process()", count: 20))
            .joined(separator: "\n")

        let settings = IndentationAnalyzer.inferSettings(in: text, fallbackWidth: 4)

        XCTAssertEqual(settings.style, .spaces)
        XCTAssertEqual(settings.width, 4)
        XCTAssertTrue(settings.isInferred)
        XCTAssertFalse(settings.hasUnevenIndentation)
    }

    func testTwoSpaceIndentationWinsOverMoreCommonNestedFourSpaceLines() {
        let text = ([
            "if ready {",
            "  if enabled {"
        ] + Array(repeating: "    run()", count: 20) + [
            "  }",
            "}"
        ]).joined(separator: "\n")

        let settings = IndentationAnalyzer.inferSettings(in: text, fallbackWidth: 4)

        XCTAssertEqual(settings.width, 2)
        XCTAssertFalse(settings.hasUnevenIndentation)
    }

    func testOneSpaceIndentationIsStillDetectedWhenDirectlyObserved() {
        let text = """
        if ready:
         if enabled:
          run()
        """

        let settings = IndentationAnalyzer.inferSettings(in: text, fallbackWidth: 4)

        XCTAssertEqual(settings.width, 1)
        XCTAssertFalse(settings.hasUnevenIndentation)
    }

    func testFallbackWinsWhenOnlyNestedIndentationLevelsArePresent() {
        let text = "        first()\n            second()"

        let settings = IndentationAnalyzer.inferSettings(in: text, fallbackWidth: 4)

        XCTAssertEqual(settings.width, 4)
    }

    func testExplicitSpaceWidthReportsAndFixesUnevenIndentation() {
        let text = "if ready:\n   run()"
        let settings = IndentationAnalyzer.explicitSettings(
            style: .spaces,
            width: 4,
            in: text
        )

        XCTAssertTrue(settings.hasUnevenIndentation)
        XCTAssertEqual(
            IndentationAnalyzer.normalizedContent(text, using: settings),
            "if ready:\n    run()"
        )
    }
}
