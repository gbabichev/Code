//
//  SettingsSection.swift
//  Screen Snip
//
//  Created by George Babichev on 9/13/25.
//

import SwiftUI
// MARK: - Reusable building blocks

#if os(macOS)
struct SettingsRow<Control: View>: View {
    let systemImage: String?
    let title: String
    let subtitle: String?
    @ViewBuilder var control: Control

    init(
        _ title: String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .center)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                control
                    .labelsHidden()
                    .controlSize(.large)
            }
            .frame(minHeight: 44)

        }
    }
}
#endif

extension View {
    @ViewBuilder
    func iOSModernInputFieldStyle() -> some View {
#if os(macOS)
        self
            .textFieldStyle(.plain)
            .frame(minHeight: 20, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
#else
        self
            .frame(minHeight: 30, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
#endif
    }
}
