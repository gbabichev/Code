//
//  FileTreeView.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import SwiftUI

struct FileTreeView: View {
    let nodes: [FileNode]
    let selectedFileID: FileNode.ID?
    let onOpenFile: (URL) -> Void

    var body: some View {
        List(selection: .constant(selectedFileID)) {
            OutlineGroup(nodes, children: \.outlineChildren) { node in
                FileRowView(node: node, isSelected: node.id == selectedFileID)
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
}

private struct FileRowView: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc.plaintext")
                .foregroundStyle(node.isDirectory ? .secondary : .primary)
            Text(node.displayName)
                .lineLimit(1)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
