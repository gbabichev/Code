//
//  ContentView.swift
//  Basic Editor
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var isShowingSettingsPopover = false
    @State private var pendingTabClose: PendingTabClose?

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

                Button {
                    isShowingSettingsPopover.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .popover(isPresented: $isShowingSettingsPopover, arrowEdge: .bottom) {
                    SettingsPopoverView()
                        .environmentObject(preferences)
                        .environmentObject(workspace)
                }
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .alert("Save Changes?", isPresented: pendingTabCloseBinding, presenting: pendingTabClose) { pending in
            Button("Save") {
                workspace.saveTab(id: pending.id)
                if workspace.errorMessage == nil {
                    workspace.closeTab(pending.id)
                }
                pendingTabClose = nil
            }
            Button("Discard", role: .destructive) {
                workspace.closeTab(pending.id)
                pendingTabClose = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTabClose = nil
            }
        } message: { pending in
            Text("Do you want to save the changes you made to \(pending.fileName)?")
        }
        .alert("Editor Error", isPresented: errorBinding) {
            Button("OK") {
                workspace.errorMessage = nil
                preferences.errorMessage = nil
            }
        } message: {
            Text(activeErrorMessage)
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
                    onClose: requestCloseTab
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

                        CodeEditorView(
                            text: selectedTabBinding(selectedTab),
                            isWordWrapEnabled: preferences.isWordWrapEnabled,
                            skin: preferences.selectedSkin,
                            language: selectedTab.language
                        )
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

    private func requestCloseTab(_ id: EditorTab.ID) {
        guard let tab = workspace.tab(withID: id) else { return }

        if tab.isDirty {
            pendingTabClose = PendingTabClose(id: id, fileName: tab.title)
        } else {
            workspace.closeTab(id)
        }
    }

    private var pendingTabCloseBinding: Binding<Bool> {
        Binding(
            get: { pendingTabClose != nil },
            set: { newValue in
                if !newValue {
                    pendingTabClose = nil
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { workspace.errorMessage != nil || preferences.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    workspace.errorMessage = nil
                    preferences.errorMessage = nil
                }
            }
        )
    }

    private var activeErrorMessage: String {
        workspace.errorMessage ?? preferences.errorMessage ?? ""
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appTheme {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

private struct PendingTabClose: Identifiable {
    let id: EditorTab.ID
    let fileName: String
}

private struct SettingsPopoverView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.headline)

                Picker("Theme", selection: $preferences.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Syntax Highlighting Skin")
                    .font(.headline)

                Picker("Syntax Highlighting Skin", selection: $preferences.selectedSkinID) {
                    ForEach(preferences.availableSkins) { skin in
                        Text(skin.name).tag(skin.id)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button("Import…") {
                        preferences.importSkin()
                    }
                    Button("Export Current…") {
                        preferences.exportSelectedSkin()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
