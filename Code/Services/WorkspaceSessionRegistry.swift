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
    private var didScheduleAdditionalLaunchRestore = false
    private var connectedSessionIDs = Set<String>()
    private var pendingLaunchRestoreSessionIDs: [String] = []

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func makeSceneBootstrapSessionID() -> String {
        if let pendingSessionID = consumePendingLaunchRestoreSessionID() {
            return pendingSessionID
        }

        if !didConsumeLaunchRestore,
           let lastSessionID = orderedRestorableSessionIDs().first {
            didConsumeLaunchRestore = true
            return lastSessionID
        }

        return UUID().uuidString
    }

    func handleSceneAppear(
        sessionID: String,
        openAdditionalWindows: @escaping (_ count: Int) -> Void
    ) {
        guard !sessionID.isEmpty else { return }

        connectedSessionIDs.insert(sessionID)
        register(sessionID: sessionID)

        guard !didScheduleAdditionalLaunchRestore else { return }
        didScheduleAdditionalLaunchRestore = true

        // Give SwiftUI scene restoration a moment to recreate any additional windows
        // before fallback restore opens missing ones.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                let existingOrPending = self.connectedSessionIDs.union(self.pendingLaunchRestoreSessionIDs)
                let missingSessionIDs = self.orderedRestorableSessionIDs().filter { !existingOrPending.contains($0) }
                guard !missingSessionIDs.isEmpty else { return }

                self.pendingLaunchRestoreSessionIDs.append(contentsOf: missingSessionIDs)
                openAdditionalWindows(missingSessionIDs.count)
            }
        }
    }

    func handleSceneDisappear(sessionID: String) {
        guard !sessionID.isEmpty else { return }

        connectedSessionIDs.remove(sessionID)
    }

    func handleWindowWillClose(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        guard !ApplicationLifecycleState.shared.isTerminating else { return }

        var sessionIDs = storedRestorableSessionIDs()
        sessionIDs.removeAll { $0 == sessionID }
        userDefaults.set(sessionIDs, forKey: Keys.restorableSessionIDs)
    }

    func markFocused(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        register(sessionID: sessionID)
    }

    private func register(sessionID: String) {
        var sessionIDs = storedRestorableSessionIDs()
        if !sessionIDs.contains(sessionID) {
            sessionIDs.append(sessionID)
            userDefaults.set(sessionIDs, forKey: Keys.restorableSessionIDs)
        }
        userDefaults.set(sessionID, forKey: Keys.lastFocusedSessionID)
    }

    private func orderedRestorableSessionIDs() -> [String] {
        let savedSessions = SessionStore.savedSessions(fileManager: fileManager)
        let availableSessionIDs = storedRestorableSessionIDs().filter {
            SessionStore(sessionID: $0, fileManager: fileManager).hasSavedSession
        }

        if availableSessionIDs != storedRestorableSessionIDs() {
            userDefaults.set(availableSessionIDs, forKey: Keys.restorableSessionIDs)
        }

        if availableSessionIDs.isEmpty {
            return fallbackRestorableSessionIDs(from: savedSessions)
        }

        guard let lastFocusedSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
              availableSessionIDs.contains(lastFocusedSessionID) else {
            return availableSessionIDs
        }

        return [lastFocusedSessionID] + availableSessionIDs.filter { $0 != lastFocusedSessionID }
    }

    private func fallbackRestorableSessionIDs(from savedSessions: [(id: String, modificationDate: Date)]) -> [String] {
        guard !savedSessions.isEmpty else { return [] }

        let sortedSessions = savedSessions.sorted { lhs, rhs in
            if lhs.modificationDate == rhs.modificationDate {
                return lhs.id < rhs.id
            }
            return lhs.modificationDate > rhs.modificationDate
        }
        let newestDate = sortedSessions[0].modificationDate
        let clusteredSessionIDs = sortedSessions
            .filter { newestDate.timeIntervalSince($0.modificationDate) <= 5 }
            .prefix(8)
            .map(\.id)

        guard let lastFocusedSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
              clusteredSessionIDs.contains(lastFocusedSessionID) else {
            return clusteredSessionIDs
        }

        return [lastFocusedSessionID] + clusteredSessionIDs.filter { $0 != lastFocusedSessionID }
    }

    private func storedRestorableSessionIDs() -> [String] {
        userDefaults.stringArray(forKey: Keys.restorableSessionIDs) ?? []
    }

    private func consumePendingLaunchRestoreSessionID() -> String? {
        guard !pendingLaunchRestoreSessionIDs.isEmpty else { return nil }
        return pendingLaunchRestoreSessionIDs.removeFirst()
    }
}

private enum Keys {
    static let lastFocusedSessionID = "workspace.lastFocusedSessionID"
    static let restorableSessionIDs = "workspace.restorableSessionIDs"
}

@MainActor
final class ApplicationLifecycleState: ObservableObject {
    static let shared = ApplicationLifecycleState()

    private(set) var isTerminating = false

    func markTerminating() {
        isTerminating = true
    }
}
