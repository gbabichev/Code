//
//  Basic_EditorApp.swift
//  Basic Editor
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI

@main
struct Basic_EditorApp: App {
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                workspace.persistSession()
            }
        }
    }
}
