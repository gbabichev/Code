//
//  TabBarView.swift
//  Code
//

import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    let tabs: [EditorTab]
    let selectedTabID: EditorTab.ID?
    let isDropTargeted: Bool
    let onSelect: (EditorTab.ID) -> Void
    let onClose: (EditorTab.ID) -> Void
    let onCreate: () -> Void
    let onMove: (EditorTab.ID, EditorTab.ID) -> Void
    let onMoveToEnd: (EditorTab.ID) -> Void
    @State private var draggedTabID: EditorTab.ID?

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == selectedTabID,
                            draggedTabID: $draggedTabID,
                            onSelect: onSelect,
                            onClose: onClose,
                            onMove: onMove
                        )
                    }

                    Color.clear
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.plainText], delegate: TabDropToEndDelegate(
                            draggedTabID: $draggedTabID,
                            onMoveToEnd: onMoveToEnd
                        ))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("New Tab")
            .padding(.trailing, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.9 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(4)
        }
    }
}

private struct TabItemView: View {
    private static let tabDragType = UTType.plainText

    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    @Binding var draggedTabID: EditorTab.ID?
    let onSelect: (EditorTab.ID) -> Void
    let onClose: (EditorTab.ID) -> Void
    let onMove: (EditorTab.ID, EditorTab.ID) -> Void

    private var selectedBackground: Color {
        Color.accentColor.opacity(0.16)
    }

    private var selectedBorder: Color {
        Color.accentColor.opacity(0.55)
    }

    private var unselectedBackground: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.01)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(tab.title)
                .lineLimit(1)
                .fontWeight(isSelected ? .semibold : .regular)
            if tab.isDirty {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.orange)
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
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 34)
        .background(isSelected ? selectedBackground : unselectedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? selectedBorder : Color.primary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onSelect(tab.id)
            }
        )
        .onDrag {
            draggedTabID = tab.id
            return NSItemProvider(object: NSString(string: tab.id))
        }
        .onDrop(of: [Self.tabDragType], delegate: TabDropDelegate(
            tabID: tab.id,
            draggedTabID: $draggedTabID,
            onMove: onMove
        ))
    }
}

private struct TabDropDelegate: DropDelegate {
    let tabID: EditorTab.ID
    @Binding var draggedTabID: EditorTab.ID?
    let onMove: (EditorTab.ID, EditorTab.ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTabID, draggedTabID != tabID else { return }
        onMove(draggedTabID, tabID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }
}

private struct TabDropToEndDelegate: DropDelegate {
    @Binding var draggedTabID: EditorTab.ID?
    let onMoveToEnd: (EditorTab.ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTabID else { return }
        onMoveToEnd(draggedTabID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }
}
