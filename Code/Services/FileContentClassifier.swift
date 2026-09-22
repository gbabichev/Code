//
//  FileContentClassifier.swift
//  Code
//

import Foundation

enum FileContentClassifier {
    static let sampleByteCount = 8_192

    static func isLikelyBinary(_ data: Data) -> Bool {
        let sample = data.prefix(sampleByteCount)
        guard !sample.isEmpty else { return false }

        if hasUnicodeByteOrderMark(sample) {
            return false
        }

        if sample.contains(0) {
            return true
        }

        guard String(data: sample, encoding: .utf8) != nil else {
            return true
        }

        let controlByteCount = sample.reduce(into: 0) { count, byte in
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F {
                count += 1
            }
        }

        return controlByteCount * 100 > sample.count
    }

    private static func hasUnicodeByteOrderMark(_ data: Data.SubSequence) -> Bool {
        let bytes = Array(data.prefix(4))

        return bytes.starts(with: [0xEF, 0xBB, 0xBF])
            || bytes.starts(with: [0xFF, 0xFE])
            || bytes.starts(with: [0xFE, 0xFF])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
    }
}
