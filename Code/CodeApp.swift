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
    @StateObject private var externalFileRouter = ExternalFileRouter.shared
    @StateObject private var searchController = EditorSearchController()

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneView(
                preferences: preferences,
                sessionRegistry: sessionRegistry,
                externalFileRouter: externalFileRouter,
                searchController: searchController
            )
        }
        .commands {
            EditorCommands(
                preferences: preferences,
                searchController: searchController,
                openNewWindow: { openWindow(id: "workspace") }
            )
        }
    }
}

private struct WorkspaceSceneView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var sessionRegistry: WorkspaceSessionRegistry
    @ObservedObject var externalFileRouter: ExternalFileRouter
    @ObservedObject var searchController: EditorSearchController
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("workspaceSessionID") private var workspaceSessionID = ""
    @State private var bootstrapSessionID: String

    init(
        preferences: AppPreferences,
        sessionRegistry: WorkspaceSessionRegistry,
        externalFileRouter: ExternalFileRouter,
        searchController: EditorSearchController
    ) {
        self.preferences = preferences
        self.sessionRegistry = sessionRegistry
        self.externalFileRouter = externalFileRouter
        self.searchController = searchController
        _bootstrapSessionID = State(initialValue: sessionRegistry.makeSceneBootstrapSessionID())
    }

    var body: some View {
        let effectiveSessionID = workspaceSessionID.isEmpty ? bootstrapSessionID : workspaceSessionID

        WorkspaceContentView(sessionID: effectiveSessionID)
            .id(effectiveSessionID)
            .environmentObject(preferences)
            .environmentObject(externalFileRouter)
            .environmentObject(searchController)
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
    let sessionID: String
    @StateObject private var workspace: EditorWorkspace
    @EnvironmentObject private var externalFileRouter: ExternalFileRouter

    init(sessionID: String) {
        self.sessionID = sessionID
        _workspace = StateObject(wrappedValue: EditorWorkspace(sessionStore: SessionStore(sessionID: sessionID)))
    }

    var body: some View {
        ContentView()
            .environmentObject(workspace)
            .focusedSceneValue(\.activeEditorWorkspace, workspace)
            .background(WindowDirtyStateView(isDocumentEdited: workspace.hasDirtyTabs))
            .background(WindowCloseInterceptorView(workspace: workspace))
            .onAppear {
                openPendingExternalFiles()
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
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalFileRouter.shared.enqueue(urls: urls)
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

    func consumePendingFiles() -> [URL] {
        let files = pendingFiles
        pendingFiles.removeAll()
        return files
    }
}

private struct EditorCommands: Commands {
    @FocusedValue(\.activeEditorWorkspace) private var workspace
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var searchController: EditorSearchController
    let openNewWindow: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                workspace?.createUntitledTab()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(workspace == nil)

            Button("New Window") {
                openNewWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open File...") {
                workspace?.chooseFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(workspace == nil)

            Button("Open Folder...") {
                workspace?.chooseRootFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Save") {
                workspace?.saveSelectedTab()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(workspace?.selectedTab == nil)

            Button("Toggle Line Comment") {
                ActiveEditorTextViewRegistry.shared.toggleLineComment()
            }
            .keyboardShortcut("/", modifiers: [.command])
            .disabled(workspace?.selectedTab == nil)
        }

        CommandGroup(after: .textFormatting) {
            Button("Increase Font Size") {
                preferences.increaseEditorFontSize()
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Decrease Font Size") {
                preferences.decreaseEditorFontSize()
            }
            .keyboardShortcut("-", modifiers: [.command])
        }

        CommandMenu("Find") {
            Button("Find...") {
                searchController.showFind()
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Replace...") {
                searchController.showReplace()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button("Find Next") {
                searchController.findNext()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(workspace?.selectedTab == nil)

            Button("Find Previous") {
                searchController.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTab == nil)

            Divider()

            Button("Use Selection for Find") {
                searchController.useSelectionForFind()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(workspace?.selectedTab == nil)
        }

        CommandGroup(after: .sidebar) {
            Toggle("Word Wrap", isOn: Binding(
                get: { preferences.isWordWrapEnabled },
                set: { preferences.isWordWrapEnabled = $0 }
            ))
            .keyboardShortcut("z", modifiers: [.option, .command])
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

private final class WindowCloseInterceptingView: NSView {
    weak var workspace: EditorWorkspace?
    private let delegateProxy = WindowCloseDelegateProxy()
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let window = unsafe self.window else { return }
        guard observedWindow !== window else { return }

        observedWindow = window
        unsafe delegateProxy.originalDelegate = window.delegate
        delegateProxy.shouldAllowWindowClose = { [weak self] in
            guard let self, let workspace = self.workspace else { return true }
            guard workspace.selectedTab != nil else { return true }

            workspace.requestCloseSelectedTab()
            return false
        }
        window.delegate = delegateProxy
    }
}

private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var originalDelegate: (NSObjectProtocol & NSWindowDelegate)?
    var shouldAllowWindowClose: (() -> Bool)?

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
        guard shouldAllowWindowClose?() ?? true else {
            return false
        }

        return unsafe originalDelegate?.windowShouldClose?(sender) ?? true
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
