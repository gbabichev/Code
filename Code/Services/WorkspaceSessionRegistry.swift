//
//  WorkspaceSessionRegistry.swift
//  Code
//
//  Created by Codex on 4/5/26.
//

import Combine
import Foundation

@MainActor
final class WorkspaceSessionRegistry: ObservableObject {
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private var didConsumeLaunchRestore = false

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func makeSceneBootstrapSessionID() -> String {
        resolveSessionID(storedSessionID: nil)
    }

    func resolveSessionID(storedSessionID: String?) -> String {
        if let storedSessionID, !storedSessionID.isEmpty {
            register(sessionID: storedSessionID)
            return storedSessionID
        }

        if !didConsumeLaunchRestore,
           let lastSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
           SessionStore(sessionID: lastSessionID, fileManager: fileManager).hasSavedSession {
            didConsumeLaunchRestore = true
            register(sessionID: lastSessionID)
            return lastSessionID
        }

        let sessionID = UUID().uuidString
        register(sessionID: sessionID)
        return sessionID
    }

    func markFocused(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        register(sessionID: sessionID)
    }

    private func register(sessionID: String) {
        userDefaults.set(sessionID, forKey: Keys.lastFocusedSessionID)
    }
}

private enum Keys {
    static let lastFocusedSessionID = "workspace.lastFocusedSessionID"
}
