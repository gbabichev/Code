//
//  ContentView.swift
//  Code
//
//  Created by George Babichev on 4/5/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var workspace: EditorWorkspace
    @EnvironmentObject private var searchController: EditorSearchController
    @EnvironmentObject private var aboutController: AboutOverlayController
    @State private var isShowingSettingsPopover = false
    @State private var isTargetingTabDrop = false
    @State private var cachedSearchMatches: [NSRange] = []
    @State private var toastMessage: String?
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
        .navigationSplitViewStyle(.prominentDetail)
#if DEBUG
        .overlay(alignment: .bottomTrailing) {
            BetaTag()
                .padding(12)
        }
#endif
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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
            //Spacer()
            ToolbarItem(placement: .status) {
                Button("Code") {
                }
                .buttonStyle(.glass)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .alert("Save Changes?", isPresented: pendingTabCloseBinding, presenting: workspace.pendingTabClose) { pending in
            Button("Save") {
                Task {
                    await workspace.confirmPendingTabCloseSave()
                }
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
        .overlay {
            if aboutController.isPresented {
                AboutOverlayView(isPresented: $aboutController.isPresented)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if workspace.rootFolderURL == nil {
                ContentUnavailableView(
                    "Open a Folder",
                    systemImage: "folder.badge.plus",
                    description: Text("Pick a root folder to browse files in the sidebar.")
                )
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    LinearGradient(
                                        colors: [
                                            Color.accentColor.opacity(0.95),
                                            Color.accentColor.opacity(0.7)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )

                            Text(workspace.rootFolderURL?.lastPathComponent ?? "")
                                .font(.headline.weight(.semibold))

                            Spacer(minLength: 0)

                            Button {
                                workspace.reloadFileTree()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .help("Refresh Folder")
                        }

                        Text(workspace.rootFolderURL?.path(percentEncoded: false) ?? "")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.72))
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            }
                    }
                    .padding(12)

                    Divider()
                }

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
                    onCreate: workspace.createUntitledTab,
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
                    .onExitCommand {
                        searchController.hide()
                    }

                    Divider()
                }

                editorArea
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selectedTab = workspace.selectedTab {
                fileInfoBar(for: selectedTab)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 16)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

            if tab.fileURL != nil {
                Button {
                    openParentFolder(for: tab)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open Parent Folder in Finder")

                Button {
                    openParentFolderInTerminal(for: tab)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.borderless)
                .help("Open Parent Folder in Terminal")

                Button {
                    copyFileURL(for: tab)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .help("Copy File URL")

                Divider()
                    .frame(height: 12)
            }

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

            Menu(languageStatusTitle(for: tab)) {
                Button {
                    workspace.updateSelectedTabLanguageOverride(nil)
                } label: {
                    if tab.languageOverride == nil {
                        Label("Auto Detect (\(tab.inferredLanguage.title))", systemImage: "checkmark")
                    } else {
                        Text("Auto Detect (\(tab.inferredLanguage.title))")
                    }
                }

                Divider()

                ForEach(EditorLanguage.allCases) { language in
                    Button {
                        workspace.updateSelectedTabLanguageOverride(language)
                    } label: {
                        if tab.languageOverride == language {
                            Label(language.title, systemImage: "checkmark")
                        } else {
                            Text(language.title)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
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

    private func languageStatusTitle(for tab: EditorTab) -> String {
        if tab.languageOverride == nil {
            return "Auto: \(tab.inferredLanguage.title)"
        }

        return tab.language.title
    }

    private func selectedTabBinding(_ tab: EditorTab) -> Binding<String> {
        Binding(
            get: { tab.content },
            set: { workspace.updateContent($0, for: tab.id) }
        )
    }

    private var editorArea: some View {
        Group {
            if let tab = workspace.selectedTab {
                let binding = selectedTabBinding(tab)
                let lang = tab.language
                EditorAreaView(
                    text: binding,
                    isWordWrapEnabled: preferences.isWordWrapEnabled,
                    skin: preferences.selectedSkin,
                    language: lang,
                    indentWidth: preferences.indentWidth,
                    editorFont: preferences.editorFont,
                    editorSemiboldFont: preferences.editorSemiboldFont
                )
            }
        }
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

    private func openParentFolder(for tab: EditorTab) {
        guard let parentURL = tab.fileURL?.deletingLastPathComponent() else { return }
        NSWorkspace.shared.open(parentURL)
    }

    private func copyFileURL(for tab: EditorTab) {
        guard let fileURL = tab.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.absoluteString, forType: .string)
        showToast("File URL Copied")
    }

    private func openParentFolderInTerminal(for tab: EditorTab) {
        guard let folderURL = tab.fileURL?.deletingLastPathComponent() else { return }
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: terminalURL, configuration: configuration) { _, _ in }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard toastMessage == message else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                toastMessage = nil
            }
        }
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

// MARK: - Editor Area View (extracted to help compiler type-checking)
private struct EditorAreaView: View {
    let text: Binding<String>
    let isWordWrapEnabled: Bool
    let skin: SkinDefinition
    let language: EditorLanguage
    let indentWidth: Int
    let editorFont: NSFont
    let editorSemiboldFont: NSFont

    var body: some View {
        ZStack {
            CodeEditorView(
                text: text,
                isWordWrapEnabled: isWordWrapEnabled,
                skin: skin,
                language: language,
                indentWidth: indentWidth,
                editorFont: editorFont,
                editorSemiboldFont: editorSemiboldFont
            )
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Editor Settings")
                            .font(.title3.weight(.semibold))
                        Text("Global preferences for every window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingsSection(
                title: "Appearance",
                caption: "Window-wide presentation and theme behavior"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Theme", selection: $preferences.appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider()

                    Toggle(isOn: $preferences.isWordWrapEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Word Wrap")
                            Text("Wrap long lines inside the editor")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            settingsSection(
                title: "Editor",
                caption: "Typeface and editing defaults"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Editor Font", selection: $preferences.editorFontName) {
                        ForEach(preferences.availableEditorFonts, id: \.self) { fontName in
                            Text(fontName).tag(fontName)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.custom(preferences.editorFont.fontName, size: preferences.editorFont.pointSize))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    settingStepperRow(
                        title: "Font Size",
                        detail: "\(Int(preferences.editorFontSize)) pt",
                        value: $preferences.editorFontSize,
                        range: AppPreferences.minEditorFontSize...AppPreferences.maxEditorFontSize
                    )

                    settingStepperRow(
                        title: "Indent Width",
                        detail: "\(preferences.indentWidth) spaces",
                        value: Binding(
                            get: { Double(preferences.indentWidth) },
                            set: { preferences.indentWidth = Int($0) }
                        ),
                        range: Double(AppPreferences.minIndentWidth)...Double(AppPreferences.maxIndentWidth)
                    )
                }
            }

            settingsSection(
                title: "Syntax Skin",
                caption: "Color theme used for token highlighting"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Syntax Highlighting Skin", selection: $preferences.selectedSkinID) {
                        ForEach(preferences.availableSkins) { skin in
                            Text(skin.name).tag(skin.id)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        Button("Import…") {
                            preferences.importSkin()
                        }

                        Button("Export Current…") {
                            Task {
                                await preferences.exportSelectedSkin()
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.035),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func settingStepperRow(
        title: String,
        detail: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
        }
    }
}
