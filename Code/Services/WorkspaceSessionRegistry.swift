//
//  WorkspaceSessionRegistry.swift
//  Code
//

import Combine
import Foundation

@MainActor
final class WorkspaceSessionRegistry: ObservableObject {
    private static let additionalLaunchRestoreDelay: TimeInterval = 1.0

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let applicationSupportDirectoryURL: URL?
    private var didConsumeLaunchRestore = false
    private var connectedSessionCounts: [String: Int] = [:]
    private var pendingLaunchRestoreSessionIDs: [String] = []
    private var discardedSessionIDs: Set<String> = []
    private var pendingRestoreWorkItem: DispatchWorkItem?
    private var isLaunchRestorationActive = true

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportDirectoryURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
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

        connectedSessionCounts[sessionID, default: 0] += 1
        pendingLaunchRestoreSessionIDs.removeAll { $0 == sessionID }
        register(sessionID: sessionID)
        scheduleAdditionalLaunchRestoreCheck(openAdditionalWindows: openAdditionalWindows)
    }

    func handleSceneDisappear(sessionID: String) {
        guard !sessionID.isEmpty else { return }

        let currentCount = connectedSessionCounts[sessionID, default: 0]
        if currentCount <= 1 {
            connectedSessionCounts.removeValue(forKey: sessionID)
        } else {
            connectedSessionCounts[sessionID] = currentCount - 1
        }
    }

    func handleWindowWillClose(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        guard !ApplicationLifecycleState.shared.isTerminating else { return }

        // Closing a workspace during the launch grace period is intentional. Stop the
        // delayed missing-session check from interpreting it as a failed restoration.
        isLaunchRestorationActive = false
        pendingRestoreWorkItem?.cancel()
        pendingRestoreWorkItem = nil
        pendingLaunchRestoreSessionIDs.removeAll()

        guard connectedSessionCounts[sessionID, default: 0] <= 1 else { return }

        discardedSessionIDs.insert(sessionID)
        SessionStore(
            sessionID: sessionID,
            fileManager: fileManager,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
        ).remove()

        var sessionIDs = storedRestorableSessionIDs()
        sessionIDs.removeAll { $0 == sessionID }
        userDefaults.set(sessionIDs, forKey: Keys.restorableSessionIDs)
        if userDefaults.string(forKey: Keys.lastFocusedSessionID) == sessionID {
            userDefaults.removeObject(forKey: Keys.lastFocusedSessionID)
        }
    }

    func consumeSessionDiscardRequest(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        return discardedSessionIDs.remove(sessionID) != nil
    }

    func noteRestoredSceneSession(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        didConsumeLaunchRestore = true
        pendingLaunchRestoreSessionIDs.removeAll { $0 == sessionID }
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
        let savedSessions = SessionStore.savedSessions(
            fileManager: fileManager,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
        )
        let availableSessionIDs = storedRestorableSessionIDs().filter {
            SessionStore(
                sessionID: $0,
                fileManager: fileManager,
                applicationSupportDirectoryURL: applicationSupportDirectoryURL
            ).hasSavedSession
        }

        if availableSessionIDs != storedRestorableSessionIDs() {
            userDefaults.set(availableSessionIDs, forKey: Keys.restorableSessionIDs)
        }

        let orderedSessionIDs: [String]
        if availableSessionIDs.isEmpty {
            orderedSessionIDs = fallbackRestorableSessionIDs(from: savedSessions)
        } else if let lastFocusedSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
                  availableSessionIDs.contains(lastFocusedSessionID) {
            orderedSessionIDs = [lastFocusedSessionID] + availableSessionIDs.filter { $0 != lastFocusedSessionID }
        } else {
            orderedSessionIDs = availableSessionIDs
        }

        let restorableSessionIDs = filteredLaunchRestoreSessionIDs(from: orderedSessionIDs)
        let connectedSessionIDs = Set(connectedSessionCounts.compactMap { sessionID, count in
            count > 0 ? sessionID : nil
        })
        let retainedSessionIDs = Set(restorableSessionIDs)
            .union(connectedSessionIDs)
            .union(pendingLaunchRestoreSessionIDs)

        SessionStore.removeSavedSessions(
            excluding: retainedSessionIDs,
            fileManager: fileManager,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
        )

        let storedSessionIDs = storedRestorableSessionIDs()
        var reconciledStoredSessionIDs = restorableSessionIDs
        for sessionID in storedSessionIDs where retainedSessionIDs.contains(sessionID) {
            if !reconciledStoredSessionIDs.contains(sessionID) {
                reconciledStoredSessionIDs.append(sessionID)
            }
        }
        for sessionID in connectedSessionIDs where !reconciledStoredSessionIDs.contains(sessionID) {
            reconciledStoredSessionIDs.append(sessionID)
        }
        if reconciledStoredSessionIDs != storedSessionIDs {
            userDefaults.set(reconciledStoredSessionIDs, forKey: Keys.restorableSessionIDs)
        }
        if let lastFocusedSessionID = userDefaults.string(forKey: Keys.lastFocusedSessionID),
           !retainedSessionIDs.contains(lastFocusedSessionID) {
            userDefaults.removeObject(forKey: Keys.lastFocusedSessionID)
        }

        return restorableSessionIDs
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

    private func filteredLaunchRestoreSessionIDs(from sessionIDs: [String]) -> [String] {
        guard !sessionIDs.isEmpty else { return [] }

        let classifiedSessionIDs: [(sessionID: String, isBlankWorkspace: Bool)] = sessionIDs.compactMap { sessionID in
            let snapshot = SessionStore(
                sessionID: sessionID,
                fileManager: fileManager,
                applicationSupportDirectoryURL: applicationSupportDirectoryURL
            ).load()
            guard let snapshot else { return nil }
            return (sessionID: sessionID, isBlankWorkspace: snapshot.isBlankWorkspace)
        }

        let nonBlankSessionIDs = classifiedSessionIDs
            .filter { !$0.isBlankWorkspace }
            .map(\.sessionID)
        if !nonBlankSessionIDs.isEmpty {
            return nonBlankSessionIDs
        }

        guard let firstBlankSessionID = classifiedSessionIDs.first?.sessionID else {
            return []
        }
        return [firstBlankSessionID]
    }

    private func scheduleAdditionalLaunchRestoreCheck(
        openAdditionalWindows: @escaping (_ count: Int) -> Void
    ) {
        pendingRestoreWorkItem?.cancel()
        guard isLaunchRestorationActive else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isLaunchRestorationActive else { return }

                let missingSessionIDs = self.orderedRestorableSessionIDs().filter { sessionID in
                    self.connectedSessionCounts[sessionID, default: 0] == 0
                        && !self.pendingLaunchRestoreSessionIDs.contains(sessionID)
                }
                guard !missingSessionIDs.isEmpty else {
                    self.isLaunchRestorationActive = false
                    self.pendingRestoreWorkItem = nil
                    return
                }

                self.pendingLaunchRestoreSessionIDs.append(contentsOf: missingSessionIDs)
                openAdditionalWindows(missingSessionIDs.count)
            }
        }

        pendingRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.additionalLaunchRestoreDelay,
            execute: workItem
        )
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
