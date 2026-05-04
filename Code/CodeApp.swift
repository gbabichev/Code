//
//  CodeApp.swift
//  Code
//
//  Created by George Babichev on 4/5/26.
//

import AppKit
import Combine
import SwiftUI

@main
struct CodeApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = AppPreferences.shared
    @StateObject private var sessionRegistry = WorkspaceSessionRegistry()
    @StateObject private var activeWorkspaceRegistry = ActiveWorkspaceRegistry.shared
    @StateObject private var workspacePersistenceRegistry = WorkspacePersistenceRegistry.shared
    @StateObject private var detachedTabTransfer = DetachedTabTransferCoordinator.shared
    @StateObject private var externalFileRouter = ExternalFileRouter.shared
    @StateObject private var recentItemRouter = RecentItemRouter.shared
    @StateObject private var dockCommandRouter = DockCommandRouter.shared
    @StateObject private var aboutController = AboutOverlayController()
    @StateObject private var settingsController = SettingsPopoverController()
    @StateObject private var updateCenter = AppUpdateCenter.shared

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneView(
                preferences: preferences,
                sessionRegistry: sessionRegistry,
                activeWorkspaceRegistry: activeWorkspaceRegistry,
                workspacePersistenceRegistry: workspacePersistenceRegistry,
                detachedTabTransfer: detachedTabTransfer,
                externalFileRouter: externalFileRouter,
                recentItemRouter: recentItemRouter,
                aboutController: aboutController,
                settingsController: settingsController,
                updateCenter: updateCenter,
                openNewWindow: { openWindow(id: "workspace") }
            )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            EditorCommands(
                preferences: preferences,
                aboutController: aboutController,
                settingsController: settingsController,
                updateCenter: updateCenter,
                activeWorkspaceRegistry: activeWorkspaceRegistry,
                workspacePersistenceRegistry: workspacePersistenceRegistry,
                openNewWindow: { openWindow(id: "workspace") }
            )
        }
        .onChange(of: externalFileRouter.pendingRequestID) { _, _ in
            // Files arrived while no window was visible — open one
            let hasVisibleWindows = NSApp.windows.contains(where: { $0.isVisible })
            if !hasVisibleWindows {
                openWindow(id: "workspace")
            }
        }
        .onChange(of: recentItemRouter.pendingRequestID) { _, _ in
            let hasVisibleWindows = NSApp.windows.contains(where: { $0.isVisible })
            if !hasVisibleWindows {
                openWindow(id: "workspace")
            }
        }
        .onChange(of: dockCommandRouter.newWindowRequestID) { _, _ in
            openWindowFromDock()
        }
        .onChange(of: dockCommandRouter.newFileRequestID) { _, _ in
            openNewFileFromDock()
        }
    }

    private func openWindowFromDock() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "workspace")
    }

    private func openNewFileFromDock() {
        NSApp.activate(ignoringOtherApps: true)

        if let workspace = activeWorkspaceRegistry.workspace {
            workspace.createUntitledTab()
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "workspace")
    }
}

private struct WorkspaceSceneView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var sessionRegistry: WorkspaceSessionRegistry
    @ObservedObject var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @ObservedObject var workspacePersistenceRegistry: WorkspacePersistenceRegistry
    @ObservedObject var detachedTabTransfer: DetachedTabTransferCoordinator
    @ObservedObject var externalFileRouter: ExternalFileRouter
    @ObservedObject var recentItemRouter: RecentItemRouter
    @ObservedObject var aboutController: AboutOverlayController
    @ObservedObject var settingsController: SettingsPopoverController
    @ObservedObject var updateCenter: AppUpdateCenter
    let openNewWindow: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("workspaceSessionID") private var workspaceSessionID = ""
    @State private var bootstrapSessionID = ""

    init(
        preferences: AppPreferences,
        sessionRegistry: WorkspaceSessionRegistry,
        activeWorkspaceRegistry: ActiveWorkspaceRegistry,
        workspacePersistenceRegistry: WorkspacePersistenceRegistry,
        detachedTabTransfer: DetachedTabTransferCoordinator,
        externalFileRouter: ExternalFileRouter,
        recentItemRouter: RecentItemRouter,
        aboutController: AboutOverlayController,
        settingsController: SettingsPopoverController,
        updateCenter: AppUpdateCenter,
        openNewWindow: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.sessionRegistry = sessionRegistry
        self.activeWorkspaceRegistry = activeWorkspaceRegistry
        self.workspacePersistenceRegistry = workspacePersistenceRegistry
        self.detachedTabTransfer = detachedTabTransfer
        self.externalFileRouter = externalFileRouter
        self.recentItemRouter = recentItemRouter
        self.aboutController = aboutController
        self.settingsController = settingsController
        self.updateCenter = updateCenter
        self.openNewWindow = openNewWindow
    }

    var body: some View {
        let effectiveSessionID = workspaceSessionID.isEmpty ? bootstrapSessionID : workspaceSessionID

        Group {
            if effectiveSessionID.isEmpty {
                Color.clear
                    .onAppear {
                        guard workspaceSessionID.isEmpty, bootstrapSessionID.isEmpty else { return }
                        bootstrapSessionID = sessionRegistry.makeSceneBootstrapSessionID()
                    }
            } else {
                WorkspaceContentView(sessionID: effectiveSessionID, preferences: preferences)
                    .id(effectiveSessionID)
                    .onAppear {
                        let wasRestoredBySceneStorage = !workspaceSessionID.isEmpty
                        if wasRestoredBySceneStorage {
                            sessionRegistry.noteRestoredSceneSession(sessionID: effectiveSessionID)
                        } else {
                            workspaceSessionID = effectiveSessionID
                        }

                        sessionRegistry.handleSceneAppear(sessionID: effectiveSessionID) { count in
                            guard count > 0 else { return }
                            for _ in 0..<count {
                                openNewWindow()
                            }
                        }
                        sessionRegistry.markFocused(sessionID: effectiveSessionID)
                    }
                    .onDisappear {
                        sessionRegistry.handleSceneDisappear(sessionID: effectiveSessionID)
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            sessionRegistry.markFocused(sessionID: effectiveSessionID)
                        }
                    }
            }
        }
        .environmentObject(preferences)
        .environmentObject(sessionRegistry)
        .environmentObject(activeWorkspaceRegistry)
        .environmentObject(workspacePersistenceRegistry)
        .environmentObject(detachedTabTransfer)
        .environmentObject(externalFileRouter)
        .environmentObject(recentItemRouter)
        .environmentObject(aboutController)
        .environmentObject(settingsController)
        .environmentObject(updateCenter)
    }
}

private struct WorkspaceContentView: View {
    let sessionID: String
    @StateObject private var workspace: EditorWorkspace
    @StateObject private var searchController = EditorSearchController()
    @EnvironmentObject private var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @EnvironmentObject private var workspacePersistenceRegistry: WorkspacePersistenceRegistry
    @EnvironmentObject private var detachedTabTransfer: DetachedTabTransferCoordinator
    @EnvironmentObject private var externalFileRouter: ExternalFileRouter
    @EnvironmentObject private var recentItemRouter: RecentItemRouter
    @EnvironmentObject private var preferences: AppPreferences

    init(sessionID: String, preferences: AppPreferences) {
        self.sessionID = sessionID
        let hasPendingExternalOpen = ExternalFileRouter.shared.hasPendingFiles()
            || RecentItemRouter.shared.hasPendingItems()
        _workspace = StateObject(wrappedValue: EditorWorkspace(
            preferences: preferences,
            sessionStore: SessionStore(sessionID: sessionID),
            skipUntitledIfPendingFiles: hasPendingExternalOpen
        ))
    }

    var body: some View {
        ContentView()
            .frame(minWidth: 500, minHeight: 500)
            .environmentObject(workspace)
            .environmentObject(searchController)
            .focusedSceneValue(\.activeEditorWorkspace, workspace)
            .focusedSceneValue(\.activeEditorSearchController, searchController)
            .background(WindowDirtyStateView(isDocumentEdited: workspace.hasDirtyTabs))
            .background(WindowCloseInterceptorView(workspace: workspace))
            .background(ActiveWorkspaceTrackingView(
                workspace: workspace,
                sessionID: sessionID
            ))
            .onAppear {
                workspacePersistenceRegistry.register(workspace)
                adoptDetachedTabIfNeeded()
                openPendingExternalFiles()
                openPendingRecentItems()
            }
            .onDisappear {
                workspacePersistenceRegistry.unregister(workspace)
                activeWorkspaceRegistry.clearIfNeeded(workspace)
                workspace.flushSession()
            }
            .onChange(of: externalFileRouter.pendingRequestID) { _, _ in
                openPendingExternalFiles()
            }
            .onChange(of: recentItemRouter.pendingRequestID) { _, _ in
                openPendingRecentItems()
            }
    }

    private func openPendingExternalFiles() {
        let folders = externalFileRouter.consumePendingFolders()
        let urls = externalFileRouter.consumePendingFiles()
        guard !folders.isEmpty || !urls.isEmpty else { return }

        for folderURL in folders {
            workspace.setRootFolder(folderURL)
        }

        for url in urls {
            workspace.openFile(url)
        }
    }

    private func openPendingRecentItems() {
        let items = recentItemRouter.consumePendingItems()
        guard !items.isEmpty else { return }

        for item in items {
            openRecentItem(item)
        }
    }

    private func openRecentItem(_ item: RecentItem) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            preferences.removeRecentItem(item)
            preferences.errorMessage = "Recent item no longer exists: \(item.path)"
            return
        }

        switch item.kind {
        case .file:
            workspace.openFile(item.url)
        case .folder:
            workspace.setRootFolder(item.url)
        }
    }

    private func adoptDetachedTabIfNeeded() {
        guard let tab = detachedTabTransfer.consumePendingTab() else { return }
        workspace.adoptTransferredTab(tab)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let recentItems = AppPreferences.shared.visibleRecentItems

        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(openDockNewWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        newWindowItem.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
        menu.addItem(newWindowItem)

        let newFileItem = NSMenuItem(
            title: "New File",
            action: #selector(openDockNewFile(_:)),
            keyEquivalent: ""
        )
        newFileItem.target = self
        newFileItem.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        menu.addItem(newFileItem)

        menu.addItem(.separator())

        if recentItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return menu
        }

        for item in recentItems {
            let menuItem = NSMenuItem(
                title: item.menuTitle,
                action: #selector(openDockRecentItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = item.id
            menuItem.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
            menu.addItem(menuItem)
        }

        let clearItem = NSMenuItem(
            title: "Clear Recents",
            action: #selector(clearDockRecentItems(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    @objc private func openDockNewWindow(_ sender: NSMenuItem) {
        DockCommandRouter.shared.requestNewWindow()
    }

    @objc private func openDockNewFile(_ sender: NSMenuItem) {
        DockCommandRouter.shared.requestNewFile()
    }

    @objc private func openDockRecentItem(_ sender: NSMenuItem) {
        guard
            let itemID = sender.representedObject as? String,
            let item = AppPreferences.shared.recentItems.first(where: { $0.id == itemID })
        else {
            return
        }

        guard FileManager.default.fileExists(atPath: item.path) else {
            AppPreferences.shared.removeRecentItem(item)
            AppPreferences.shared.errorMessage = "Recent item no longer exists: \(item.path)"
            return
        }

        if let workspace = ActiveWorkspaceRegistry.shared.workspace {
            NSApp.activate(ignoringOtherApps: true)
            openRecentItem(item, in: workspace)
            return
        }

        RecentItemRouter.shared.enqueue(item)
    }

    @objc private func clearDockRecentItems(_ _: NSMenuItem) {
        AppPreferences.shared.clearRecentItems()
    }

    private func openRecentItem(_ item: RecentItem, in workspace: EditorWorkspace) {
        switch item.kind {
        case .file:
            workspace.openFile(item.url)
        case .folder:
            workspace.setRootFolder(item.url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalFileRouter.shared.enqueue(urls: urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationLifecycleState.shared.markTerminating()
        WorkspacePersistenceRegistry.shared.flushAllSessions()
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
    }
}

@MainActor
final class DockCommandRouter: ObservableObject {
    static let shared = DockCommandRouter()

    @Published private(set) var newWindowRequestID = UUID()
    @Published private(set) var newFileRequestID = UUID()

    func requestNewWindow() {
        newWindowRequestID = UUID()
    }

    func requestNewFile() {
        newFileRequestID = UUID()
    }
}

@MainActor
final class ExternalFileRouter: ObservableObject {
    static let shared = ExternalFileRouter()

    @Published private(set) var pendingRequestID = UUID()
    private var pendingFiles: [URL] = []
    private var pendingFolders: [URL] = []

    func enqueue(urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        let folders = fileURLs.filter(isDirectory)
        let files = fileURLs.filter { !isDirectory($0) }
        guard !files.isEmpty || !folders.isEmpty else { return }

        pendingFiles.append(contentsOf: files)
        pendingFolders.append(contentsOf: folders)
        pendingRequestID = UUID()
    }

    func hasPendingFiles() -> Bool {
        !pendingFiles.isEmpty || !pendingFolders.isEmpty
    }

    @MainActor
    func consumePendingFiles() -> [URL] {
        let files = pendingFiles
        pendingFiles.removeAll()

        // Activate the app and bring window to front
        if !files.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        return files
    }

    @MainActor
    func consumePendingFolders() -> [URL] {
        let folders = pendingFolders
        pendingFolders.removeAll()

        if !folders.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        return folders
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }
}

@MainActor
final class RecentItemRouter: ObservableObject {
    static let shared = RecentItemRouter()

    @Published private(set) var pendingRequestID = UUID()
    private var pendingItems: [RecentItem] = []

    func enqueue(_ item: RecentItem) {
        pendingItems.append(item)
        pendingRequestID = UUID()
    }

    func hasPendingItems() -> Bool {
        !pendingItems.isEmpty
    }

    func consumePendingItems() -> [RecentItem] {
        let items = pendingItems
        pendingItems.removeAll()

        if !items.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        return items
    }
}

@MainActor
final class DetachedTabTransferCoordinator: ObservableObject {
    static let shared = DetachedTabTransferCoordinator()

    private var pendingTab: EditorTab?

    func store(_ tab: EditorTab) {
        pendingTab = tab
    }

    func consumePendingTab() -> EditorTab? {
        let tab = pendingTab
        pendingTab = nil
        return tab
    }
}

@MainActor
final class AboutOverlayController: ObservableObject {
    @Published var isPresented = false

    func present() {
        isPresented = true
    }
}

@MainActor
final class SettingsPopoverController: ObservableObject {
    @Published var isPresented = false

    func present() {
        isPresented = true
    }
}

@MainActor
final class ActiveWorkspaceRegistry: ObservableObject {
    static let shared = ActiveWorkspaceRegistry()

    @Published private(set) var activeWorkspaceID: ObjectIdentifier?
    private weak var workspaceReference: EditorWorkspace?
    private var workspaceObserver: AnyCancellable?

    var workspace: EditorWorkspace? {
        workspaceReference
    }

    func setActive(_ workspace: EditorWorkspace) {
        if workspaceReference === workspace {
            return
        }

        workspaceObserver = nil
        workspaceReference = workspace
        DispatchQueue.main.async { [weak self, weak workspace] in
            guard let self, let workspace, self.workspaceReference === workspace else { return }
            self.activeWorkspaceID = ObjectIdentifier(workspace)
        }
        workspaceObserver = workspace.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    func clearIfNeeded(_ workspace: EditorWorkspace) {
        guard workspaceReference === workspace else { return }
        workspaceObserver = nil
        workspaceReference = nil
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkspaceID = nil
        }
    }
}

@MainActor
final class WorkspacePersistenceRegistry: ObservableObject {
    static let shared = WorkspacePersistenceRegistry()

    private let workspaces = NSHashTable<EditorWorkspace>.weakObjects()

    func register(_ workspace: EditorWorkspace) {
        workspaces.add(workspace)
    }

    func unregister(_ workspace: EditorWorkspace) {
        workspaces.remove(workspace)
    }

    func flushAllSessions() {
        for workspace in workspaces.allObjects {
            workspace.flushSession()
        }
    }
}

private struct EditorCommands: Commands {
    @FocusedValue(\.activeEditorWorkspace) private var workspace
    @FocusedValue(\.activeEditorSearchController) private var searchController
    @State private var isCommandLineToolInstalled = CommandLineToolInstaller.canRemoveInstalledTool
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var aboutController: AboutOverlayController
    @ObservedObject var settingsController: SettingsPopoverController
    @ObservedObject var updateCenter: AppUpdateCenter
    @ObservedObject var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @ObservedObject var workspacePersistenceRegistry: WorkspacePersistenceRegistry
    let openNewWindow: () -> Void

    private var resolvedWorkspace: EditorWorkspace? {
        activeWorkspaceRegistry.workspace ?? workspace
    }

    private func openRecentItem(_ item: RecentItem) {
        guard let resolvedWorkspace else { return }

        guard FileManager.default.fileExists(atPath: item.path) else {
            preferences.removeRecentItem(item)
            preferences.errorMessage = "Recent item no longer exists: \(item.path)"
            return
        }

        switch item.kind {
        case .file:
            resolvedWorkspace.openFile(item.url)
        case .folder:
            resolvedWorkspace.setRootFolder(item.url)
        }
    }

    private func refreshCommandLineToolState() {
        isCommandLineToolInstalled = CommandLineToolInstaller.canRemoveInstalledTool
    }

    private func installCommandLineTool() {
        Task { @MainActor in
            await CommandLineToolInstaller.installFromMenu()
            refreshCommandLineToolState()
        }
    }

    private func uninstallCommandLineTool() {
        Task { @MainActor in
            await CommandLineToolInstaller.removeFromMenu()
            refreshCommandLineToolState()
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                settingsController.present()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(replacing: .appInfo) {
            Button {
                aboutController.present()
            } label: {
                Label("About Code", systemImage: "info.circle")
            }

            Button {
                updateCenter.checkForUpdates(trigger: .manual)
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .disabled(updateCenter.isChecking)

            Divider()

            if isCommandLineToolInstalled {
                Button {
                    uninstallCommandLineTool()
                } label: {
                    Label("Uninstall Command Line Tool…", systemImage: "trash")
                }
            } else {
                Button {
                    installCommandLineTool()
                } label: {
                    Label("Install Command Line Tool…", systemImage: "terminal")
                }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button {
                resolvedWorkspace?.createUntitledTab()
            } label: {
                Label("New Tab", systemImage: "plus.square.on.square")
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(resolvedWorkspace == nil)

            Button {
                openNewWindow()
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button {
                resolvedWorkspace?.chooseFile()
            } label: {
                Label("Open File...", systemImage: "doc")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(resolvedWorkspace == nil)

            Button {
                resolvedWorkspace?.chooseRootFolder()
            } label: {
                Label("Open Folder...", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(resolvedWorkspace == nil)

            Menu {
                if preferences.visibleRecentItems.isEmpty {
                    Button("No Recent Items") {
                    }
                    .disabled(true)
                } else {
                    ForEach(preferences.visibleRecentItems) { item in
                        Button {
                            openRecentItem(item)
                        } label: {
                            Label(item.menuTitle, systemImage: item.systemImage)
                        }
                    }

                    Divider()

                    Button("Clear Recents", role: .destructive) {
                        preferences.clearRecentItems()
                    }
                }
            } label: {
                Label("Recent Items", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            .disabled(resolvedWorkspace == nil)

            Button {
                resolvedWorkspace?.requestCloseFolder()
            } label: {
                Label("Close Folder", systemImage: "folder.badge.minus")
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(resolvedWorkspace?.rootFolderURL == nil)

            Divider()

            Button {
                resolvedWorkspace?.requestRefreshSelectedFile()
            } label: {
                Label("Refresh File", systemImage: "arrow.clockwise")
            }
            .disabled(!(resolvedWorkspace?.canRefreshSelectedFile ?? false))
        }

        CommandGroup(after: .saveItem) {
            Button {
                resolvedWorkspace?.reopenLastClosedTab()
            } label: {
                Label("Reopen Closed Tab", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!(resolvedWorkspace?.canReopenClosedTab ?? false))

            Divider()

            Button {
                Task {
                    await resolvedWorkspace?.saveSelectedTab()
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Button {
                Task {
                    await resolvedWorkspace?.saveSelectedTabAs()
                }
            } label: {
                Label("Save As...", systemImage: "square.and.arrow.down.on.square")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Divider()

            Button {
                resolvedWorkspace?.requestCloseSelectedTab()
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button {
                ActiveEditorTextViewRegistry.shared.toggleLineComment()
            } label: {
                Label("Toggle Line Comment", systemImage: "text.append")
            }
            .keyboardShortcut("/", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Button {
                ActiveEditorTextViewRegistry.shared.indentSelection()
            } label: {
                Label("Indent", systemImage: "increase.indent")
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Button {
                ActiveEditorTextViewRegistry.shared.outdentSelection()
            } label: {
                Label("Outdent", systemImage: "decrease.indent")
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)
        }

        CommandMenu("Find") {
            Button {
                searchController?.showFind()
            } label: {
                Label("Find...", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(searchController == nil)

            Button {
                searchController?.showReplace()
            } label: {
                Label("Replace...", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(searchController == nil)

            Divider()

            Button {
                searchController?.findNext()
            } label: {
                Label("Find Next", systemImage: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil || searchController == nil)

            Button {
                searchController?.findPrevious()
            } label: {
                Label("Find Previous", systemImage: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(resolvedWorkspace?.selectedTab == nil || searchController == nil)

            Divider()

            Button {
                searchController?.useSelectionForFind()
            } label: {
                Label("Use Selection for Find", systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil || searchController == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                preferences.increaseEditorFontSize()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button {
                preferences.decreaseEditorFontSize()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button {
                preferences.resetEditorFontSize()
            } label: {
                Label("Reset Zoom", systemImage: "textformat.size")
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Toggle(isOn: Binding(
                get: { preferences.isWordWrapEnabled },
                set: { preferences.isWordWrapEnabled = $0 }
            )) {
                Label("Word Wrap", systemImage: "text.justify.left")
            }
            .keyboardShortcut("z", modifiers: [.option, .command])
        }

        CommandGroup(replacing: .appTermination) {
            Button {
                ApplicationLifecycleState.shared.markTerminating()
                workspacePersistenceRegistry.flushAllSessions()
                NSApp.terminate(nil)
            } label: {
                Label("Quit Code", systemImage: "xmark.circle")
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

private struct ActiveEditorWorkspaceKey: FocusedValueKey {
    typealias Value = EditorWorkspace
}

private extension FocusedValues {
    var activeEditorWorkspace: EditorWorkspace? {
        get { self[ActiveEditorWorkspaceKey.self] }
        set { self[ActiveEditorWorkspaceKey.self] = newValue }
    }

    var activeEditorSearchController: EditorSearchController? {
        get { self[ActiveEditorSearchControllerKey.self] }
        set { self[ActiveEditorSearchControllerKey.self] = newValue }
    }
}

private struct ActiveEditorSearchControllerKey: FocusedValueKey {
    typealias Value = EditorSearchController
}

private struct WindowDirtyStateView: NSViewRepresentable {
    let isDocumentEdited: Bool

    func makeNSView(context: Context) -> DirtyStateObserverView {
        DirtyStateObserverView()
    }

    func updateNSView(_ nsView: DirtyStateObserverView, context: Context) {
        nsView.isDocumentEdited = isDocumentEdited
        nsView.applyDirtyStateIfPossible()
    }
}

private final class DirtyStateObserverView: NSView {
    var isDocumentEdited = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDirtyStateIfPossible()
    }

    func applyDirtyStateIfPossible() {
        guard let window = unsafe self.window else { return }
        if window.isDocumentEdited != isDocumentEdited {
            window.isDocumentEdited = isDocumentEdited
        }
    }
}

private struct WindowCloseInterceptorView: NSViewRepresentable {
    @ObservedObject var workspace: EditorWorkspace

    func makeNSView(context: Context) -> WindowCloseInterceptingView {
        let view = WindowCloseInterceptingView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: WindowCloseInterceptingView, context: Context) {
        nsView.workspace = workspace
        nsView.attachIfNeeded()
    }
}

private struct ActiveWorkspaceTrackingView: NSViewRepresentable {
    @ObservedObject var workspace: EditorWorkspace
    let sessionID: String
    @EnvironmentObject private var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @EnvironmentObject private var sessionRegistry: WorkspaceSessionRegistry

    func makeNSView(context: Context) -> ActiveWorkspaceTrackingNSView {
        let view = ActiveWorkspaceTrackingNSView()
        view.registry = activeWorkspaceRegistry
        view.sessionRegistry = sessionRegistry
        view.workspace = workspace
        view.sessionID = sessionID
        return view
    }

    func updateNSView(_ nsView: ActiveWorkspaceTrackingNSView, context: Context) {
        nsView.registry = activeWorkspaceRegistry
        nsView.sessionRegistry = sessionRegistry
        nsView.workspace = workspace
        nsView.sessionID = sessionID
        nsView.attachIfNeeded()
    }
}

private final class ActiveWorkspaceTrackingNSView: NSView {
    weak var registry: ActiveWorkspaceRegistry?
    weak var sessionRegistry: WorkspaceSessionRegistry?
    weak var workspace: EditorWorkspace?
    var sessionID = ""
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attachIfNeeded() {
        guard let window = unsafe self.window else { return }
        guard observedWindow !== window else { return }

        detachNotifications()
        observedWindow = window

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )

        if window.isKeyWindow || window.isMainWindow {
            promoteWorkspace()
        }
    }

    @objc
    private func handleWindowDidBecomeKey(_: Notification) {
        promoteWorkspace()
    }

    @objc
    private func handleWindowDidBecomeMain(_: Notification) {
        promoteWorkspace()
    }

    @objc
    private func handleWindowWillClose(_: Notification) {
        if let workspace {
            registry?.clearIfNeeded(workspace)
        }
        sessionRegistry?.handleWindowWillClose(sessionID: sessionID)
    }

    @objc
    private func handleApplicationDidBecomeActive(_: Notification) {
        guard let observedWindow else { return }
        guard observedWindow.isKeyWindow || observedWindow.isMainWindow else { return }
        promoteWorkspace()
    }

    private func promoteWorkspace() {
        guard let workspace else { return }
        workspace.synchronizeCleanTabsWithDisk()
        registry?.setActive(workspace)
    }

    private func detachNotifications() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        } else {
            NotificationCenter.default.removeObserver(self)
        }
        observedWindow = nil
    }
}

private final class WindowCloseInterceptingView: NSView {
    weak var workspace: EditorWorkspace?
    private let delegateProxy = WindowCloseDelegateProxy()
    private weak var observedWindow: NSWindow?
    private var commandWMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard unsafe self.window != nil else {
            detachFromObservedWindow()
            return
        }
        attachIfNeeded()
    }

    deinit {
        MainActor.assumeIsolated {
            detachFromObservedWindow()
        }
    }

    func attachIfNeeded() {
        guard let window = unsafe self.window else { return }
        guard observedWindow !== window else { return }

        detachFromObservedWindow()
        observedWindow = window
        if window.delegate !== delegateProxy {
            unsafe delegateProxy.originalDelegate = window.delegate
        }
        delegateProxy.shouldAllowWindowClose = { [weak self] _ in
            guard let self, let workspace = self.workspace else { return true }

            if workspace.hasDirtyTabs {
                workspace.requestWindowClose { [weak self] in
                    guard let self, let window = self.observedWindow else { return }
                    self.delegateProxy.performDeferredWindowClose(for: window)
                }
                return false
            }

            return true
        }
        window.delegate = delegateProxy
        commandWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isCommandW(event) else { return event }
            guard self.observedWindow?.isKeyWindow == true else { return event }
            guard let workspace = self.workspace, workspace.selectedTab != nil else { return event }

            workspace.requestCloseSelectedTab()
            return nil
        }
    }

    private func detachFromObservedWindow() {
        detachCommandWMonitor()
        if let observedWindow, observedWindow.delegate === delegateProxy {
            unsafe observedWindow.delegate = delegateProxy.originalDelegate
        }
        delegateProxy.reset()
        observedWindow = nil
    }

    private func detachCommandWMonitor() {
        if let commandWMonitor {
            NSEvent.removeMonitor(commandWMonitor)
            self.commandWMonitor = nil
        }
    }

    private func isCommandW(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command] && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}

private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) var originalDelegate: (NSObjectProtocol & NSWindowDelegate)?
    var shouldAllowWindowClose: ((NSWindow) -> Bool)?
    private var shouldBypassNextClose = false

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (unsafe originalDelegate?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if unsafe originalDelegate?.responds(to: aSelector) == true {
            return unsafe originalDelegate
        }

        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldBypassNextClose {
            shouldBypassNextClose = false
            return unsafe originalDelegate?.windowShouldClose?(sender) ?? true
        }

        guard shouldAllowWindowClose?(sender) ?? true else {
            return false
        }

        return unsafe originalDelegate?.windowShouldClose?(sender) ?? true
    }

    func performDeferredWindowClose(for window: NSWindow) {
        shouldBypassNextClose = true
        DispatchQueue.main.async {
            window.performClose(nil)
            if window.isVisible {
                window.close()
            }
        }
    }

    func reset() {
        unsafe originalDelegate = nil
        shouldAllowWindowClose = nil
        shouldBypassNextClose = false
    }
}

@MainActor
final class EditorSearchController: ObservableObject {
    enum Command {
        case showFind
        case showReplace
        case findNext
        case findPrevious
        case useSelectionForFind
    }

    @Published var isPresented = false
    @Published var isReplaceVisible = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var isCaseSensitive = false
    @Published private(set) var eventID = UUID()
    private(set) var lastCommand: Command = .showFind

    func showFind() {
        isPresented = true
        isReplaceVisible = false
        lastCommand = .showFind
        eventID = UUID()
    }

    func showReplace() {
        isPresented = true
        isReplaceVisible = true
        lastCommand = .showReplace
        eventID = UUID()
    }

    func hide() {
        isPresented = false
    }

    func findNext() {
        guard isPresented else {
            showFind()
            return
        }
        lastCommand = .findNext
        eventID = UUID()
    }

    func findPrevious() {
        guard isPresented else {
            showFind()
            return
        }
        lastCommand = .findPrevious
        eventID = UUID()
    }

    func useSelectionForFind() {
        guard let textView = ActiveEditorTextViewRegistry.shared.textView else { return }
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else { return }
        let text = textView.string as NSString
        query = text.substring(with: selectedRange)
        if !isPresented {
            isPresented = true
        }
        lastCommand = .useSelectionForFind
        eventID = UUID()
    }
}
