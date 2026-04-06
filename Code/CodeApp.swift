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

    var body: some Scene {
        WindowGroup {
            WorkspaceSceneView()
                .environmentObject(preferences)
        }
        .commands {
            EditorCommands(preferences: preferences)
        }
    }
}

private struct WorkspaceSceneView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @SceneStorage("workspaceSessionID") private var workspaceSessionID = UUID().uuidString

    var body: some View {
        WorkspaceContentView(sessionID: workspaceSessionID)
            .id(workspaceSessionID)
            .environmentObject(preferences)
    }
}

private struct WorkspaceContentView: View {
    @StateObject private var workspace: EditorWorkspace

    init(sessionID: String) {
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
