//
//  EditorWorkspace.swift
//  Code
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorWorkspace: ObservableObject {
    private static let largeFileTypingThreshold = 100_000
    private static let maxRecentlyClosedTabs = 20

    enum EditorPane: String {
        case primary
        case secondary
    }

    @Published private(set) var rootFolderURL: URL?
    @Published private(set) var fileTree: [FileNode] = []
    @Published private(set) var openTabs: [EditorTab] = []
    @Published var selectedTabID: EditorTab.ID?
    @Published private(set) var primaryTabID: EditorTab.ID?
    @Published private(set) var secondaryTabID: EditorTab.ID?
    @Published private(set) var focusedPane: EditorPane = .primary
    @Published var selectedFileID: FileNode.ID?
    @Published var errorMessage: String?
    @Published var pendingTabClose: PendingTabClose?
    @Published var pendingWindowClose: PendingWindowClose?
    @Published var pendingFileRefresh: PendingFileRefresh?
    @Published private var externalModificationVersionByTabID: [EditorTab.ID: Int] = [:]

    private let preferences: AppPreferences
    private let fileManager: FileManager
    private let sessionStore: SessionStore
    private var tabObservers: [String: AnyCancellable] = [:]
    private var knownDiskStatesByTabID: [EditorTab.ID: FileDiskState] = [:]
    private var persistSessionTimer: Timer?
    private var pendingWindowCloseAction: (@MainActor () -> Void)?
    private var pendingDirtyStateRecheckTabIDs = Set<EditorTab.ID>()
    private var recentlyClosedTabs: [ClosedTabState] = []
    private var nextExternalModificationVersion = 0

    init(
        preferences: AppPreferences,
        fileManager: FileManager = .default,
        sessionStore: SessionStore,
        skipUntitledIfPendingFiles: Bool = false
    ) {
        self.preferences = preferences
        self.fileManager = fileManager
        self.sessionStore = sessionStore
        restoreSession()

        if openTabs.isEmpty && !skipUntitledIfPendingFiles {
            createUntitledTab()
        }
    }

    var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return openTabs.first(where: { $0.id == selectedTabID })
    }

    var primaryTab: EditorTab? {
        guard let primaryTabID else { return nil }
        return openTabs.first(where: { $0.id == primaryTabID })
    }

    var secondaryTab: EditorTab? {
        guard let secondaryTabID else { return nil }
        return openTabs.first(where: { $0.id == secondaryTabID })
    }

    var hasDirtyTabs: Bool {
        openTabs.contains(where: \.isDirty)
    }

    func externalModificationVersion(for id: EditorTab.ID) -> Int? {
        externalModificationVersionByTabID[id]
    }

    func tab(withID id: EditorTab.ID) -> EditorTab? {
        openTabs.first(where: { $0.id == id })
    }

    func isFileDirty(_ url: URL) -> Bool {
        openTabs.contains { $0.fileURL == url && $0.isDirty }
    }

    func createUntitledTab() {
        let untitledIndex = openTabs
            .filter { $0.fileURL == nil }
            .count + 1
        let title = untitledIndex == 1 ? "Untitled" : "Untitled \(untitledIndex)"
        let tab = EditorTab(
            fileURL: nil,
            customTitle: title,
            content: "",
            lastSavedContent: "",
            isDirty: false
        )
        attachObserver(to: tab)
        openTabs.append(tab)
        if primaryTabID == nil {
            primaryTabID = tab.id
            focusedPane = .primary
        } else if focusedPane == .secondary, secondaryTabID != nil {
            secondaryTabID = tab.id
        } else {
            primaryTabID = tab.id
            focusedPane = .primary
        }
        syncActiveSelection()
        persistSession()
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"

        if panel.runModal() == .OK, let url = panel.url {
            setRootFolder(url)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open File"

        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    func setRootFolder(_ url: URL) {
        rootFolderURL = url
        preferences.recordRecentFolder(url)
        reloadFileTree()
        persistSession()
    }

    func closeFolder() {
        rootFolderURL = nil
        fileTree = []
        openTabs.removeAll()
        tabObservers.removeAll()
        knownDiskStatesByTabID.removeAll()
        recentlyClosedTabs.removeAll()
        primaryTabID = nil
        secondaryTabID = nil
        focusedPane = .primary
        selectedTabID = nil
        selectedFileID = nil
        pendingTabClose = nil
        pendingWindowClose = nil
        pendingFileRefresh = nil
        externalModificationVersionByTabID.removeAll()
        nextExternalModificationVersion = 0
        pendingWindowCloseAction = nil
        errorMessage = nil
        createUntitledTab()
    }

    func reloadFileTree() {
        guard let rootFolderURL else {
            fileTree = []
            return
        }

        fileTree = loadChildren(of: rootFolderURL)
    }

    func openFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }

        selectedFileID = url.path(percentEncoded: false)

        if let existing = openTabs.first(where: { $0.fileURL == url }) {
            preferences.recordRecentFile(url)
            selectTab(existing.id)
            persistSession()
            return
        }

        do {
            let fileContents = try readTextFile(at: url)
            let tab = EditorTab(
                fileURL: url,
                languageOverride: nil,
                textEncoding: fileContents.encoding,
                lineEnding: fileContents.lineEnding,
                content: fileContents.content,
                lastSavedContent: fileContents.content,
                isDirty: false
            )
            attachObserver(to: tab)
            openTabs.append(tab)
            recordKnownDiskState(for: tab.id, fileURL: url)
            preferences.recordRecentFile(url)
            selectTab(tab.id, persist: false)
            persistSession()
        } catch {
            errorMessage = "Failed to open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func closeTab(_ id: EditorTab.ID, preserveUnsavedChangesForReopen: Bool = true) {
        guard let closedState = closedTabState(for: id, preserveUnsavedChanges: preserveUnsavedChangesForReopen) else {
            return
        }

        recentlyClosedTabs.append(closedState)
        if recentlyClosedTabs.count > Self.maxRecentlyClosedTabs {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.maxRecentlyClosedTabs)
        }

        _ = removeTab(id, persist: false)
        persistSession()
    }

    var canReopenClosedTab: Bool {
        !recentlyClosedTabs.isEmpty
    }

    func reopenLastClosedTab() {
        guard let closedState = recentlyClosedTabs.popLast() else { return }

        let tab = EditorTab(
            fileURL: closedState.fileURL,
            languageOverride: closedState.languageOverride,
            textEncoding: closedState.textEncoding,
            lineEnding: closedState.lineEnding,
            customTitle: closedState.customTitle,
            content: closedState.content,
            lastSavedContent: closedState.lastSavedContent,
            lastSavedEncoding: closedState.lastSavedEncoding,
            lastSavedLineEnding: closedState.lastSavedLineEnding,
            isDirty: closedState.isDirty
        )

        attachObserver(to: tab)
        openTabs.append(tab)
        if let lastKnownDiskState = closedState.lastKnownDiskState {
            knownDiskStatesByTabID[tab.id] = lastKnownDiskState
        } else {
            recordKnownDiskState(for: tab.id, fileURL: tab.fileURL)
        }
        if let externalModificationVersion = closedState.externalModificationVersion {
            externalModificationVersionByTabID[tab.id] = externalModificationVersion
        }
        selectTab(tab.id, persist: false)
        persistSession()
    }

    func detachTab(_ id: EditorTab.ID) -> EditorTab? {
        let tab = removeTab(id, persist: false)
        persistSession()
        return tab
    }

    func adoptTransferredTab(_ tab: EditorTab) {
        openTabs.forEach { tabObservers[$0.id] = nil }
        openTabs.removeAll()
        knownDiskStatesByTabID.removeAll()
        externalModificationVersionByTabID.removeAll()
        attachObserver(to: tab)
        openTabs.append(tab)
        recordKnownDiskState(for: tab.id, fileURL: tab.fileURL)
        primaryTabID = tab.id
        secondaryTabID = nil
        focusedPane = .primary
        syncActiveSelection()
        persistSession()
    }

    func openTabInSplitView(_ id: EditorTab.ID) {
        guard tab(withID: id) != nil else { return }

        if primaryTabID == nil {
            primaryTabID = id
            focusedPane = .primary
        } else if primaryTabID == id {
            guard let candidate = openTabs.first(where: { $0.id != id }) else {
                syncActiveSelection()
                return
            }
            secondaryTabID = candidate.id
            focusedPane = .secondary
        } else {
            secondaryTabID = id
            focusedPane = .secondary
        }

        syncActiveSelection()
        persistSession()
    }

    func removeTabFromSplitView(_ id: EditorTab.ID) {
        guard primaryTabID == id || secondaryTabID == id else { return }

        if primaryTabID == id, let secondaryTabID {
            primaryTabID = secondaryTabID
            self.secondaryTabID = nil
        } else if secondaryTabID == id {
            secondaryTabID = nil
        }

        focusedPane = .primary
        syncActiveSelection()
        persistSession()
    }

    func focusPane(_ pane: EditorPane) {
        DispatchQueue.main.async { [weak self] in
            self?.applyFocusPane(pane)
        }
    }

    private func applyFocusPane(_ pane: EditorPane) {
        if pane == .secondary, secondaryTabID == nil {
            focusedPane = .primary
        } else {
            focusedPane = pane
        }
        syncActiveSelection()
    }

    func selectTab(_ id: EditorTab.ID, persist: Bool = true) {
        guard tab(withID: id) != nil else { return }

        if primaryTabID == id {
            focusedPane = .primary
        } else if secondaryTabID == id {
            focusedPane = .secondary
        } else {
            switch focusedPane {
            case .primary:
                primaryTabID = id
            case .secondary:
                if secondaryTabID != nil {
                    secondaryTabID = id
                } else {
                    primaryTabID = id
                    focusedPane = .primary
                }
            }
        }

        syncActiveSelection()
        if persist {
            persistSession()
        }
    }

    func moveTab(_ id: EditorTab.ID, before targetID: EditorTab.ID) {
        guard id != targetID,
              let sourceIndex = openTabs.firstIndex(where: { $0.id == id }),
              let targetIndex = openTabs.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let tab = openTabs.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        openTabs.insert(tab, at: adjustedTargetIndex)
        persistSession()
    }

    func moveTabToEnd(_ id: EditorTab.ID) {
        guard let sourceIndex = openTabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let tab = openTabs.remove(at: sourceIndex)
        openTabs.append(tab)
        persistSession()
    }

    func requestCloseTab(_ id: EditorTab.ID) {
        ActiveEditorTextViewRegistry.shared.flushAllPendingModelSync()
        guard let tab = tab(withID: id) else { return }

        if tab.isDirty {
            pendingTabClose = PendingTabClose(id: id, fileName: tab.title)
        } else {
            closeTab(id)
        }
    }

    func requestCloseSelectedTab() {
        guard let selectedTabID else { return }
        requestCloseTab(selectedTabID)
    }

    var canRefreshSelectedFile: Bool {
        selectedTab?.fileURL != nil
    }

    func requestRefreshSelectedFile() {
        guard let selectedTab else { return }
        requestRefreshFile(for: selectedTab.id)
    }

    func requestRefreshFile(for id: EditorTab.ID) {
        ActiveEditorTextViewRegistry.shared.flushAllPendingModelSync()
        guard let tab = tab(withID: id), tab.fileURL != nil else { return }

        if tab.isDirty {
            pendingFileRefresh = PendingFileRefresh(id: id, fileName: tab.title)
        } else {
            refreshFile(for: id)
        }
    }

    func synchronizeCleanTabsWithDisk() {
        ActiveEditorTextViewRegistry.shared.flushAllPendingModelSync()

        for tab in openTabs {
            guard !tab.isDirty, let fileURL = tab.fileURL else { continue }
            guard let currentDiskState = try? diskState(for: fileURL) else { continue }
            guard knownDiskStatesByTabID[tab.id] != currentDiskState else { continue }
            _ = refreshFile(for: tab.id, reportErrors: false)
        }

        for tab in openTabs {
            guard tab.isDirty, let fileURL = tab.fileURL else { continue }
            guard let currentDiskState = try? diskState(for: fileURL) else { continue }
            guard knownDiskStatesByTabID[tab.id] != currentDiskState else { continue }
            noteExternalModification(for: tab.id, diskState: currentDiskState)
        }
    }

    func confirmPendingFileRefresh() {
        guard let pendingFileRefresh else { return }
        refreshFile(for: pendingFileRefresh.id)
        self.pendingFileRefresh = nil
    }

    func cancelPendingFileRefresh() {
        pendingFileRefresh = nil
    }

    func confirmPendingTabCloseSave() async {
        guard let pendingTabClose else { return }
        await saveTab(id: pendingTabClose.id)
        if errorMessage == nil {
            closeTab(pendingTabClose.id)
        }
        self.pendingTabClose = nil
    }

    func confirmPendingTabCloseDiscard() {
        guard let pendingTabClose else { return }
        closeTab(pendingTabClose.id, preserveUnsavedChangesForReopen: false)
        self.pendingTabClose = nil
    }

    func cancelPendingTabClose() {
        pendingTabClose = nil
    }

    func requestWindowClose(performClose: @escaping @MainActor () -> Void) {
        ActiveEditorTextViewRegistry.shared.flushAllPendingModelSync()
        if hasDirtyTabs {
            pendingWindowCloseAction = performClose
            pendingWindowClose = PendingWindowClose(
                dirtyTabNames: openTabs.filter(\.isDirty).map(\.title)
            )
            return
        }

        flushSession()
        performClose()
    }

    func confirmPendingWindowCloseSave() async {
        guard pendingWindowClose != nil else { return }

        let dirtyTabIDs = openTabs.filter(\.isDirty).map(\.id)
        for id in dirtyTabIDs {
            await saveTab(id: id)
            guard let tab = tab(withID: id), !tab.isDirty, errorMessage == nil else {
                cancelPendingWindowClose()
                return
            }
        }

        let closeAction = pendingWindowCloseAction
        pendingWindowClose = nil
        pendingWindowCloseAction = nil
        flushSession()
        closeAction?()
    }

    func confirmPendingWindowCloseDiscard() {
        guard pendingWindowClose != nil else { return }

        for tab in openTabs where tab.isDirty {
            discardChanges(for: tab)
        }

        let closeAction = pendingWindowCloseAction
        pendingWindowClose = nil
        pendingWindowCloseAction = nil
        flushSession()
        closeAction?()
    }

    func cancelPendingWindowClose() {
        pendingWindowClose = nil
        pendingWindowCloseAction = nil
    }

    func updateContent(_ content: String, for id: EditorTab.ID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        // Large dirty files should not re-compare the entire buffer on every keypress.
        let shouldUseDeferredDirtyCheck = tab.isDirty && content.utf16.count > Self.largeFileTypingThreshold
        EditorDebugTrace.log("EditorWorkspace.updateContent tab=\(id) chars=\(content.utf16.count) deferredDirtyCheck=\(shouldUseDeferredDirtyCheck)")
        tab.setContent(content, notify: false, exactDirtyCheck: !shouldUseDeferredDirtyCheck)
        if shouldUseDeferredDirtyCheck {
            pendingDirtyStateRecheckTabIDs.insert(tab.id)
        } else {
            pendingDirtyStateRecheckTabIDs.remove(tab.id)
        }
        // Debounced session persistence — fires after 250ms of inactivity.
        persistSession()
    }

    func saveSelectedTab() async {
        ActiveEditorTextViewRegistry.shared.flushPendingModelSync()
        guard let tab = selectedTab else { return }
        await saveTab(id: tab.id)
    }

    func saveSelectedTabAs() async {
        ActiveEditorTextViewRegistry.shared.flushPendingModelSync()
        guard let tab = selectedTab else { return }
        await saveTab(id: tab.id, forceSavePanel: true)
    }

    func saveTab(id: EditorTab.ID) async {
        await saveTab(id: id, forceSavePanel: false)
    }

    func saveTab(id: EditorTab.ID, forceSavePanel: Bool) async {
        ActiveEditorTextViewRegistry.shared.flushPendingModelSync()
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }

        let destinationURL: URL
        if let fileURL = tab.fileURL, !forceSavePanel {
            destinationURL = fileURL
        } else {
            guard let url = await presentSavePanel(
                suggestedFileName: tab.title,
                existingFileURL: tab.fileURL
            ) else {
                return
            }

            destinationURL = url
        }

        do {
            let output = contentWithPreferredLineEndings(for: tab)
            guard let data = output.data(using: tab.textEncoding.stringEncoding) else {
                errorMessage = "Failed to encode \(destinationURL.lastPathComponent) as \(tab.textEncoding.title)."
                return
            }

            try data.write(to: destinationURL, options: .atomic)
            tab.fileURL = destinationURL
            tab.customTitle = nil
            tab.lastSavedContent = tab.content
            tab.lastSavedEncoding = tab.textEncoding
            tab.lastSavedLineEnding = tab.lineEnding
            tab.refreshDirtyState()
            preferences.recordRecentFile(destinationURL)
            selectedFileID = destinationURL.path(percentEncoded: false)
            recordKnownDiskState(for: tab.id, fileURL: destinationURL)
            clearExternalModification(for: tab.id)
            if let rootFolderURL,
               destinationURL.path(percentEncoded: false).hasPrefix(rootFolderURL.path(percentEncoded: false)) {
                reloadFileTree()
            }
            persistSession()
        } catch {
            errorMessage = "Failed to save \(destinationURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func presentSavePanel(
        suggestedFileName: String,
        existingFileURL: URL?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = ""
        panel.message = ""
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = existingFileURL?.lastPathComponent ?? suggestedFileName
        panel.directoryURL = existingFileURL?.deletingLastPathComponent()
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: hostWindow) { response in
                    guard response == .OK, let destinationURL = panel.url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: destinationURL)
                }
            }
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return nil
        }

        return destinationURL
    }

    func updateSelectedTabEncoding(_ encoding: EditorTextEncoding) {
        guard let selectedTab else { return }
        if selectedTab.textEncoding == encoding { return }
        selectedTab.textEncoding = encoding
        selectedTab.refreshDirtyState()
        persistSession()
    }

    func updateSelectedTabLineEnding(_ lineEnding: EditorLineEnding) {
        guard let selectedTab else { return }
        if selectedTab.lineEnding == lineEnding { return }
        selectedTab.lineEnding = lineEnding
        selectedTab.refreshDirtyState()
        persistSession()
    }

    func updateSelectedTabLanguageOverride(_ language: EditorLanguage?) {
        guard let selectedTab else { return }
        if selectedTab.languageOverride == language { return }
        selectedTab.languageOverride = language
        persistSession()
    }

    func persistSession() {
        // Real debounce: wait for 250ms of inactivity before writing session state.
        EditorDebugTrace.log("EditorWorkspace.persistSession schedule")
        persistSessionTimer?.invalidate()
        persistSessionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushSession()
            }
        }
    }

    /// Immediately write session state to disk (used on app termination)
    func flushSession() {
        EditorDebugTrace.log("EditorWorkspace.flushSession begin")
        ActiveEditorTextViewRegistry.shared.flushAllPendingModelSync()
        reconcilePendingDirtyStates()

        let snapshot = EditorSessionSnapshot(
            rootFolderPath: rootFolderURL?.path(percentEncoded: false),
            selectedFilePath: selectedFileID,
            selectedTabPath: primaryTabID,
            tabs: openTabs.map {
                EditorTabSnapshot(
                    id: $0.id,
                    filePath: $0.fileURL?.path(percentEncoded: false),
                    title: $0.fileURL == nil ? $0.title : nil,
                    languageOverride: $0.languageOverride,
                    encoding: $0.textEncoding,
                    lineEnding: $0.lineEnding,
                    lastSavedEncoding: $0.lastSavedEncoding,
                    lastSavedLineEnding: $0.lastSavedLineEnding,
                    content: ($0.fileURL != nil && !$0.isDirty) ? "" : $0.content,
                    isDirty: $0.isDirty
                )
            }
        )
        sessionStore.save(snapshot)
        EditorDebugTrace.log("EditorWorkspace.flushSession end tabs=\(openTabs.count)")
    }

    private func reconcilePendingDirtyStates() {
        guard !pendingDirtyStateRecheckTabIDs.isEmpty else { return }

        for id in pendingDirtyStateRecheckTabIDs {
            guard let tab = openTabs.first(where: { $0.id == id }) else { continue }
            tab.refreshDirtyState(exactContentCheck: true)
        }

        pendingDirtyStateRecheckTabIDs.removeAll()
    }

    private func restoreSession() {
        guard let snapshot = sessionStore.load() else { return }

        if let rootFolderPath = snapshot.rootFolderPath {
            let url = URL(fileURLWithPath: rootFolderPath)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                rootFolderURL = url
                reloadFileTree()
            }
        }

        let restoredTabs = snapshot.tabs.compactMap { item -> EditorTab? in
            if let filePath = item.filePath {
                let url = URL(fileURLWithPath: filePath)
                guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
                    return nil
                }

                let diskContents = (try? readTextFile(at: url)) ?? (
                    content: normalizeLineEndings(in: item.content),
                    encoding: item.lastSavedEncoding ?? item.encoding ?? .utf8,
                    lineEnding: item.lastSavedLineEnding ?? item.lineEnding ?? .lf
                )
                let currentEncoding = item.encoding ?? diskContents.encoding
                let currentLineEnding = item.lineEnding ?? diskContents.lineEnding
                let restoredContent = item.isDirty ? item.content : diskContents.content
                let tab = EditorTab(
                    id: item.id ?? url.path(percentEncoded: false),
                    fileURL: url,
                    languageOverride: item.languageOverride,
                    textEncoding: currentEncoding,
                    lineEnding: currentLineEnding,
                    content: restoredContent,
                    lastSavedContent: diskContents.content,
                    lastSavedEncoding: item.isDirty ? diskContents.encoding : currentEncoding,
                    lastSavedLineEnding: item.isDirty ? diskContents.lineEnding : currentLineEnding,
                    isDirty: item.isDirty
                )
                attachObserver(to: tab)
                recordKnownDiskState(for: tab.id, fileURL: url)
                return tab
            }

            let tab = EditorTab(
                id: item.id ?? UUID().uuidString,
                fileURL: nil,
                languageOverride: item.languageOverride,
                textEncoding: item.encoding ?? .utf8,
                lineEnding: item.lineEnding ?? .lf,
                customTitle: item.title,
                content: item.content,
                lastSavedContent: item.content,
                lastSavedEncoding: item.lastSavedEncoding ?? item.encoding ?? .utf8,
                lastSavedLineEnding: item.lastSavedLineEnding ?? item.lineEnding ?? .lf,
                isDirty: item.isDirty
            )
            attachObserver(to: tab)
            return tab
        }

        openTabs = restoredTabs
        selectedFileID = snapshot.selectedFilePath
        if let preferredID = snapshot.selectedTabPath, restoredTabs.contains(where: { $0.id == preferredID }) {
            primaryTabID = preferredID
        } else {
            primaryTabID = restoredTabs.first?.id
        }
        secondaryTabID = nil
        focusedPane = .primary
        syncActiveSelection()
    }
    private func attachObserver(to tab: EditorTab) {
        // Only forward changes that affect the dirty state (isDirty is @Published).
        // Per-keystroke content updates no longer trigger objectWillChange.
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.persistSession()
            }
        }
    }

    private func discardChanges(for tab: EditorTab) {
        tab.textEncoding = tab.lastSavedEncoding
        tab.lineEnding = tab.lastSavedLineEnding
        tab.setContent(tab.lastSavedContent, notify: true)
    }

    private func refreshFile(for id: EditorTab.ID) {
        _ = refreshFile(for: id, reportErrors: true)
    }

    @discardableResult
    private func refreshFile(for id: EditorTab.ID, reportErrors: Bool) -> Bool {
        guard let tab = tab(withID: id), let fileURL = tab.fileURL else { return false }

        do {
            let fileContents = try readTextFile(at: fileURL)
            tab.textEncoding = fileContents.encoding
            tab.lineEnding = fileContents.lineEnding
            tab.lastSavedEncoding = fileContents.encoding
            tab.lastSavedLineEnding = fileContents.lineEnding
            tab.lastSavedContent = fileContents.content
            tab.setContent(fileContents.content, notify: true)
            if selectedTabID == id {
                selectedFileID = fileURL.path(percentEncoded: false)
            }
            recordKnownDiskState(for: tab.id, fileURL: fileURL)
            clearExternalModification(for: tab.id)
            persistSession()
            return true
        } catch {
            if reportErrors {
                errorMessage = "Failed to refresh \(fileURL.lastPathComponent): \(error.localizedDescription)"
            }
            return false
        }
    }

    private func closedTabState(for id: EditorTab.ID, preserveUnsavedChanges: Bool) -> ClosedTabState? {
        guard let tab = tab(withID: id) else { return nil }

        if preserveUnsavedChanges {
            return ClosedTabState(
                fileURL: tab.fileURL,
                customTitle: tab.customTitle,
                languageOverride: tab.languageOverride,
                textEncoding: tab.textEncoding,
                lineEnding: tab.lineEnding,
                content: tab.content,
                lastSavedContent: tab.lastSavedContent,
                lastSavedEncoding: tab.lastSavedEncoding,
                lastSavedLineEnding: tab.lastSavedLineEnding,
                isDirty: tab.isDirty,
                lastKnownDiskState: knownDiskStatesByTabID[id],
                externalModificationVersion: externalModificationVersionByTabID[id]
            )
        }

        return ClosedTabState(
            fileURL: tab.fileURL,
            customTitle: tab.customTitle,
            languageOverride: tab.languageOverride,
            textEncoding: tab.lastSavedEncoding,
            lineEnding: tab.lastSavedLineEnding,
            content: tab.lastSavedContent,
            lastSavedContent: tab.lastSavedContent,
            lastSavedEncoding: tab.lastSavedEncoding,
            lastSavedLineEnding: tab.lastSavedLineEnding,
            isDirty: false,
            lastKnownDiskState: knownDiskStatesByTabID[id],
            externalModificationVersion: externalModificationVersionByTabID[id]
        )
    }

    @discardableResult
    private func removeTab(_ id: EditorTab.ID, persist: Bool) -> EditorTab? {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let removedTab = openTabs.remove(at: index)
        tabObservers[id] = nil
        knownDiskStatesByTabID[id] = nil
        externalModificationVersionByTabID[id] = nil

        if primaryTabID == id {
            if let secondaryTabID {
                primaryTabID = secondaryTabID
                self.secondaryTabID = nil
            } else {
                primaryTabID = openTabs.last?.id
            }
            focusedPane = .primary
        } else if secondaryTabID == id {
            secondaryTabID = nil
            focusedPane = .primary
        }

        if selectedFileID == removedTab.fileURL?.path(percentEncoded: false) {
            selectedFileID = selectedTab?.fileURL?.path(percentEncoded: false)
        }

        syncActiveSelection()
        if persist {
            persistSession()
        }
        return removedTab
    }

    private func syncActiveSelection() {
        if focusedPane == .secondary, let secondaryTabID {
            selectedTabID = secondaryTabID
        } else {
            focusedPane = .primary
            selectedTabID = primaryTabID
        }
        selectedFileID = selectedTab?.fileURL?.path(percentEncoded: false)
    }

    private func loadChildren(of url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .localizedNameKey]

        let items = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )) ?? []

        return items
            .filter { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return values?.isHidden != true
            }
            .sorted { lhs, rhs in
                let leftDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rightDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if leftDirectory != rightDirectory {
                    return leftDirectory && !rightDirectory
                }

                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { item in
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(
                    url: item,
                    isDirectory: isDirectory,
                    children: isDirectory ? loadChildren(of: item) : []
                )
            }
    }

    private func normalizeLineEndings(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func detectedLineEnding(in text: String) -> EditorLineEnding {
        if text.contains("\r\n") {
            return .crlf
        }

        if text.contains("\r") {
            return .cr
        }

        return .lf
    }

    private func contentWithPreferredLineEndings(for tab: EditorTab) -> String {
        normalizeLineEndings(in: tab.content).replacingOccurrences(of: "\n", with: tab.lineEnding.sequence)
    }

    private func recordKnownDiskState(for id: EditorTab.ID, fileURL: URL?) {
        guard let fileURL else {
            knownDiskStatesByTabID[id] = nil
            return
        }

        knownDiskStatesByTabID[id] = try? diskState(for: fileURL)
    }

    private func noteExternalModification(for id: EditorTab.ID, diskState: FileDiskState) {
        nextExternalModificationVersion += 1
        externalModificationVersionByTabID[id] = nextExternalModificationVersion
        knownDiskStatesByTabID[id] = diskState
    }

    private func clearExternalModification(for id: EditorTab.ID) {
        externalModificationVersionByTabID[id] = nil
    }

    private func diskState(for url: URL) throws -> FileDiskState {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileDiskState(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize
        )
    }

    private func readTextFile(at url: URL) throws -> (content: String, encoding: EditorTextEncoding, lineEnding: EditorLineEnding) {
        let data = try Data(contentsOf: url)
        let decoded = try decodeTextData(data, fileName: url.lastPathComponent)
        let string = decoded.string
        let encoding = decoded.encoding
        let normalizedContent = normalizeLineEndings(in: string)
        return (
            content: normalizedContent,
            encoding: encoding,
            lineEnding: detectedLineEnding(in: data, encoding: encoding) ?? detectedLineEnding(in: string)
        )
    }

    private func detectedLineEnding(in data: Data, encoding: EditorTextEncoding) -> EditorLineEnding? {
        if data.range(of: encodedData(for: "\r\n", encoding: encoding)) != nil {
            return .crlf
        }

        if data.range(of: encodedData(for: "\r", encoding: encoding)) != nil {
            return .cr
        }

        if data.range(of: encodedData(for: "\n", encoding: encoding)) != nil {
            return .lf
        }

        return nil
    }

    private func encodedData(for string: String, encoding: EditorTextEncoding) -> Data {
        string.data(using: encoding.stringEncoding) ?? Data()
    }

    private func decodeTextData(_ data: Data, fileName: String) throws -> (string: String, encoding: EditorTextEncoding) {
        for encoding in EditorTextEncoding.allCases {
            if let string = String(data: data, encoding: encoding.stringEncoding) {
                return (string, encoding)
            }
        }

        throw NSError(
            domain: "Code.EditorWorkspace",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding for \(fileName)."]
        )
    }
}

private struct ClosedTabState {
    let fileURL: URL?
    let customTitle: String?
    let languageOverride: EditorLanguage?
    let textEncoding: EditorTextEncoding
    let lineEnding: EditorLineEnding
    let content: String
    let lastSavedContent: String
    let lastSavedEncoding: EditorTextEncoding
    let lastSavedLineEnding: EditorLineEnding
    let isDirty: Bool
    let lastKnownDiskState: FileDiskState?
    let externalModificationVersion: Int?
}

private struct FileDiskState: Equatable {
    let modificationDate: Date?
    let fileSize: Int?
}
