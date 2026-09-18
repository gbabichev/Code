//
//  WorkspaceSessionRegistryTests.swift
//  CodeTests
//

import Foundation
import XCTest
@testable import Code

@MainActor
final class WorkspaceSessionRegistryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )

        userDefaultsSuiteName = "WorkspaceSessionRegistryTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        userDefaults = nil
        userDefaultsSuiteName = nil
        temporaryDirectoryURL = nil
    }

    func testLaunchCleanupRemovesSnapshotsNotRegisteredForRestoration() {
        save(nonBlankSnapshot(), sessionID: "retained")
        save(nonBlankSnapshot(), sessionID: "stale")
        writeCorruptSession(sessionID: "corrupt")
        userDefaults.set(["retained"], forKey: "workspace.restorableSessionIDs")

        let registry = makeRegistry()

        XCTAssertEqual(registry.makeSceneBootstrapSessionID(), "retained")
        XCTAssertTrue(store(sessionID: "retained").hasSavedSession)
        XCTAssertFalse(store(sessionID: "stale").hasSavedSession)
        XCTAssertFalse(store(sessionID: "corrupt").hasSavedSession)
    }

    func testFallbackSessionsAreRegisteredBeforeLaterRestoreChecks() {
        save(nonBlankSnapshot(), sessionID: "first")
        save(nonBlankSnapshot(), sessionID: "second")
        setModificationDate(Date(), sessionID: "first")
        setModificationDate(Date().addingTimeInterval(-1), sessionID: "second")

        let registry = makeRegistry()

        XCTAssertEqual(registry.makeSceneBootstrapSessionID(), "first")
        XCTAssertEqual(
            Set(userDefaults.stringArray(forKey: "workspace.restorableSessionIDs") ?? []),
            Set(["first", "second"])
        )
        XCTAssertTrue(store(sessionID: "first").hasSavedSession)
        XCTAssertTrue(store(sessionID: "second").hasSavedSession)
    }

    func testOnlyOneRedundantBlankWorkspaceIsRetained() {
        save(blankSnapshot(), sessionID: "blank-one")
        save(blankSnapshot(), sessionID: "blank-two")
        userDefaults.set(
            ["blank-one", "blank-two"],
            forKey: "workspace.restorableSessionIDs"
        )

        let registry = makeRegistry()
        let restoredSessionID = registry.makeSceneBootstrapSessionID()

        XCTAssertEqual(restoredSessionID, "blank-one")
        XCTAssertTrue(store(sessionID: "blank-one").hasSavedSession)
        XCTAssertFalse(store(sessionID: "blank-two").hasSavedSession)
    }

    func testIntentionalWindowCloseRequestsSnapshotDiscard() {
        save(nonBlankSnapshot(), sessionID: "closing")
        let registry = makeRegistry()
        registry.handleSceneAppear(sessionID: "closing") { _ in }

        registry.handleWindowWillClose(sessionID: "closing")

        XCTAssertFalse(store(sessionID: "closing").hasSavedSession)
        XCTAssertTrue(registry.consumeSessionDiscardRequest(sessionID: "closing"))
        XCTAssertFalse(registry.consumeSessionDiscardRequest(sessionID: "closing"))
        XCTAssertFalse(
            (userDefaults.stringArray(forKey: "workspace.restorableSessionIDs") ?? [])
                .contains("closing")
        )
    }

    private func makeRegistry() -> WorkspaceSessionRegistry {
        WorkspaceSessionRegistry(
            userDefaults: userDefaults,
            fileManager: .default,
            applicationSupportDirectoryURL: temporaryDirectoryURL
        )
    }

    private func store(sessionID: String) -> SessionStore {
        SessionStore(
            sessionID: sessionID,
            fileManager: .default,
            applicationSupportDirectoryURL: temporaryDirectoryURL
        )
    }

    private func save(_ snapshot: EditorSessionSnapshot, sessionID: String) {
        store(sessionID: sessionID).save(snapshot)
    }

    private func blankSnapshot() -> EditorSessionSnapshot {
        EditorSessionSnapshot(
            rootFolderPath: nil,
            selectedFilePath: nil,
            selectedTabPath: nil,
            tabs: []
        )
    }

    private func nonBlankSnapshot() -> EditorSessionSnapshot {
        EditorSessionSnapshot(
            rootFolderPath: "/tmp/project",
            selectedFilePath: nil,
            selectedTabPath: nil,
            tabs: []
        )
    }

    private func writeCorruptSession(sessionID: String) {
        let url = sessionURL(sessionID: sessionID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not-json".utf8).write(to: url)
    }

    private func setModificationDate(_ date: Date, sessionID: String) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: sessionURL(sessionID: sessionID).path(percentEncoded: false)
        )
    }

    private func sessionURL(sessionID: String) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("Code", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }
}
