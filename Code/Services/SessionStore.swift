//
//  SessionStore.swift
//  Code
//

import Foundation

struct SessionStore {
    private let fileManager: FileManager
    private let sessionURL: URL

    init(sessionID: String? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL.appendingPathComponent("Code", isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        if let sessionID {
            let sessionsDirectoryURL = directoryURL.appendingPathComponent("Sessions", isDirectory: true)
            if !fileManager.fileExists(atPath: sessionsDirectoryURL.path(percentEncoded: false)) {
                try? fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
            }
            self.sessionURL = sessionsDirectoryURL.appendingPathComponent("\(sessionID).json")
        } else {
            self.sessionURL = directoryURL.appendingPathComponent("Session.json")
        }
    }

    func load() -> EditorSessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL) else {
            return nil
        }

        return try? JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
    }

    var hasSavedSession: Bool {
        fileManager.fileExists(atPath: sessionURL.path(percentEncoded: false))
    }

    func save(_ snapshot: EditorSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: sessionURL, options: .atomic)
    }

    static func savedSessions(fileManager: FileManager = .default) -> [(id: String, modificationDate: Date)] {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sessionsDirectoryURL = appSupportURL
            .appendingPathComponent("Code", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        let urls = (try? fileManager.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modificationDate = values?.contentModificationDate ?? .distantPast
            return (id: id, modificationDate: modificationDate)
        }
    }
}
