//
//  UpdateAvailableOverlayView.swift
//  Code
//

#if os(macOS)
import SwiftUI

struct UpdateAvailableOverlayView: View {
    let update: AppAvailableUpdate
    let onLater: () -> Void
    let onDownload: () -> Void

    private var notesText: String {
        let trimmed = update.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No release notes were provided for this release." : trimmed
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                content
                    .frame(width: min(620, max(360, proxy.size.width - 48)))
                    .padding(24)
            }
        }
        .transition(.opacity)
        .onExitCommand {
            onLater()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Update Available")
                        .font(.title3.weight(.semibold))

                    Text(update.appName)
                        .font(.headline)

                    Text(update.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                versionBadge(update.currentVersion, style: .secondary)

                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                versionBadge(update.latestVersion, style: .accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Release Notes")
                    .font(.subheadline.weight(.semibold))

                ScrollView {
                    Text(notesText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 180, maxHeight: 300)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button {
                    onLater()
                } label: {
                    Label("Later", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)

                if update.releaseURL != nil {
                    Button {
                        onDownload()
                    } label: {
                        Label("Open Download Page", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        onLater()
                    } label: {
                        Label("Close", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 10)
    }

    private enum VersionBadgeStyle {
        case secondary
        case accent
    }

    private func versionBadge(_ version: String, style: VersionBadgeStyle) -> some View {
        let foreground = style == .accent ? Color.accentColor : Color.secondary
        let background = style == .accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)

        return Text(version)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
    }
}

#endif
