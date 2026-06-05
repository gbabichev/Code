//
//  FileStatusIndicatorView.swift
//  Code
//

import SwiftUI

enum FileStatusIndicatorStyle {
    case icon
    case badge
}

struct FileStatusIndicatorStrip: View {
    let indicators: [EditorFileStatusKind]
    var style: FileStatusIndicatorStyle = .icon
    var maxVisible: Int?
    var clickableIndicators: Set<EditorFileStatusKind> = []
    var onIndicatorClick: ((EditorFileStatusKind) -> Void)?

    private var sortedIndicators: [EditorFileStatusKind] {
        indicators.sorted { lhs, rhs in
            if lhs.sortPriority == rhs.sortPriority {
                return lhs.rawValue < rhs.rawValue
            }
            return lhs.sortPriority < rhs.sortPriority
        }
    }

    private var visibleIndicators: [EditorFileStatusKind] {
        guard let maxVisible else { return sortedIndicators }
        return Array(sortedIndicators.prefix(maxVisible))
    }

    private var hiddenCount: Int {
        max(sortedIndicators.count - visibleIndicators.count, 0)
    }

    var body: some View {
        if !sortedIndicators.isEmpty {
            HStack(spacing: style == .badge ? 6 : 4) {
                ForEach(visibleIndicators) { indicator in
                    indicatorView(for: indicator)
                }

                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(.system(size: style == .badge ? 10 : 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .help(sortedIndicators.dropFirst(visibleIndicators.count).map(\.title).joined(separator: ", "))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sortedIndicators.map(\.title).joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func indicatorView(for indicator: EditorFileStatusKind) -> some View {
        if clickableIndicators.contains(indicator), let onIndicatorClick {
            Button {
                onIndicatorClick(indicator)
            } label: {
                indicatorContent(for: indicator)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            indicatorContent(for: indicator)
        }
    }

    @ViewBuilder
    private func indicatorContent(for indicator: EditorFileStatusKind) -> some View {
        switch style {
        case .icon:
            Image(systemName: indicator.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(for: indicator))
                .frame(width: 14, height: 14)
                .help("\(indicator.title): \(indicator.helpText)")
        case .badge:
            Label(indicator.title, systemImage: indicator.systemImage)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tint(for: indicator))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(tint(for: indicator).opacity(0.12))
                )
                .help(indicator.helpText)
        }
    }

    private func tint(for indicator: EditorFileStatusKind) -> Color {
        switch indicator {
        case .externalModification, .mixedIndentation, .unevenIndentation:
            .orange
        case .readOnly, .largeFile:
            .secondary
        case .binary:
            .red
        }
    }
}
