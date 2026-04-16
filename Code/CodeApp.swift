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
    @StateObject private var preferences = AppPreferences()
    @StateObject private var sessionRegistry = WorkspaceSessionRegistry()
    @StateObject private var activeWorkspaceRegistry = ActiveWorkspaceRegistry.shared
    @StateObject private var detachedTabTransfer = DetachedTabTransferCoordinator.shared
    @StateObject private var externalFileRouter = ExternalFileRouter.shared
    @StateObject private var searchController = EditorSearchController()
    @StateObject private var aboutController = AboutOverlayController()
    @StateObject private var settingsController = SettingsPopoverController()
    @StateObject private var updateCenter = AppUpdateCenter.shared

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneView(
                preferences: preferences,
                sessionRegistry: sessionRegistry,
                activeWorkspaceRegistry: activeWorkspaceRegistry,
                detachedTabTransfer: detachedTabTransfer,
                externalFileRouter: externalFileRouter,
                searchController: searchController,
                aboutController: aboutController,
                settingsController: settingsController,
                updateCenter: updateCenter
            )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            EditorCommands(
                preferences: preferences,
                searchController: searchController,
                aboutController: aboutController,
                settingsController: settingsController,
                updateCenter: updateCenter,
                activeWorkspaceRegistry: activeWorkspaceRegistry,
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
    }
}

private struct WorkspaceSceneView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var sessionRegistry: WorkspaceSessionRegistry
    @ObservedObject var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @ObservedObject var detachedTabTransfer: DetachedTabTransferCoordinator
    @ObservedObject var externalFileRouter: ExternalFileRouter
    @ObservedObject var searchController: EditorSearchController
    @ObservedObject var aboutController: AboutOverlayController
    @ObservedObject var settingsController: SettingsPopoverController
    @ObservedObject var updateCenter: AppUpdateCenter
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("workspaceSessionID") private var workspaceSessionID = ""
    @State private var bootstrapSessionID: String

    init(
        preferences: AppPreferences,
        sessionRegistry: WorkspaceSessionRegistry,
        activeWorkspaceRegistry: ActiveWorkspaceRegistry,
        detachedTabTransfer: DetachedTabTransferCoordinator,
        externalFileRouter: ExternalFileRouter,
        searchController: EditorSearchController,
        aboutController: AboutOverlayController,
        settingsController: SettingsPopoverController,
        updateCenter: AppUpdateCenter
    ) {
        self.preferences = preferences
        self.sessionRegistry = sessionRegistry
        self.activeWorkspaceRegistry = activeWorkspaceRegistry
        self.detachedTabTransfer = detachedTabTransfer
        self.externalFileRouter = externalFileRouter
        self.searchController = searchController
        self.aboutController = aboutController
        self.settingsController = settingsController
        self.updateCenter = updateCenter
        _bootstrapSessionID = State(initialValue: sessionRegistry.makeSceneBootstrapSessionID())
    }

    var body: some View {
        let effectiveSessionID = workspaceSessionID.isEmpty ? bootstrapSessionID : workspaceSessionID

        WorkspaceContentView(sessionID: effectiveSessionID)
            .id(effectiveSessionID)
            .environmentObject(preferences)
            .environmentObject(activeWorkspaceRegistry)
            .environmentObject(detachedTabTransfer)
            .environmentObject(externalFileRouter)
            .environmentObject(searchController)
            .environmentObject(aboutController)
            .environmentObject(settingsController)
            .environmentObject(updateCenter)
            .onAppear {
                if workspaceSessionID.isEmpty {
                    workspaceSessionID = effectiveSessionID
                }
                sessionRegistry.markFocused(sessionID: effectiveSessionID)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    sessionRegistry.markFocused(sessionID: effectiveSessionID)
                }
            }
    }
}

private struct WorkspaceContentView: View {
    @StateObject private var workspace: EditorWorkspace
    @EnvironmentObject private var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    @EnvironmentObject private var detachedTabTransfer: DetachedTabTransferCoordinator
    @EnvironmentObject private var externalFileRouter: ExternalFileRouter

    init(sessionID: String) {
        let hasPendingFiles = ExternalFileRouter.shared.hasPendingFiles()
        _workspace = StateObject(wrappedValue: EditorWorkspace(
            sessionStore: SessionStore(sessionID: sessionID),
            skipUntitledIfPendingFiles: hasPendingFiles
        ))
    }

    var body: some View {
        ContentView()
            .frame(minWidth: 500, minHeight: 500)
            .environmentObject(workspace)
            .focusedSceneValue(\.activeEditorWorkspace, workspace)
            .background(WindowDirtyStateView(isDocumentEdited: workspace.hasDirtyTabs))
            .background(WindowCloseInterceptorView(workspace: workspace))
            .background(ActiveWorkspaceTrackingView(workspace: workspace))
            .onAppear {
                adoptDetachedTabIfNeeded()
                openPendingExternalFiles()
            }
            .onDisappear {
                activeWorkspaceRegistry.clearIfNeeded(workspace)
                workspace.flushSession()
            }
            .onChange(of: externalFileRouter.pendingRequestID) { _, _ in
                openPendingExternalFiles()
            }
    }

    private func openPendingExternalFiles() {
        let urls = externalFileRouter.consumePendingFiles()
        guard !urls.isEmpty else { return }

        for url in urls {
            workspace.openFile(url)
        }
    }

    private func adoptDetachedTabIfNeeded() {
        guard let tab = detachedTabTransfer.consumePendingTab() else { return }
        workspace.adoptTransferredTab(tab)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalFileRouter.shared.enqueue(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
    }
}

@MainActor
final class ExternalFileRouter: ObservableObject {
    static let shared = ExternalFileRouter()

    @Published private(set) var pendingRequestID = UUID()
    private var pendingFiles: [URL] = []

    func enqueue(urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !fileURLs.isEmpty else { return }

        pendingFiles.append(contentsOf: fileURLs)
        pendingRequestID = UUID()
    }

    func hasPendingFiles() -> Bool {
        !pendingFiles.isEmpty
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

private struct EditorCommands: Commands {
    @FocusedValue(\.activeEditorWorkspace) private var workspace
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var searchController: EditorSearchController
    @ObservedObject var aboutController: AboutOverlayController
    @ObservedObject var settingsController: SettingsPopoverController
    @ObservedObject var updateCenter: AppUpdateCenter
    @ObservedObject var activeWorkspaceRegistry: ActiveWorkspaceRegistry
    let openNewWindow: () -> Void

    private var resolvedWorkspace: EditorWorkspace? {
        activeWorkspaceRegistry.workspace ?? workspace
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

            Button {
                resolvedWorkspace?.closeFolder()
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

        CommandGroup(after: .textFormatting) {
            Button {
                preferences.increaseEditorFontSize()
            } label: {
                Label("Increase Font Size", systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button {
                preferences.decreaseEditorFontSize()
            } label: {
                Label("Decrease Font Size", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: [.command])
        }

        CommandMenu("Find") {
            Button {
                searchController.showFind()
            } label: {
                Label("Find...", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button {
                searchController.showReplace()
            } label: {
                Label("Replace...", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button {
                searchController.findNext()
            } label: {
                Label("Find Next", systemImage: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Button {
                searchController.findPrevious()
            } label: {
                Label("Find Previous", systemImage: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(resolvedWorkspace?.selectedTab == nil)

            Divider()

            Button {
                searchController.useSelectionForFind()
            } label: {
                Label("Use Selection for Find", systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(resolvedWorkspace?.selectedTab == nil)
        }

        CommandGroup(after: .sidebar) {
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
    @EnvironmentObject private var activeWorkspaceRegistry: ActiveWorkspaceRegistry

    func makeNSView(context: Context) -> ActiveWorkspaceTrackingNSView {
        let view = ActiveWorkspaceTrackingNSView()
        view.registry = activeWorkspaceRegistry
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: ActiveWorkspaceTrackingNSView, context: Context) {
        nsView.registry = activeWorkspaceRegistry
        nsView.workspace = workspace
        nsView.attachIfNeeded()
    }
}

private final class ActiveWorkspaceTrackingNSView: NSView {
    weak var registry: ActiveWorkspaceRegistry?
    weak var workspace: EditorWorkspace?
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
    }

    private func promoteWorkspace() {
        guard let workspace else { return }
        registry?.setActive(workspace)
    }

    private func detachNotifications() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
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
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let window = unsafe self.window else { return }
        guard observedWindow !== window else { return }

        detachCommandWMonitor()
        observedWindow = window
        unsafe delegateProxy.originalDelegate = window.delegate
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
    nonisolated(unsafe) weak var originalDelegate: (NSObjectProtocol & NSWindowDelegate)?
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
