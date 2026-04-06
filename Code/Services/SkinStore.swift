//
//  SkinStore.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import AppKit
import Foundation

struct SkinStore {
    private let fileManager: FileManager
    private let skinsDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL
            .appendingPathComponent("Basic Editor", isDirectory: true)
            .appendingPathComponent("Skins", isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        self.skinsDirectoryURL = directoryURL
    }

    func loadSkins() -> [SkinDefinition] {
        var skinsByID: [String: SkinDefinition] = [:]

        for url in bundledSkinURLs() {
            if let skin = decodeSkin(at: url) {
                skinsByID[skin.id] = skin
            }
        }

        for url in userSkinURLs() {
            if let skin = decodeSkin(at: url) {
                skinsByID[skin.id] = skin
            }
        }

        return skinsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func importSkin(from sourceURL: URL) throws -> SkinDefinition {
        let skin = try decodeRequiredSkin(at: sourceURL)
        let destinationURL = skinsDirectoryURL.appendingPathComponent("\(skin.id).json")
        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return skin
    }

    func exportSkin(_ skin: SkinDefinition, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(skin)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func bundledSkinURLs() -> [URL] {
        let nestedURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Skins") ?? []
        let rootURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let allURLs = nestedURLs + rootURLs

        return Array(Set(allURLs)).sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func userSkinURLs() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: skinsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "json" } ?? []
    }

    private func decodeSkin(at url: URL) -> SkinDefinition? {
        try? decodeRequiredSkin(at: url)
    }

    private func decodeRequiredSkin(at url: URL) throws -> SkinDefinition {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(SkinDefinition.self, from: data)
    }
}
