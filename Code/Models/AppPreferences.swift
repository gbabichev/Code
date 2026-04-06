//
//  AppPreferences.swift
//  Code
//
//  Created by Codex on 4/5/26.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppPreferences: ObservableObject {
    static let defaultSkinID = "classic"

    @Published var isWordWrapEnabled: Bool {
        didSet {
            userDefaults.set(isWordWrapEnabled, forKey: Keys.isWordWrapEnabled)
        }
    }

    @Published var appTheme: AppTheme {
        didSet {
            userDefaults.set(appTheme.rawValue, forKey: Keys.appTheme)
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

    @Published private(set) var availableSkins: [SkinDefinition] = []
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

        reloadSkins()

        // Persist migrated values so future launches no longer depend on the legacy session file.
        userDefaults.set(isWordWrapEnabled, forKey: Keys.isWordWrapEnabled)
        userDefaults.set(appTheme.rawValue, forKey: Keys.appTheme)
        userDefaults.set(selectedSkinID, forKey: Keys.selectedSkinID)
    }

    var selectedSkin: SkinDefinition {
        availableSkins.first(where: { $0.id == selectedSkinID })
            ?? availableSkins.first
            ?? SkinDefinition(
                schemaVersion: 1,
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

    func exportSelectedSkin() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(selectedSkin.id).json"
        panel.prompt = "Export Skin"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try skinStore.exportSkin(selectedSkin, to: url)
        } catch {
            errorMessage = "Failed to export skin: \(error.localizedDescription)"
        }
    }

    func reloadSkins() {
        availableSkins = skinStore.loadSkins()
        if !availableSkins.contains(where: { $0.id == selectedSkinID }) {
            selectedSkinID = availableSkins.first?.id ?? Self.defaultSkinID
        }
    }
}

private enum Keys {
    static let isWordWrapEnabled = "preferences.isWordWrapEnabled"
    static let appTheme = "preferences.appTheme"
    static let selectedSkinID = "preferences.selectedSkinID"
}
