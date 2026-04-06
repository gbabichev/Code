//
//  EditorWorkspace.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorWorkspace: ObservableObject {
    @Published private(set) var rootFolderURL: URL?
    @Published private(set) var fileTree: [FileNode] = []
    @Published private(set) var openTabs: [EditorTab] = []
    @Published var selectedTabID: EditorTab.ID?
    @Published var selectedFileID: FileNode.ID?
    @Published var errorMessage: String?
    @Published var pendingTabClose: PendingTabClose?

    private let fileManager: FileManager
    private let sessionStore: SessionStore
    private var tabObservers: [String: AnyCancellable] = [:]

    init(
        fileManager: FileManager = .default,
        sessionStore: SessionStore
    ) {
        self.fileManager = fileManager
        self.sessionStore = sessionStore
        restoreSession()

        if openTabs.isEmpty {
            createUntitledTab()
        }
    }

    var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return openTabs.first(where: { $0.id == selectedTabID })
    }

    var hasDirtyTabs: Bool {
        openTabs.contains(where: \.isDirty)
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
        selectedTabID = tab.id
        selectedFileID = nil
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
        reloadFileTree()
        persistSession()
    }

    func closeFolder() {
        rootFolderURL = nil
        fileTree = []
        openTabs.removeAll()
        tabObservers.removeAll()
        selectedTabID = nil
        selectedFileID = nil
        pendingTabClose = nil
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
            selectedTabID = existing.id
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
            selectedTabID = tab.id
            persistSession()
        } catch {
            errorMessage = "Failed to open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func closeTab(_ id: EditorTab.ID) {
        openTabs.removeAll { $0.id == id }
        tabObservers[id] = nil

        if selectedTabID == id {
            selectedTabID = openTabs.last?.id
        }

        persistSession()
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

    func confirmPendingTabCloseSave() {
        guard let pendingTabClose else { return }
        saveTab(id: pendingTabClose.id)
        if errorMessage == nil {
            closeTab(pendingTabClose.id)
        }
        self.pendingTabClose = nil
    }

    func confirmPendingTabCloseDiscard() {
        guard let pendingTabClose else { return }
        closeTab(pendingTabClose.id)
        self.pendingTabClose = nil
    }

    func cancelPendingTabClose() {
        pendingTabClose = nil
    }

    func updateSelectedTabContent(_ content: String) {
        guard let tab = selectedTab else { return }
        updateContent(content, for: tab.id)
    }

    func updateContent(_ content: String, for id: EditorTab.ID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        if tab.content == content { return }

        tab.content = content
        tab.refreshDirtyState()
        persistSession()
    }

    func saveSelectedTab() {
        guard let tab = selectedTab else { return }
        saveTab(id: tab.id)
    }

    func saveTab(id: EditorTab.ID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }

        let destinationURL: URL
        if let fileURL = tab.fileURL {
            destinationURL = fileURL
        } else {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = tab.title

            guard panel.runModal() == .OK, let url = panel.url else {
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
            selectedFileID = destinationURL.path(percentEncoded: false)
            if let rootFolderURL,
               destinationURL.path(percentEncoded: false).hasPrefix(rootFolderURL.path(percentEncoded: false)) {
                reloadFileTree()
            }
            persistSession()
        } catch {
            errorMessage = "Failed to save \(destinationURL.lastPathComponent): \(error.localizedDescription)"
        }
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
        let snapshot = EditorSessionSnapshot(
            rootFolderPath: rootFolderURL?.path(percentEncoded: false),
            selectedFilePath: selectedFileID,
            selectedTabPath: selectedTabID,
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
                    content: $0.content,
                    isDirty: $0.isDirty
                )
            }
        )
        sessionStore.save(snapshot)
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
                let tab = EditorTab(
                    id: item.id ?? url.path(percentEncoded: false),
                    fileURL: url,
                    languageOverride: item.languageOverride,
                    textEncoding: currentEncoding,
                    lineEnding: currentLineEnding,
                    content: item.content,
                    lastSavedContent: item.isDirty ? diskContents.content : item.content,
                    lastSavedEncoding: item.isDirty ? diskContents.encoding : currentEncoding,
                    lastSavedLineEnding: item.isDirty ? diskContents.lineEnding : currentLineEnding,
                    isDirty: item.isDirty
                )
                attachObserver(to: tab)
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
        selectedTabID = snapshot.selectedTabPath ?? restoredTabs.first?.id
    }
    private func attachObserver(to tab: EditorTab) {
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.persistSession()
        }
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
