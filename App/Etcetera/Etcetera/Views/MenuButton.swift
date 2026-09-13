//
//  MenuButton.swift
//  Etcetera
//

import AppKit
import SwiftUI

enum MenuButtonItem {
    case action(String, () -> Void)
    case toggle(String, isOn: Bool, (Bool) -> Void)
    case separator
}

/// A plain button that opens a menu below itself. SwiftUI draws an
/// icon-only Menu as a pull-down shorter than the buttons beside it.
struct MenuButton<Label: View>: View {
    var items: [MenuButtonItem]
    @ViewBuilder var label: Label

    @State private var anchor = NSView()

    var body: some View {
        Button(action: open) { label }
            .background(Anchor(view: anchor))
    }

    private func open() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .action(let title, let action):
                menu.addItem(Self.item(title, action))
            case .toggle(let title, let isOn, let set):
                let entry = Self.item(title) { set(!isOn) }
                entry.state = isOn ? .on : .off
                menu.addItem(entry)
            case .separator:
                menu.addItem(.separator())
            }
        }
        let below = anchor.isFlipped ? anchor.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    private static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = target
        // The target is weak; the item keeps it alive.
        item.representedObject = target
        return item
    }

    private struct Anchor: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}
