//
//  NamedKeyText.swift
//  Etcetera
//

import SwiftUI

/// A key led by the name its mapping takes from the value, when there is
/// one; the key always shows. See SPEC 5.5.
struct NamedKeyText: View {
    var name: String?
    var key: String
    /// `key` stands in for an empty segment, so it must not read as one.
    var isPlaceholder = false

    var body: some View {
        if let name {
            HStack(spacing: 6) {
                Text(name)
                    .layoutPriority(1)
                Text(key)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } else {
            Text(key)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
        }
    }
}
