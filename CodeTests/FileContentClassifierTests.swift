//
//  FileContentClassifierTests.swift
//  CodeTests
//

import XCTest
@testable import Code

final class FileContentClassifierTests: XCTestCase {
    func testSRTContentIsText() {
        let data = Data("""
        1
        00:00:01,000 --> 00:00:03,000
        This subtitle is text.

        """.utf8)

        XCTAssertFalse(FileContentClassifier.isLikelyBinary(data))
    }

    func testBinaryContentIsDetected() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])

        XCTAssertTrue(FileContentClassifier.isLikelyBinary(data))
    }

    func testUTF16ContentWithByteOrderMarkIsText() {
        let data = "Subtitle".data(using: .utf16)!

        XCTAssertFalse(FileContentClassifier.isLikelyBinary(data))
    }
}
