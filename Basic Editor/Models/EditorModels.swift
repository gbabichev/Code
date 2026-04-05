//
//  EditorModels.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

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

enum SyntaxHighlightingSkin: String, Codable, CaseIterable, Identifiable {
    case classic
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .forest: "Forest"
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

        return .plainText
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
    let syntaxHighlightingSkin: SyntaxHighlightingSkin
    let tabs: [EditorTabSnapshot]

    init(
        rootFolderPath: String?,
        selectedFilePath: String?,
        selectedTabPath: String?,
        isWordWrapEnabled: Bool,
        appTheme: AppTheme,
        syntaxHighlightingSkin: SyntaxHighlightingSkin,
        tabs: [EditorTabSnapshot]
    ) {
        self.rootFolderPath = rootFolderPath
        self.selectedFilePath = selectedFilePath
        self.selectedTabPath = selectedTabPath
        self.isWordWrapEnabled = isWordWrapEnabled
        self.appTheme = appTheme
        self.syntaxHighlightingSkin = syntaxHighlightingSkin
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case rootFolderPath
        case selectedFilePath
        case selectedTabPath
        case isWordWrapEnabled
        case appTheme
        case syntaxHighlightingSkin
        case tabs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootFolderPath = try container.decodeIfPresent(String.self, forKey: .rootFolderPath)
        selectedFilePath = try container.decodeIfPresent(String.self, forKey: .selectedFilePath)
        selectedTabPath = try container.decodeIfPresent(String.self, forKey: .selectedTabPath)
        isWordWrapEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWordWrapEnabled) ?? false
        appTheme = try container.decodeIfPresent(AppTheme.self, forKey: .appTheme) ?? .system
        syntaxHighlightingSkin = try container.decodeIfPresent(SyntaxHighlightingSkin.self, forKey: .syntaxHighlightingSkin) ?? .classic
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
