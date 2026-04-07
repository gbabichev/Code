//
//  WorkspaceSessionRegistry.swift
//  Code
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
        if !didConsumeLaunchRestore,
           let lastSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
           SessionStore(sessionID: lastSessionID, fileManager: fileManager).hasSavedSession {
            didConsumeLaunchRestore = true
            return lastSessionID
        }

        return UUID().uuidString
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
