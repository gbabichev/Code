//
//  CodeApp.swift
//  Code
//
//  Created by George Babichev on 4/5/26.
//

import AppKit
import SwiftUI

@main
struct CodeApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var preferences = AppPreferences()
    @StateObject private var sessionRegistry = WorkspaceSessionRegistry()

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceSceneView(
                preferences: preferences,
                sessionRegistry: sessionRegistry
            )
        }
        .commands {
            EditorCommands(
                preferences: preferences,
                openNewWindow: { openWindow(id: "workspace") }
            )
        }
    }
}

private struct WorkspaceSceneView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var sessionRegistry: WorkspaceSessionRegistry
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("workspaceSessionID") private var workspaceSessionID = ""
    @State private var bootstrapSessionID: String

    init(
        preferences: AppPreferences,
        sessionRegistry: WorkspaceSessionRegistry
    ) {
        self.preferences = preferences
        self.sessionRegistry = sessionRegistry
        _bootstrapSessionID = State(initialValue: sessionRegistry.makeSceneBootstrapSessionID())
    }

    var body: some View {
        let effectiveSessionID = workspaceSessionID.isEmpty ? bootstrapSessionID : workspaceSessionID

        WorkspaceContentView(sessionID: effectiveSessionID)
            .id(effectiveSessionID)
            .environmentObject(preferences)
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
    }
}

private struct EditorCommands: Commands {
    @FocusedValue(\.activeEditorWorkspace) private var workspace
    @ObservedObject var preferences: AppPreferences
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
        delegateProxy.originalDelegate = window.delegate
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
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true {
            return originalDelegate
        }

        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldAllowWindowClose?() ?? true else {
            return false
        }

        return originalDelegate?.windowShouldClose?(sender) ?? true
    }
}
