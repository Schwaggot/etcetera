import AppKit
import EtceteraCore
import SwiftUI

@main
struct EtceteraApp: App {
    var body: some Scene {
        // One window: each would hold its own copy of the saved connections
        // and overwrite the others' changes.
        Window(Text(verbatim: "Etcetera"), id: "main") {
            ContentView()
        }
        .commands {
            EditorCommands()
        }
        Settings {
            SettingsView()
        }
    }
}

/// Menu commands for the focused window's tabs and editor. Command-W closes
/// the selected tab while one is open. See SPEC 4.1 and 4.3.
struct EditorCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @AppStorage("editor.softWrap") private var softWrap = true

    private var selected: ValueModel? { workspace?.tabs.selected?.value }

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task { await workspace?.saveSelected() }
            }
            .keyboardShortcut("s")
            .disabled(!(selected?.isDirty ?? false))
            Button("Close Tab") {
                if let workspace {
                    workspace.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Value") {
            Button("Format JSON") { selected?.formatJSON() }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(!(selected?.isEditable ?? false))
            Button("Minify JSON") { selected?.minifyJSON() }
                .disabled(!(selected?.isEditable ?? false))
            Toggle("Soft Wrap", isOn: $softWrap)
            Divider()
            Button("Load Into Editor") { selected?.openInEditor() }
                .disabled(!((selected?.isLarge ?? false) && !(selected?.isEditable ?? true)))
            Button("Refresh Schema") {
                Task { await workspace?.refreshSchema() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(workspace?.connection.profile?.schema.source == nil)
            Divider()
            Button("Show Next Tab") { workspace?.tabs.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { workspace?.tabs.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandGroup(after: .help) {
            Toggle(
                "Verbose Logging for This Session",
                isOn: Binding(
                    get: { workspace?.verboseLogging ?? false },
                    set: { workspace?.verboseLogging = $0 })
            )
            .disabled(workspace == nil)
        }
    }
}
