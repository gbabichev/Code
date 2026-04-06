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
    @EnvironmentObject private var searchController: EditorSearchController
    @State private var isShowingSettingsPopover = false
    @State private var isTargetingTabDrop = false
    @State private var cachedSearchMatches: [NSRange] = []
    @FocusState private var focusedSearchField: SearchField?

    enum SearchField: Hashable {
        case find
        case replace
    }

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
                    onClose: requestCloseTab,
                    onMove: workspace.moveTab,
                    onMoveToEnd: workspace.moveTabToEnd
                )
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: $isTargetingTabDrop,
                    perform: handleDroppedItems
                )

                Divider()

                if searchController.isPresented, let selectedTab = workspace.selectedTab {
                    EditorSearchBar(
                        query: $searchController.query,
                        replacement: $searchController.replacement,
                        isCaseSensitive: $searchController.isCaseSensitive,
                        isReplaceVisible: searchController.isReplaceVisible,
                        matchSummary: matchSummary(for: cachedSearchMatches, in: selectedTab),
                        focusedField: $focusedSearchField,
                        onClose: { searchController.hide() },
                        onFindNext: { findNext(in: selectedTab) },
                        onFindPrevious: { findPrevious(in: selectedTab) },
                        onReplace: { replaceCurrentMatch(in: selectedTab) },
                        onReplaceAll: { replaceAllMatches(in: selectedTab) }
                    )
                    .onAppear {
                        DispatchQueue.main.async {
                            focusedSearchField = .find
                        }
                    }

                    Divider()
                }

                if let selectedTab = workspace.selectedTab {
                    CodeEditorView(
                        text: selectedTabBinding(selectedTab),
                        isWordWrapEnabled: preferences.isWordWrapEnabled,
                        skin: preferences.selectedSkin,
                        language: selectedTab.language,
                        indentWidth: preferences.indentWidth,
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
        .onChange(of: searchController.eventID) { _, _ in
            handleSearchCommand()
        }
        .onChange(of: searchController.query) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: searchController.isCaseSensitive) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: searchController.isPresented) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: workspace.selectedTab?.content ?? "") { _, _ in
            refreshSearchMatches()
        }
        .onAppear {
            refreshSearchMatches()
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

    private func handleSearchCommand() {
        guard searchController.isPresented else { return }
        focusedSearchField = .find

        guard let selectedTab = workspace.selectedTab else {
            return
        }

        switch searchController.lastCommand {
        case .showFind, .showReplace:
            if !searchController.query.isEmpty {
                findNext(in: selectedTab)
            }
        case .findNext, .useSelectionForFind:
            findNext(in: selectedTab)
        case .findPrevious:
            findPrevious(in: selectedTab)
        }
    }

    private func findNext(in tab: EditorTab) {
        guard let textView = ActiveEditorTextViewRegistry.shared.textView else { return }
        guard !searchController.query.isEmpty else { return }

        let text = tab.content as NSString
        let currentSelection = textView.selectedRange()
        let startLocation = NSMaxRange(currentSelection)

        if let match = findMatch(
            in: text,
            query: searchController.query,
            range: NSRange(location: min(startLocation, text.length), length: max(0, text.length - min(startLocation, text.length))),
            options: stringCompareOptions
        ) ?? findMatch(in: text, query: searchController.query, range: NSRange(location: 0, length: min(startLocation, text.length)), options: stringCompareOptions) {
            select(match, in: textView)
        }
    }

    private func findPrevious(in tab: EditorTab) {
        guard let textView = ActiveEditorTextViewRegistry.shared.textView else { return }
        guard !searchController.query.isEmpty else { return }

        let text = tab.content as NSString
        let currentSelection = textView.selectedRange()
        let startLocation = max(0, currentSelection.location)

        if let match = findMatch(
            in: text,
            query: searchController.query,
            range: NSRange(location: 0, length: min(startLocation, text.length)),
            options: backwardStringCompareOptions
        ) ?? findMatch(
            in: text,
            query: searchController.query,
            range: NSRange(location: startLocation, length: max(0, text.length - startLocation)),
            options: backwardStringCompareOptions
        ) {
            select(match, in: textView)
        }
    }

    private func replaceCurrentMatch(in tab: EditorTab) {
        guard let textView = ActiveEditorTextViewRegistry.shared.textView else { return }
        guard !searchController.query.isEmpty else { return }

        let selectedRange = textView.selectedRange()
        let text = tab.content as NSString

        if selectedRange.length > 0,
           selectedRange.location != NSNotFound,
           NSMaxRange(selectedRange) <= text.length,
           text.substring(with: selectedRange) == searchController.query {
            let updated = text.replacingCharacters(in: selectedRange, with: searchController.replacement)
            workspace.updateContent(updated, for: tab.id)
            let replacementRange = NSRange(location: selectedRange.location, length: (searchController.replacement as NSString).length)
            DispatchQueue.main.async {
                select(replacementRange, in: textView)
            }
            findNext(in: tab)
            return
        }

        findNext(in: tab)
    }

    private func replaceAllMatches(in tab: EditorTab) {
        guard !searchController.query.isEmpty else { return }

        let text = tab.content as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let updated = text.replacingOccurrences(
            of: searchController.query,
            with: searchController.replacement,
            options: stringCompareOptions,
            range: fullRange
        )
        workspace.updateContent(updated, for: tab.id)
    }

    private func findMatches(in tab: EditorTab) -> [NSRange] {
        guard !searchController.query.isEmpty else { return [] }

        let text = tab.content as NSString
        var matches: [NSRange] = []
        var searchLocation = 0

        while searchLocation <= text.length {
            let searchRange = NSRange(location: searchLocation, length: text.length - searchLocation)
            let match = text.range(of: searchController.query, options: stringCompareOptions, range: searchRange)
            guard match.location != NSNotFound, match.length > 0 else { break }
            matches.append(match)
            searchLocation = NSMaxRange(match)
        }

        return matches
    }

    private func refreshSearchMatches() {
        guard searchController.isPresented,
              let selectedTab = workspace.selectedTab else {
            cachedSearchMatches = []
            return
        }

        cachedSearchMatches = findMatches(in: selectedTab)
    }

    private func matchSummary(for matches: [NSRange], in tab: EditorTab) -> String {
        guard !matches.isEmpty else {
            return searchController.query.isEmpty ? "" : "0 matches"
        }

        guard let textView = ActiveEditorTextViewRegistry.shared.textView else {
            return "\(matches.count) matches"
        }

        let selectedRange = textView.selectedRange()
        if let currentIndex = matches.firstIndex(where: { NSEqualRanges($0, selectedRange) }) {
            return "\(currentIndex + 1) of \(matches.count)"
        }

        return "\(matches.count) matches"
    }

    private func findMatch(
        in text: NSString,
        query: String,
        range: NSRange,
        options: NSString.CompareOptions
    ) -> NSRange? {
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= text.length,
              !query.isEmpty else {
            return nil
        }

        let match = text.range(of: query, options: options, range: range)
        return match.location == NSNotFound ? nil : match
    }

    private func select(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private var stringCompareOptions: NSString.CompareOptions {
        searchController.isCaseSensitive ? [] : [.caseInsensitive]
    }

    private var backwardStringCompareOptions: NSString.CompareOptions {
        var options = stringCompareOptions
        options.insert(.backwards)
        return options
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

private struct EditorSearchBar: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var isCaseSensitive: Bool
    let isReplaceVisible: Bool
    let matchSummary: String
    let focusedField: FocusState<ContentView.SearchField?>.Binding
    let onClose: () -> Void
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused(focusedField, equals: .find)
                .onSubmit {
                    onFindNext()
                    focusedField.wrappedValue = .find
                }

            Button {
                onFindPrevious()
                focusedField.wrappedValue = .find
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)

            Button {
                onFindNext()
                focusedField.wrappedValue = .find
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)

            Toggle("Match Case", isOn: $isCaseSensitive)
                .toggleStyle(.checkbox)

            if !matchSummary.isEmpty {
                Text(matchSummary)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .leading)
            }

            if isReplaceVisible {
                TextField("Replace", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused(focusedField, equals: .replace)
                    .onSubmit {
                        onReplace()
                        focusedField.wrappedValue = .replace
                    }

                Button("Replace") {
                    onReplace()
                }

                Button("Replace All") {
                    onReplaceAll()
                }
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

                HStack {
                    Text("Indent Width")
                    Spacer()
                    Text("\(preferences.indentWidth) spaces")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "",
                        value: $preferences.indentWidth,
                        in: AppPreferences.minIndentWidth...AppPreferences.maxIndentWidth,
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
