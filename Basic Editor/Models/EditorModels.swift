//
//  EditorModels.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import Combine
import Foundation

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
    let tabs: [EditorTabSnapshot]
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
