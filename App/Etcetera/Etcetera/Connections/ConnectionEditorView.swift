//
//  ConnectionEditorView.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits one connection profile. Secrets go to the Keychain; Test runs the
/// connection steps with the unsaved values and names the step that
/// failed. See SPEC 3.10 and 4.6.
struct ConnectionEditorView: View {
    var profiles: ProfilesModel
    /// The compiled schema, when this profile is the live connection.
    var registry: SchemaRegistry?
    var testMapping: MappingTester?
    var onSave: (ConnectionProfile) -> Void

    @State private var profile: ConnectionProfile
    /// Nil until typed, so an untouched field keeps the stored secret.
    @State private var password: String?
    @State private var passphrase: String?
    @State private var isImporting = false
    /// Outlives the panel: SwiftUI dismisses it before calling the completion.
    @State private var importTarget: ImportTarget?
    @State private var report: ConnectionTestReport?
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var isEditingMappings = false
    @Environment(\.dismiss) private var dismiss

    private enum ImportTarget {
        case caCertificate
        case clientIdentity
        case schemaFolder

        var types: [UTType] {
            switch self {
            case .caCertificate: [.x509Certificate, .data]
            case .clientIdentity: [.pkcs12]
            case .schemaFolder: [.folder]
            }
        }
    }

    init(
        profile: ConnectionProfile, profiles: ProfilesModel, registry: SchemaRegistry? = nil,
        testMapping: MappingTester? = nil,
        onSave: @escaping (ConnectionProfile) -> Void
    ) {
        self.profiles = profiles
        self.registry = registry
        self.testMapping = testMapping
        self.onSave = onSave
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                connectionSection
                authenticationSection
                tlsSection
                schemaSection
                if let report {
                    reportSection(report)
                }
            }
            .formStyle(.grouped)
            Divider()
            buttons
                .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importTarget?.types ?? [.data]
        ) { result in
            guard let target = importTarget else { return }
            do {
                let reference = try SecurityScopedFileAccess.reference(for: result.get())
                switch target {
                case .caCertificate: profile.tls.caCertificate = reference
                case .clientIdentity: profile.tls.clientIdentity = reference
                case .schemaFolder: profile.schema.source = reference
                }
            } catch {
                errorMessage = ConnectionModel.message(for: error)
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $profile.name)
            TextField("Endpoint", text: $profile.endpoint, prompt: Text(verbatim: "https://etcd.example.com:2379"))
            // One character: the tree and delete prefixes split on exactly that.
            TextField(
                "Key separator",
                text: Binding(get: { profile.separator }, set: { profile.separator = String($0.suffix(1)) }),
                prompt: Text(verbatim: "/"))
            Picker("API prefix", selection: $profile.pinnedPrefix) {
                Text("Detect automatically").tag(String?.none)
                ForEach(["/v3", "/v3beta", "/v3alpha"], id: \.self) { prefix in
                    Text(prefix).tag(String?(prefix))
                }
            }
            .help("The gateway path etcd serves its API under; older versions use /v3beta or /v3alpha")
            Toggle("Live updates", isOn: $profile.watchEnabled)
                .help("Keep the tree current through a watch. Turn off for large or busy clusters.")
        }
    }

    private var authenticationSection: some View {
        Section("Authentication") {
            TextField(
                "Username",
                text: Binding(get: { profile.username ?? "" }, set: { profile.username = $0.isEmpty ? nil : $0 }),
                prompt: Text("None"))
            SecureField(
                "Password", text: secretBinding($password),
                prompt: hasStored(.password) ? Text("Saved in Keychain") : nil)
        }
    }

    private var tlsSection: some View {
        Section("TLS") {
            fileRow(
                "CA certificate", profile.tls.caCertificate, target: .caCertificate,
                chooseHelp: "Choose the CA certificate", clearHelp: "Stop using this CA certificate"
            ) {
                profile.tls.caCertificate = nil
            }
            fileRow(
                "Client certificate (PKCS#12)", profile.tls.clientIdentity, target: .clientIdentity,
                chooseHelp: "Choose the client certificate", clearHelp: "Stop using this client certificate"
            ) {
                profile.tls.clientIdentity = nil
            }
            if profile.tls.clientIdentity != nil {
                SecureField(
                    "PKCS#12 passphrase", text: secretBinding($passphrase),
                    prompt: hasStored(.pkcs12Passphrase) ? Text("Saved in Keychain") : nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Have a PEM key pair? Convert it first:")
                    .foregroundStyle(.secondary)
                Text(verbatim: "openssl pkcs12 -export -in client.crt -inkey client.key -out client.p12")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .font(.caption)
            Toggle("Skip server certificate verification", isOn: $profile.tls.skipServerVerification)
            if profile.tls.skipServerVerification {
                Label(
                    "Anyone between you and the cluster can read and change the data. The window shows a warning while connected.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.caption)
            }
        }
    }

    /// Binds key patterns to message types. See SPEC 5.5.
    private var schemaSection: some View {
        Section("Protobuf Schema") {
            fileRow(
                "Proto folder", profile.schema.source, target: .schemaFolder,
                chooseHelp: "Choose the proto folder", clearHelp: "Stop using this proto folder"
            ) {
                profile.schema.source = nil
            }
            LabeledContent("Mappings") {
                HStack {
                    Text(mappingSummary)
                        .foregroundStyle(profile.schema.mappings.isEmpty ? .secondary : .primary)
                    Button("Edit Mappings...") { isEditingMappings = true }
                        .help("Choose which keys decode as which protobuf message")
                }
            }
        }
        .sheet(isPresented: $isEditingMappings) {
            SchemaMappingsSheet(
                mappings: profile.schema.mappings, connectionName: profile.name, registry: registry,
                testMapping: testMapping
            ) { profile.schema.mappings = $0 }
        }
    }

    private var mappingSummary: String {
        let count = profile.schema.mappings.count
        return count == 0 ? String(localized: "None", comment: "No file chosen") : String(localized: "\(count) mappings")
    }

    private func fileRow(
        _ title: LocalizedStringKey, _ reference: FileReference?, target: ImportTarget,
        chooseHelp: LocalizedStringKey, clearHelp: LocalizedStringKey, clear: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(reference?.displayName ?? String(localized: "None", comment: "No file chosen"))
                    .foregroundStyle(reference == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose...") {
                    importTarget = target
                    isImporting = true
                }
                    .help(chooseHelp)
                if reference != nil {
                    Button("Clear", action: clear)
                        .help(clearHelp)
                }
            }
        }
    }

    private func reportSection(_ report: ConnectionTestReport) -> some View {
        Section("Test") {
            ForEach(report.results, id: \.step) { result in
                HStack(alignment: .firstTextBaseline) {
                    switch result.outcome {
                    case .passed(let detail):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        stepText(result.step, detail)
                    case .failed(let message):
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        stepText(result.step, message)
                    case .skipped:
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        stepText(result.step, nil)
                    }
                }
            }
        }
    }

    private func stepText(_ step: ConnectionStep, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(step.title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Test") { test() }
                .disabled(isTesting)
                .help("Try each connection step with these settings, without saving")
            if isTesting {
                ProgressView()
                    .controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.endpoint.isEmpty)
                .help("Save the connection; secrets go to the Keychain")
        }
    }

    private func secretBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }

    private func hasStored(_ kind: SecretKind) -> Bool {
        profiles.secrets.hasSecret(kind, for: profile.id)
    }

    private func test() {
        isTesting = true
        report = nil
        var overrides: [SecretKind: String] = [:]
        if let password { overrides[.password] = password }
        if let passphrase { overrides[.pkcs12Passphrase] = passphrase }
        let secrets = OverlaySecretStore(base: profiles.secrets, overrides: overrides)
        let profile = profile
        Task {
            report = await ConnectionSetup.test(profile, secrets: secrets, files: SecurityScopedFileAccess())
            isTesting = false
        }
    }

    private func save() {
        do {
            if profile.name.isEmpty { profile.name = profile.endpoint }
            try profiles.save(profile, password: password, passphrase: passphrase)
            onSave(profile)
            dismiss()
        } catch {
            errorMessage = ConnectionModel.message(for: error)
        }
    }
}
