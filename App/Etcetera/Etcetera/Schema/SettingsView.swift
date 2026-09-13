//
//  SettingsView.swift
//  Etcetera
//

import SwiftUI
import UniformTypeIdentifiers

/// Application settings: connecting at launch, and which protoc compiles
/// schemas. See SPEC 5.2.
struct SettingsView: View {
    @AppStorage(Workspace.connectOnLaunchKey) private var connectOnLaunch = false
    @AppStorage(ProtocLocation.useCustomKey) private var useCustomProtoc = false
    @AppStorage(ProtocLocation.customPathKey) private var customProtocPath = ""
    @State private var isChoosingProtoc = false
    @State private var chooseError: String?

    var body: some View {
        Form {
            Section("Connections") {
                Toggle("Connect to the last used connection at launch", isOn: $connectOnLaunch)
                    .help("Connect automatically when etcetera starts")
            }
            Section("Protobuf") {
                Picker("protoc", selection: $useCustomProtoc) {
                    Text("Bundled").tag(false)
                    Text("Custom").tag(true)
                }
                .help("Which protoc compiles connection schemas")
                LabeledContent("Custom protoc") {
                    HStack {
                        Text(customProtocPath.isEmpty ? String(localized: "None chosen") : customProtocPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose...") { isChoosingProtoc = true }
                            .help("Choose a protoc executable")
                    }
                }
                .disabled(!useCustomProtoc)
                if let chooseError {
                    Text(chooseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if useCustomProtoc && customProtocPath.isEmpty {
                    Text("Choose a protoc. Schemas cannot compile until you do.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(
                    useCustomProtoc
                        ? String(localized: "A custom protoc must be signed to run inside the app sandbox.")
                        : String(localized: "Schemas compile with the protoc bundled with etcetera.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileImporter(isPresented: $isChoosingProtoc, allowedContentTypes: [.unixExecutable, .executable]) { result in
            switch result {
            case .success(let url):
                do {
                    try ProtocLocation.choose(url)
                    chooseError = nil
                } catch {
                    chooseError = String(localized: "\(url.lastPathComponent) cannot be used: \(error.localizedDescription)")
                }
            case .failure(let error):
                chooseError = error.localizedDescription
            }
        }
    }
}
