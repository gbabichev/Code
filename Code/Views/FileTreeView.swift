//
//  FileTreeView.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    let nodes: [FileNode]
    let selectedFileID: FileNode.ID?
    let onOpenFile: (URL) -> Void

    var body: some View {
        List(selection: .constant(selectedFileID)) {
            OutlineGroup(nodes, children: \.outlineChildren) { node in
                FileRowView(
                    node: node,
                    isSelected: node.id == selectedFileID,
                    isDirty: isNodeDirty(node)
                )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !node.isDirectory {
                            onOpenFile(node.url)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
    }

    private func isNodeDirty(_ node: FileNode) -> Bool {
        if node.isDirectory {
            return node.children.contains(where: isNodeDirty)
        }

        return workspace.isFileDirty(node.url)
    }
}

private struct FileRowView: View {
    let node: FileNode
    let isSelected: Bool
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc.plaintext")
                .foregroundStyle(node.isDirectory ? .secondary : .primary)
            Text(node.displayName)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
