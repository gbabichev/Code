//
//  TabBarView.swift
//  Basic Editor
//
//  Created by Codex on 4/5/26.
//

import SwiftUI

struct TabBarView: View {
    let tabs: [EditorTab]
    let selectedTabID: EditorTab.ID?
    let onSelect: (EditorTab.ID) -> Void
    let onClose: (EditorTab.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    HStack(spacing: 8) {
                        Text(tab.title)
                            .lineLimit(1)
                        if tab.isDirty {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                        }
                        Button {
                            onClose(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(height: 34)
                    .background(tab.id == selectedTabID ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(tab.id == selectedTabID ? 0.12 : 0.05), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(tab.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
