//
//  CodeApp.swift
//  Code
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI

@main
struct CodeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var workspace = EditorWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    workspace.chooseRootFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Toggle("Word Wrap", isOn: $workspace.isWordWrapEnabled)
                    .keyboardShortcut("z", modifiers: [.option, .command])
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                workspace.persistSession()
            }
        }
    }
}
