//
//  ContentView.swift
//  Basic Editor
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            editorPane
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open Folder") {
                    workspace.chooseRootFolder()
                }

                Button("Save") {
                    workspace.saveSelectedTab()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(workspace.selectedTab == nil)
            }
        }
        .alert("Editor Error", isPresented: errorBinding) {
            Button("OK") {
                workspace.errorMessage = nil
            }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.rootFolderURL?.lastPathComponent ?? "No Folder")
                        .font(.headline)
                    Text(workspace.rootFolderURL?.path(percentEncoded: false) ?? "Choose a folder to browse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    workspace.reloadFileTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(workspace.rootFolderURL == nil)
            }
            .padding(12)

            Divider()

            if workspace.rootFolderURL == nil {
                ContentUnavailableView(
                    "Open a Folder",
                    systemImage: "folder.badge.plus",
                    description: Text("Pick a root folder to browse files in the sidebar.")
                )
            } else {
                FileTreeView(
                    nodes: workspace.fileTree,
                    selectedFileID: workspace.selectedFileID,
                    onOpenFile: workspace.openFile
                )
            }
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if workspace.openTabs.isEmpty {
                ContentUnavailableView(
                    "No File Open",
                    systemImage: "doc.text",
                    description: Text("Choose a file from the sidebar to open it in a tab.")
                )
            } else {
                TabBarView(
                    tabs: workspace.openTabs,
                    selectedTabID: workspace.selectedTabID,
                    onSelect: { workspace.selectedTabID = $0 },
                    onClose: workspace.closeTab
                )

                Divider()

                if let selectedTab = workspace.selectedTab {
                    VStack(spacing: 0) {
                        HStack {
                            Text(selectedTab.fileURL.path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(selectedTab.language.rawValue.uppercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        Divider()

                        CodeEditorView(text: selectedTabBinding(selectedTab), language: selectedTab.language)
                    }
                }
            }
        }
    }

    private func selectedTabBinding(_ tab: EditorTab) -> Binding<String> {
        Binding(
            get: { tab.content },
            set: { workspace.updateContent($0, for: tab.id) }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { workspace.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    workspace.errorMessage = nil
                }
            }
        )
    }
}
