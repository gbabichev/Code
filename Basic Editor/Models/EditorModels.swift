//
//  EditorModels.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import AppKit
import Combine
import Foundation

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum EditorLanguage: String, Codable {
    case plainText
    case shell

    static func infer(from url: URL) -> EditorLanguage {
        let shellExtensions = ["sh", "bash", "zsh", "ksh", "command"]

        if shellExtensions.contains(url.pathExtension.lowercased()) {
            return .shell
        }

        let shellFileNames = ["bashrc", "zshrc", "profile", "bash_profile", "zprofile", ".env"]
        if shellFileNames.contains(url.lastPathComponent.lowercased()) {
            return .shell
        }

        if ["py", "pyw"].contains(url.pathExtension.lowercased()) {
            return .plainText
        }

        return .plainText
    }
}

struct SkinDefinition: Codable, Identifiable, Hashable {
    let schemaVersion: Int
    let id: String
    let name: String
    let editor: SkinEditorColors
    let tokens: SkinTokenPalette
    let languageOverrides: [String: SkinTokenPalette]

    func makeTheme(for language: EditorLanguage) -> SkinTheme {
        let palette = languageOverrides[language.rawValue] ?? tokens
        return SkinTheme(
            editorBackgroundColor: editor.background.resolveColor(),
            baseColor: editor.foreground.resolveColor(),
            keywordColor: palette.keyword.resolveColor(),
            builtinColor: palette.builtin.resolveColor(),
            variableColor: palette.variable.resolveColor(),
            stringColor: palette.string.resolveColor(),
            commentColor: palette.comment.resolveColor(),
            commandColor: palette.command.resolveColor()
        )
    }
}

struct SkinEditorColors: Codable, Hashable {
    let background: SkinAppearanceColor
    let foreground: SkinAppearanceColor
}

struct SkinTokenPalette: Codable, Hashable {
    let keyword: SkinAppearanceColor
    let builtin: SkinAppearanceColor
    let variable: SkinAppearanceColor
    let string: SkinAppearanceColor
    let comment: SkinAppearanceColor
    let command: SkinAppearanceColor
}

struct SkinAppearanceColor: Codable, Hashable {
    let light: String
    let dark: String

    func resolveColor() -> NSColor {
        NSColor(lightHex: light, darkHex: dark)
    }
}

extension NSColor {
    convenience init(lightHex: String, darkHex: String) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex) ?? .textColor
        }
    }

    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }

        let hasAlpha = cleaned.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1

        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode] = []

    var id: String { url.path(percentEncoded: false) }
    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }

    var outlineChildren: [FileNode]? {
        isDirectory ? children : nil
    }
}

struct EditorTabSnapshot: Codable {
    let filePath: String
    let content: String
    let isDirty: Bool
}

struct EditorSessionSnapshot: Codable {
    let rootFolderPath: String?
    let selectedFilePath: String?
    let selectedTabPath: String?
    let isWordWrapEnabled: Bool
    let appTheme: AppTheme
    let selectedSkinID: String
    let tabs: [EditorTabSnapshot]

    init(
        rootFolderPath: String?,
        selectedFilePath: String?,
        selectedTabPath: String?,
        isWordWrapEnabled: Bool,
        appTheme: AppTheme,
        selectedSkinID: String,
        tabs: [EditorTabSnapshot]
    ) {
        self.rootFolderPath = rootFolderPath
        self.selectedFilePath = selectedFilePath
        self.selectedTabPath = selectedTabPath
        self.isWordWrapEnabled = isWordWrapEnabled
        self.appTheme = appTheme
        self.selectedSkinID = selectedSkinID
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case rootFolderPath
        case selectedFilePath
        case selectedTabPath
        case isWordWrapEnabled
        case appTheme
        case selectedSkinID
        case tabs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootFolderPath = try container.decodeIfPresent(String.self, forKey: .rootFolderPath)
        selectedFilePath = try container.decodeIfPresent(String.self, forKey: .selectedFilePath)
        selectedTabPath = try container.decodeIfPresent(String.self, forKey: .selectedTabPath)
        isWordWrapEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWordWrapEnabled) ?? false
        appTheme = try container.decodeIfPresent(AppTheme.self, forKey: .appTheme) ?? .system
        selectedSkinID = try container.decodeIfPresent(String.self, forKey: .selectedSkinID) ?? "classic"
        tabs = try container.decode([EditorTabSnapshot].self, forKey: .tabs)
    }
}

@MainActor
final class EditorTab: ObservableObject, Identifiable {
    let fileURL: URL
    let language: EditorLanguage

    @Published var content: String
    @Published var isDirty: Bool

    let lastSavedContent: String

    init(fileURL: URL, content: String, lastSavedContent: String, isDirty: Bool) {
        self.fileURL = fileURL
        self.language = EditorLanguage.infer(from: fileURL)
        self.content = content
        self.lastSavedContent = lastSavedContent
        self.isDirty = isDirty
    }

    var id: String { fileURL.path(percentEncoded: false) }
    var title: String { fileURL.lastPathComponent }
}
