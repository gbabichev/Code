//
//  AppPreferences.swift
//  Code
//


import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum EditorAutocompleteMode: String {
    case on
    case off

    static func migratedValue(from rawValue: String?) -> EditorAutocompleteMode {
        switch rawValue {
        case Self.off.rawValue:
            .off
        case Self.on.rawValue, "custom", "systemDefault":
            .on
        default:
            .on
        }
    }
}

struct RecentItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case file
        case folder
    }

    let kind: Kind
    let path: String

    var id: String { "\(kind.rawValue):\(path)" }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var systemImage: String {
        switch kind {
        case .file:
            return "doc"
        case .folder:
            return "folder"
        }
    }

    var menuTitle: String {
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        let parentPath = url.deletingLastPathComponent().path(percentEncoded: false)

        if parentPath.isEmpty || parentPath == path {
            return name
        }

        return "\(name) - \(parentPath)"
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    static let defaultSkinID = "classic"
    static let defaultFontSize: Double = 13
    static let defaultEditorFontFamilyName = "Menlo"
    static let minEditorFontSize: Double = 10
    static let maxEditorFontSize: Double = 28
    static let defaultIndentWidth = 4
    static let minIndentWidth = 1
    static let maxIndentWidth = 8
    static let defaultSyntaxHighlightingEnabled = true
    static let defaultRecentItemLimit = 5
    static let minRecentItemLimit = 0
    static let maxRecentItemLimit = 20
    private static let maxStoredRecentItems = 50

    @Published var isWordWrapEnabled: Bool {
        didSet {
            userDefaults.set(isWordWrapEnabled, forKey: Keys.isWordWrapEnabled)
        }
    }

    @Published var appTheme: AppTheme {
        didSet {
            userDefaults.set(appTheme.rawValue, forKey: Keys.appTheme)
            applyAppAppearance()
        }
    }

    @Published var selectedSkinID: String {
        didSet {
            userDefaults.set(selectedSkinID, forKey: Keys.selectedSkinID)
            if !availableSkins.contains(where: { $0.id == selectedSkinID }) {
                selectedSkinID = availableSkins.first?.id ?? Self.defaultSkinID
            }
        }
    }

    @Published var editorFontName: String {
        didSet {
            if !availableEditorFonts.contains(editorFontName) {
                editorFontName = availableEditorFonts.first ?? Self.defaultEditorFontFamilyName
                return
            }
            userDefaults.set(editorFontName, forKey: Keys.editorFontName)
        }
    }

    @Published var editorFontSize: Double {
        didSet {
            let clampedSize = min(max(editorFontSize, Self.minEditorFontSize), Self.maxEditorFontSize)
            if clampedSize != editorFontSize {
                editorFontSize = clampedSize
                return
            }
            userDefaults.set(editorFontSize, forKey: Keys.editorFontSize)
        }
    }

    @Published var isSidebarVisible: Bool {
        didSet {
            userDefaults.set(isSidebarVisible, forKey: Keys.isSidebarVisible)
        }
    }

    @Published var indentWidth: Int {
        didSet {
            let clampedWidth = min(max(indentWidth, Self.minIndentWidth), Self.maxIndentWidth)
            if clampedWidth != indentWidth {
                indentWidth = clampedWidth
                return
            }
            userDefaults.set(indentWidth, forKey: Keys.indentWidth)
        }
    }

    @Published var autocompleteMode: EditorAutocompleteMode {
        didSet {
            userDefaults.set(autocompleteMode.rawValue, forKey: Keys.autocompleteMode)
        }
    }

    @Published var isSyntaxHighlightingEnabled: Bool {
        didSet {
            userDefaults.set(isSyntaxHighlightingEnabled, forKey: Keys.isSyntaxHighlightingEnabled)
        }
    }

    @Published var recentItemLimit: Int {
        didSet {
            let clampedLimit = min(max(recentItemLimit, Self.minRecentItemLimit), Self.maxRecentItemLimit)
            if clampedLimit != recentItemLimit {
                recentItemLimit = clampedLimit
                return
            }
            userDefaults.set(recentItemLimit, forKey: Keys.recentItemLimit)
        }
    }

    @Published private(set) var availableSkins: [SkinDefinition] = []
    @Published private(set) var availableEditorFonts: [String] = []
    @Published private(set) var recentItems: [RecentItem]
    @Published var errorMessage: String?

    private let userDefaults: UserDefaults
    private let skinStore: SkinStore

    init(
        userDefaults: UserDefaults = .standard,
        skinStore: SkinStore = SkinStore(),
        legacySessionStore: SessionStore = SessionStore()
    ) {
        self.userDefaults = userDefaults
        self.skinStore = skinStore

        let legacySnapshot = legacySessionStore.load()

        if userDefaults.object(forKey: Keys.isWordWrapEnabled) != nil {
            isWordWrapEnabled = userDefaults.bool(forKey: Keys.isWordWrapEnabled)
        } else {
            isWordWrapEnabled = legacySnapshot?.isWordWrapEnabled ?? false
        }

        if
            let storedTheme = userDefaults.string(forKey: Keys.appTheme),
            let theme = AppTheme(rawValue: storedTheme)
        {
            appTheme = theme
        } else {
            appTheme = legacySnapshot?.appTheme ?? .system
        }

        selectedSkinID = userDefaults.string(forKey: Keys.selectedSkinID)
            ?? legacySnapshot?.selectedSkinID
            ?? Self.defaultSkinID

        editorFontName = userDefaults.string(forKey: Keys.editorFontName) ?? Self.defaultEditorFontFamilyName

        if userDefaults.object(forKey: Keys.editorFontSize) != nil {
            editorFontSize = userDefaults.double(forKey: Keys.editorFontSize)
        } else {
            editorFontSize = Self.defaultFontSize
        }

        if userDefaults.object(forKey: Keys.isSidebarVisible) != nil {
            isSidebarVisible = userDefaults.bool(forKey: Keys.isSidebarVisible)
        } else {
            isSidebarVisible = true
        }

        if userDefaults.object(forKey: Keys.indentWidth) != nil {
            indentWidth = userDefaults.integer(forKey: Keys.indentWidth)
        } else {
            indentWidth = Self.defaultIndentWidth
        }

        autocompleteMode = EditorAutocompleteMode.migratedValue(
            from: userDefaults.string(forKey: Keys.autocompleteMode)
        )

        if userDefaults.object(forKey: Keys.isSyntaxHighlightingEnabled) != nil {
            isSyntaxHighlightingEnabled = userDefaults.bool(forKey: Keys.isSyntaxHighlightingEnabled)
        } else {
            isSyntaxHighlightingEnabled = Self.defaultSyntaxHighlightingEnabled
        }

        if userDefaults.object(forKey: Keys.recentItemLimit) != nil {
            recentItemLimit = userDefaults.integer(forKey: Keys.recentItemLimit)
        } else {
            recentItemLimit = Self.defaultRecentItemLimit
        }

        if let recentItemsData = userDefaults.data(forKey: Keys.recentItems),
           let decodedRecentItems = try? JSONDecoder().decode([RecentItem].self, from: recentItemsData) {
            recentItems = decodedRecentItems
        } else {
            recentItems = []
        }

        reloadEditorFonts()
        reloadSkins()

        // Persist migrated values so future launches no longer depend on the legacy session file.
        userDefaults.set(isWordWrapEnabled, forKey: Keys.isWordWrapEnabled)
        userDefaults.set(appTheme.rawValue, forKey: Keys.appTheme)
        userDefaults.set(selectedSkinID, forKey: Keys.selectedSkinID)
        userDefaults.set(editorFontName, forKey: Keys.editorFontName)
        userDefaults.set(editorFontSize, forKey: Keys.editorFontSize)
        userDefaults.set(isSidebarVisible, forKey: Keys.isSidebarVisible)
        userDefaults.set(indentWidth, forKey: Keys.indentWidth)
        userDefaults.set(autocompleteMode.rawValue, forKey: Keys.autocompleteMode)
        userDefaults.set(isSyntaxHighlightingEnabled, forKey: Keys.isSyntaxHighlightingEnabled)
        userDefaults.set(recentItemLimit, forKey: Keys.recentItemLimit)
        persistRecentItems()
        applyAppAppearance()
    }

    var selectedSkin: SkinDefinition {
        availableSkins.first(where: { $0.id == selectedSkinID })
            ?? availableSkins.first
            ?? SkinDefinition(
                id: Self.defaultSkinID,
                name: "Classic",
                editor: .init(
                    background: .init(light: "#FFFFFF", dark: "#1E1E1E"),
                    foreground: .init(light: "#111111", dark: "#E6E6E6")
                ),
                tokens: .init(
                    keyword: .init(light: "#FF2D92", dark: "#FF7ABD"),
                    builtin: .init(light: "#0A84FF", dark: "#6DB7FF"),
                    variable: .init(light: "#FF9F0A", dark: "#FFC457"),
                    string: .init(light: "#2DA44E", dark: "#7BDC8B"),
                    comment: .init(light: "#6E6E73", dark: "#8E8E93"),
                    command: .init(light: "#AF52DE", dark: "#D69CFF")
                ),
                languageOverrides: [:]
            )
    }

    var editorFont: NSFont {
        font(forFamilyName: editorFontName, size: CGFloat(editorFontSize))
            ?? NSFont(name: "Menlo-Regular", size: CGFloat(editorFontSize))
            ?? NSFont.userFixedPitchFont(ofSize: CGFloat(editorFontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(editorFontSize), weight: .regular)
    }

    var editorSemiboldFont: NSFont {
        if let semiboldFont = NSFontManager.shared.font(
            withFamily: editorFontName,
            traits: .boldFontMask,
            weight: 7,
            size: CGFloat(editorFontSize)
        ) {
            return semiboldFont
        }

        if let familyName = editorFont.familyName,
           let semiboldFont = NSFontManager.shared.font(
            withFamily: familyName,
            traits: .boldFontMask,
            weight: 7,
            size: CGFloat(editorFontSize)
           ) {
            return semiboldFont
        }

        return NSFont.monospacedSystemFont(ofSize: CGFloat(editorFontSize), weight: .semibold)
    }

    func importSkin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Skin"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let skin = try skinStore.importSkin(from: url)
            reloadSkins()
            selectedSkinID = skin.id
        } catch {
            errorMessage = "Failed to import skin: \(error.localizedDescription)"
        }
    }

    func exportSelectedSkin() async {
        guard let url = await presentSkinExportPanel() else { return }

        do {
            try skinStore.exportSkin(selectedSkin, to: url)
        } catch {
            errorMessage = "Failed to export skin: \(error.localizedDescription)"
        }
    }

    private func presentSkinExportPanel() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(selectedSkin.id).json"
        panel.prompt = "Export Skin"
        panel.title = ""
        panel.message = ""
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: hostWindow) { response in
                    guard response == .OK, let url = panel.url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: url)
                }
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func reloadSkins() {
        availableSkins = skinStore.loadSkins()
        if !availableSkins.contains(where: { $0.id == selectedSkinID }) {
            selectedSkinID = availableSkins.first?.id ?? Self.defaultSkinID
        }
    }

    func increaseEditorFontSize() {
        editorFontSize += 1
    }

    func decreaseEditorFontSize() {
        editorFontSize -= 1
    }

    func resetEditorFontSize() {
        editorFontSize = Self.defaultFontSize
    }

    var visibleRecentItems: [RecentItem] {
        Array(
            recentItems
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .prefix(recentItemLimit)
        )
    }

    func recordRecentFile(_ url: URL) {
        recordRecentItem(RecentItem(kind: .file, path: url.path(percentEncoded: false)))
    }

    func recordRecentFolder(_ url: URL) {
        recordRecentItem(RecentItem(kind: .folder, path: url.path(percentEncoded: false)))
    }

    func removeRecentItem(_ item: RecentItem) {
        recentItems.removeAll { $0 == item }
        persistRecentItems()
    }

    func clearRecentItems() {
        recentItems.removeAll()
        persistRecentItems()
    }

    private func applyAppAppearance() {
        switch appTheme {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func reloadEditorFonts() {
        availableEditorFonts = NSFontManager.shared.availableFontFamilies
            .filter { familyName in
                let members = NSFontManager.shared.availableMembers(ofFontFamily: familyName) ?? []
                return members.contains { member in
                    guard let postScriptName = member.first as? String else { return false }
                    guard let font = NSFont(name: postScriptName, size: CGFloat(Self.defaultFontSize)) else { return false }
                    return font.isFixedPitch
                }
            }
            .sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard))

        if !availableEditorFonts.contains(editorFontName) {
            editorFontName = availableEditorFonts.first(where: { $0 == Self.defaultEditorFontFamilyName })
                ?? availableEditorFonts.first
                ?? Self.defaultEditorFontFamilyName
        }
    }

    private func font(forFamilyName familyName: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: familyName, traits: [], weight: 5, size: size)
            ?? (NSFontManager.shared.availableMembers(ofFontFamily: familyName) ?? [])
                .compactMap { member -> NSFont? in
                    guard let postScriptName = member.first as? String else { return nil }
                    return NSFont(name: postScriptName, size: size)
                }
                .first
    }

    private func recordRecentItem(_ item: RecentItem) {
        recentItems.removeAll { $0 == item }
        recentItems.insert(item, at: 0)
        if recentItems.count > Self.maxStoredRecentItems {
            recentItems.removeLast(recentItems.count - Self.maxStoredRecentItems)
        }
        persistRecentItems()
    }

    private func persistRecentItems() {
        let encodedRecentItems = try? JSONEncoder().encode(recentItems)
        userDefaults.set(encodedRecentItems, forKey: Keys.recentItems)
    }
}

private enum Keys {
    static let isWordWrapEnabled = "preferences.isWordWrapEnabled"
    static let appTheme = "preferences.appTheme"
    static let selectedSkinID = "preferences.selectedSkinID"
    static let editorFontName = "preferences.editorFontName"
    static let editorFontSize = "preferences.editorFontSize"
    static let isSidebarVisible = "preferences.isSidebarVisible"
    static let indentWidth = "preferences.indentWidth"
    static let autocompleteMode = "preferences.autocompleteMode"
    static let isSyntaxHighlightingEnabled = "preferences.isSyntaxHighlightingEnabled"
    static let recentItemLimit = "preferences.recentItemLimit"
    static let recentItems = "preferences.recentItems"
}
