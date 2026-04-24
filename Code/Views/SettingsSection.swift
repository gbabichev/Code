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
