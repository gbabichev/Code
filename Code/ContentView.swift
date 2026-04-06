//
//  ContentView.swift
//  Basic Editor
//
//  Created by George Babichev on 4/5/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var isShowingSettingsPopover = false
    @State private var isTargetingTabDrop = false

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { preferences.isSidebarVisible ? .all : .detailOnly },
            set: { preferences.isSidebarVisible = $0 != .detailOnly }
        )) {
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
        .alert("Save Changes?", isPresented: pendingTabCloseBinding, presenting: workspace.pendingTabClose) { pending in
            Button("Save") {
                workspace.confirmPendingTabCloseSave()
            }
            Button("Discard", role: .destructive) {
                workspace.confirmPendingTabCloseDiscard()
            }
            Button("Cancel", role: .cancel) {
                workspace.cancelPendingTabClose()
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
                    isDropTargeted: isTargetingTabDrop,
                    onSelect: { workspace.selectedTabID = $0 },
                    onClose: requestCloseTab
                )
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: $isTargetingTabDrop,
                    perform: handleDroppedItems
                )

                Divider()

                if let selectedTab = workspace.selectedTab {
                    CodeEditorView(
                        text: selectedTabBinding(selectedTab),
                        isWordWrapEnabled: preferences.isWordWrapEnabled,
                        skin: preferences.selectedSkin,
                        language: selectedTab.language,
                        editorFont: preferences.editorFont,
                        editorSemiboldFont: preferences.editorSemiboldFont
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selectedTab = workspace.selectedTab {
                fileInfoBar(for: selectedTab)
            }
        }
    }

    private func fileInfoBar(for tab: EditorTab) -> some View {
        HStack(spacing: 12) {
            Text(tab.fileURL?.path(percentEncoded: false) ?? "Unsaved file")
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text("\(lineCount(for: tab)) lines")

            Divider()
                .frame(height: 12)

            Menu(tab.textEncoding.title) {
                ForEach(EditorTextEncoding.allCases) { encoding in
                    Button {
                        workspace.updateSelectedTabEncoding(encoding)
                    } label: {
                        if tab.textEncoding == encoding {
                            Label(encoding.title, systemImage: "checkmark")
                        } else {
                            Text(encoding.title)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)

            Divider()
                .frame(height: 12)

            Menu(tab.lineEnding.title) {
                ForEach(EditorLineEnding.allCases) { lineEnding in
                    Button {
                        workspace.updateSelectedTabLineEnding(lineEnding)
                    } label: {
                        if tab.lineEnding == lineEnding {
                            Label(lineEnding.title, systemImage: "checkmark")
                        } else {
                            Text(lineEnding.title)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)

            Divider()
                .frame(height: 12)

            Text(tab.language.rawValue.uppercased())
                .font(.caption.monospaced())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func lineCount(for tab: EditorTab) -> Int {
        guard !tab.content.isEmpty else { return 1 }

        var count = 1
        var index = tab.content.startIndex
        while index < tab.content.endIndex {
            if tab.content[index] == "\n" {
                count += 1
            }
            index = tab.content.index(after: index)
        }
        return count
    }

    private func selectedTabBinding(_ tab: EditorTab) -> Binding<String> {
        Binding(
            get: { tab.content },
            set: { workspace.updateContent($0, for: tab.id) }
        )
    }

    private func requestCloseTab(_ id: EditorTab.ID) {
        workspace.requestCloseTab(id)
    }

    private func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        let fileURLProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileURLProviders.isEmpty else { return false }

        for provider in fileURLProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      !url.hasDirectoryPath else {
                    return
                }

                Task { @MainActor in
                    workspace.openFile(url)
                }
            }
        }

        return true
    }

    private var pendingTabCloseBinding: Binding<Bool> {
        Binding(
            get: { workspace.pendingTabClose != nil },
            set: { newValue in
                if !newValue {
                    workspace.cancelPendingTabClose()
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
                Text("Editor Font")
                    .font(.headline)

                Picker("Editor Font", selection: $preferences.editorFontName) {
                    ForEach(preferences.availableEditorFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int(preferences.editorFontSize)) pt")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "",
                        value: $preferences.editorFontSize,
                        in: AppPreferences.minEditorFontSize...AppPreferences.maxEditorFontSize,
                        step: 1
                    )
                    .labelsHidden()
                }
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
