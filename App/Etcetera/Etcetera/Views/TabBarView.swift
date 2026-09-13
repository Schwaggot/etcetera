//
//  TabBarView.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI

/// The value tabs above the editor. A dirty tab shows a dot where its close
/// button goes until hovered. See SPEC 4.1.
struct TabBarView: View {
    var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        name: workspace.connection.displayNames[tab.key],
                        separator: workspace.connection.separatorCharacter,
                        isSelected: tab.key == workspace.tabs.selectedKey,
                        select: { workspace.tabs.selectedKey = tab.key },
                        close: { workspace.requestClose(tab.key) })
                    Divider()
                }
            }
        }
        .frame(height: 28)
        .background(.bar)
    }
}

private struct TabItemView: View {
    var tab: ValueTab
    /// The name the key's mapping takes from its value. See SPEC 5.5.
    var name: String?
    var separator: Character
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: close) {
                Image(systemName: showsDirtyDot ? "circle.fill" : "xmark")
                    .font(.system(size: showsDirtyDot ? 7 : 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovering || tab.value.isDirty ? 1 : 0)
            .help("Close Tab")
            Text(shortTitle)
                .lineLimit(1)
            if tab.changedSinceLastSession {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help("Changed since your last session")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Color.primary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.title)
    }

    private var showsDirtyDot: Bool { tab.value.isDirty && !isHovering }

    /// The key's name, else its last path segment; the full key is in the tooltip.
    private var shortTitle: String {
        if let name { return name }
        let title = tab.title
        let trimmed = title.last == separator ? String(title.dropLast()) : title
        return trimmed.split(separator: separator).last.map(String.init) ?? title
    }
}
