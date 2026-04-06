//
//  CodeApp.swift
//  Code
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI

@main
struct CodeApp: App {
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
            EditorCommands(preferences: preferences)
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
    }
}

private struct EditorCommands: Commands {
    @FocusedValue(\.activeEditorWorkspace) private var workspace
    @ObservedObject var preferences: AppPreferences

    var body: some Commands {
        CommandGroup(after: .newItem) {
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
