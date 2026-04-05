//
//  SessionStore.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import Foundation

struct SessionStore {
    private let sessionURL: URL

    init(fileManager: FileManager = .default) {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL.appendingPathComponent("Basic Editor", isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        self.sessionURL = directoryURL.appendingPathComponent("Session.json")
    }

    func load() -> EditorSessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL) else {
            return nil
        }

        return try? JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
    }

    func save(_ snapshot: EditorSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: sessionURL, options: .atomic)
    }
}
