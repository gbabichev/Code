//
//  EditorModels.swift
//  Code
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

enum EditorLanguage: String, Codable, CaseIterable, Identifiable {
    case plainText
    case shell
    case dotenv
    case python
    case powerShell
    case xml
    case json

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "plainText":
            self = .plainText
        case "shell":
            self = .shell
        case "dotenv":
            self = .dotenv
        case "python":
            self = .python
        case "powerShell":
            self = .powerShell
        case "xml", "plist":
            self = .xml
        case "json":
            self = .json
        default:
            self = .plainText
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func infer(from url: URL) -> EditorLanguage {
        let shellExtensions = ["sh", "bash", "zsh", "ksh", "command"]

        if shellExtensions.contains(url.pathExtension.lowercased()) {
            return .shell
        }

        let shellFileNames = ["bashrc", "zshrc", "profile", "bash_profile", "zprofile"]
        if shellFileNames.contains(url.lastPathComponent.lowercased()) {
            return .shell
        }

        let lastPathComponent = url.lastPathComponent.lowercased()
        if lastPathComponent == ".env" || lastPathComponent.hasPrefix(".env.") {
            return .dotenv
        }

        if ["py", "pyw", "pyi"].contains(url.pathExtension.lowercased()) {
            return .python
        }

        if ["ps1", "psm1", "psd1"].contains(url.pathExtension.lowercased()) {
            return .powerShell
        }

        if ["xml", "xsl", "xsd", "plist", "mobileconfig"].contains(url.pathExtension.lowercased()) {
            return .xml
        }

        if lastPathComponent.hasSuffix(".plist") {
            return .xml
        }

        if url.pathExtension.lowercased() == "json" {
            return .json
        }

        return .plainText
    }

    var lineCommentPrefix: String? {
        switch self {
        case .shell, .dotenv, .python, .powerShell:
            return "#"
        case .plainText, .xml, .json:
            return nil
        }
    }

    var title: String {
        switch self {
        case .plainText:
            "Plain Text"
        case .shell:
            "Shell"
        case .dotenv:
            "DOTENV"
        case .python:
            "Python"
        case .powerShell:
            "PowerShell"
        case .xml:
            "XML"
        case .json:
            "JSON"
        }
    }
}

enum EditorTextEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8
    case utf16
    case utf16LittleEndian
    case utf16BigEndian
    case utf32

    var id: String { rawValue }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            .utf8
        case .utf16:
            .utf16
        case .utf16LittleEndian:
            .utf16LittleEndian
        case .utf16BigEndian:
            .utf16BigEndian
        case .utf32:
            .utf32
        }
    }

    var title: String {
        switch self {
        case .utf8:
            "UTF-8"
        case .utf16:
            "UTF-16"
        case .utf16LittleEndian:
            "UTF-16 LE"
        case .utf16BigEndian:
            "UTF-16 BE"
        case .utf32:
            "UTF-32"
        }
    }
}

enum EditorLineEnding: String, Codable, CaseIterable, Identifiable {
    case lf
    case crlf
    case cr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lf:
            "LF"
        case .crlf:
            "CRLF"
        case .cr:
            "CR"
        }
    }

    var sequence: String {
        switch self {
        case .lf:
            "\n"
        case .crlf:
            "\r\n"
        case .cr:
            "\r"
        }
    }
}

struct SkinDefinition: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let editor: SkinEditorColors
    let tokens: SkinTokenPalette
    let languageOverrides: [String: SkinTokenPalette]

    func makeTheme(for language: EditorLanguage, editorFont: NSFont, semiboldFont: NSFont) -> SkinTheme {
        let palette = languageOverrides[language.rawValue] ?? tokens
        let backgroundColor = editor.background.resolveColor()
        let foregroundColor = editor.foreground.resolveColor()
        return SkinTheme(
            font: editorFont,
            semiboldFont: semiboldFont,
            editorBackgroundColor: backgroundColor,
            baseColor: foregroundColor,
            keywordColor: palette.keyword.resolveColor(),
            builtinColor: palette.builtin.resolveColor(),
            variableColor: palette.variable.resolveColor(),
            stringColor: palette.string.resolveColor(),
            commentColor: palette.comment.resolveColor(),
            commandColor: palette.command.resolveColor(),
            currentLineColor: editor.background.mixed(with: editor.foreground, fraction: 0.08, overlayAlpha: 0.20),
            selectionColor: editor.foreground.withAlpha(0.15),
            gutterBackgroundColor: backgroundColor,
            gutterBorderColor: editor.foreground.withAlpha(0.10),
            gutterTextColor: editor.foreground.withAlpha(0.55),
            gutterCurrentLineColor: editor.background.mixed(with: editor.foreground, fraction: 0.04, overlayAlpha: 0.08),
            gutterCurrentLineNumberColor: editor.foreground.withAlpha(0.90)
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

    func withAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(
            lightHex: light,
            darkHex: dark,
            lightAlpha: alpha,
            darkAlpha: alpha
        )
    }

    func mixed(with other: SkinAppearanceColor, fraction: CGFloat, overlayAlpha: CGFloat = 1) -> NSColor {
        NSColor(
            lightHex: light,
            darkHex: dark,
            mixedLightHex: other.light,
            mixedDarkHex: other.dark,
            fraction: fraction,
            overlayAlpha: overlayAlpha
        )
    }
}

extension NSColor {
    convenience init(lightHex: String, darkHex: String) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex) ?? .textColor
        }
    }

    convenience init(lightHex: String, darkHex: String, lightAlpha: CGFloat, darkAlpha: CGFloat) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base = NSColor(hex: isDark ? darkHex : lightHex) ?? .textColor
            return base.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
    }

    convenience init(
        lightHex: String,
        darkHex: String,
        mixedLightHex: String,
        mixedDarkHex: String,
        fraction: CGFloat,
        overlayAlpha: CGFloat
    ) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let baseHex = isDark ? darkHex : lightHex
            let mixedHex = isDark ? mixedDarkHex : mixedLightHex
            let base = NSColor(hex: baseHex) ?? .textColor
            let overlay = (NSColor(hex: mixedHex) ?? .textColor).withAlphaComponent(overlayAlpha)
            return base.blended(withFraction: fraction, of: overlay) ?? base
        }
    }

    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        guard let value = UInt64(cleaned, radix: 16) else { return nil }

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
    let id: String?
    let filePath: String?
    let title: String?
    let languageOverride: EditorLanguage?
    let encoding: EditorTextEncoding?
    let lineEnding: EditorLineEnding?
    let lastSavedEncoding: EditorTextEncoding?
    let lastSavedLineEnding: EditorLineEnding?
    let content: String
    let isDirty: Bool

    init(
        id: String? = nil,
        filePath: String?,
        title: String? = nil,
        languageOverride: EditorLanguage? = nil,
        encoding: EditorTextEncoding? = nil,
        lineEnding: EditorLineEnding? = nil,
        lastSavedEncoding: EditorTextEncoding? = nil,
        lastSavedLineEnding: EditorLineEnding? = nil,
        content: String,
        isDirty: Bool
    ) {
        self.id = id
        self.filePath = filePath
        self.title = title
        self.languageOverride = languageOverride
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.lastSavedEncoding = lastSavedEncoding
        self.lastSavedLineEnding = lastSavedLineEnding
        self.content = content
        self.isDirty = isDirty
    }
}

struct PendingTabClose: Identifiable, Equatable {
    let id: EditorTab.ID
    let fileName: String
}

struct PendingWindowClose: Identifiable {
    let id = UUID()
    let dirtyTabNames: [String]
}

struct EditorSessionSnapshot: Codable {
    let rootFolderPath: String?
    let selectedFilePath: String?
    let selectedTabPath: String?
    let isWordWrapEnabled: Bool?
    let appTheme: AppTheme?
    let selectedSkinID: String?
    let tabs: [EditorTabSnapshot]

    init(
        rootFolderPath: String?,
        selectedFilePath: String?,
        selectedTabPath: String?,
        isWordWrapEnabled: Bool? = nil,
        appTheme: AppTheme? = nil,
        selectedSkinID: String? = nil,
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
        isWordWrapEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWordWrapEnabled)
        appTheme = try container.decodeIfPresent(AppTheme.self, forKey: .appTheme)
        selectedSkinID = try container.decodeIfPresent(String.self, forKey: .selectedSkinID)
        tabs = try container.decode([EditorTabSnapshot].self, forKey: .tabs)
    }
}

@MainActor
final class EditorTab: ObservableObject, Identifiable {
    let id: String
    @Published var fileURL: URL?
    @Published var customTitle: String?
    @Published var languageOverride: EditorLanguage?
    @Published var textEncoding: EditorTextEncoding
    @Published var lineEnding: EditorLineEnding

    // `content` is NOT @Published — we manually trigger objectWillChange
    // only when metadata changes so that typing doesn't rebuild the whole UI.
    var content: String {
        didSet {
            // Content changes are silent by default; dirty-state changes
            // are published explicitly via set(content:notify:).
        }
    }
    @Published var isDirty: Bool
    var lastSavedContent: String
    var lastSavedEncoding: EditorTextEncoding
    var lastSavedLineEnding: EditorLineEnding

    init(
        id: String = UUID().uuidString,
        fileURL: URL?,
        languageOverride: EditorLanguage? = nil,
        textEncoding: EditorTextEncoding = .utf8,
        lineEnding: EditorLineEnding = .lf,
        customTitle: String? = nil,
        content: String,
        lastSavedContent: String,
        lastSavedEncoding: EditorTextEncoding? = nil,
        lastSavedLineEnding: EditorLineEnding? = nil,
        isDirty: Bool
    ) {
        self.id = id
        self.fileURL = fileURL
        self.languageOverride = languageOverride
        self.textEncoding = textEncoding
        self.lineEnding = lineEnding
        self.customTitle = customTitle
        self.content = content
        self.lastSavedContent = lastSavedContent
        self.lastSavedEncoding = lastSavedEncoding ?? textEncoding
        self.lastSavedLineEnding = lastSavedLineEnding ?? lineEnding
        self.isDirty = isDirty
    }

    /// Update content optionally notifying observers.
    /// Use `notify: false` for per-keystroke updates and `notify: true`
    /// when the change should propagate to sidebar / tab bar.
    func setContent(_ newContent: String, notify: Bool = false) {
        content = newContent
        refreshDirtyState()
        if notify {
            objectWillChange.send()
        }
    }

    func refreshDirtyState() {
        let newDirty = content != lastSavedContent
            || textEncoding != lastSavedEncoding
            || lineEnding != lastSavedLineEnding
        if isDirty != newDirty {
            isDirty = newDirty
        }
    }

    var language: EditorLanguage {
        if let languageOverride {
            return languageOverride
        }

        guard let fileURL else { return .plainText }
        return EditorLanguage.infer(from: fileURL)
    }

    var inferredLanguage: EditorLanguage {
        guard let fileURL else { return .plainText }
        return EditorLanguage.infer(from: fileURL)
    }

    var title: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }

        return customTitle ?? "Untitled"
    }
}
