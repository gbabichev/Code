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
    }

    var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return openTabs.first(where: { $0.id == selectedTabID })
    }

    func isFileDirty(_ url: URL) -> Bool {
        openTabs.contains { $0.fileURL == url && $0.isDirty }
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
            let content = try String(contentsOf: url, encoding: .utf8)
            let tab = EditorTab(fileURL: url, content: content, lastSavedContent: content, isDirty: false)
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

    func updateSelectedTabContent(_ content: String) {
        guard let tab = selectedTab else { return }
        updateContent(content, for: tab.id)
    }

    func updateContent(_ content: String, for id: EditorTab.ID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        if tab.content == content { return }

        tab.content = content
        tab.isDirty = content != tab.lastSavedContent
        persistSession()
    }

    func saveSelectedTab() {
        guard let tab = selectedTab else { return }
        saveTab(id: tab.id)
    }

    func saveTab(id: EditorTab.ID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }

        do {
            try tab.content.write(to: tab.fileURL, atomically: true, encoding: .utf8)
            replaceTab(tab, withContent: tab.content, lastSavedContent: tab.content, isDirty: false)
            persistSession()
        } catch {
            errorMessage = "Failed to save \(tab.fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func persistSession() {
        let snapshot = EditorSessionSnapshot(
            rootFolderPath: rootFolderURL?.path(percentEncoded: false),
            selectedFilePath: selectedFileID,
            selectedTabPath: selectedTabID,
            tabs: openTabs.map {
                EditorTabSnapshot(
                    filePath: $0.fileURL.path(percentEncoded: false),
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
            let url = URL(fileURLWithPath: item.filePath)
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
                return nil
            }

            let diskContent = (try? String(contentsOf: url, encoding: .utf8)) ?? item.content
            let tab = EditorTab(
                fileURL: url,
                content: item.content,
                lastSavedContent: item.isDirty ? diskContent : item.content,
                isDirty: item.isDirty
            )
            attachObserver(to: tab)
            return tab
        }

        openTabs = restoredTabs
        selectedFileID = snapshot.selectedFilePath
        selectedTabID = snapshot.selectedTabPath ?? restoredTabs.first?.id
    }

    private func replaceTab(_ oldTab: EditorTab, withContent content: String, lastSavedContent: String, isDirty: Bool) {
        guard let index = openTabs.firstIndex(where: { $0.id == oldTab.id }) else { return }

        let updated = EditorTab(
            fileURL: oldTab.fileURL,
            content: content,
            lastSavedContent: lastSavedContent,
            isDirty: isDirty
        )

        attachObserver(to: updated)
        openTabs[index] = updated
        if selectedTabID == oldTab.id {
            selectedTabID = updated.id
        }
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
}
