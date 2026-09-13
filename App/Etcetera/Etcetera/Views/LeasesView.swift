//
//  LeasesView.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI

/// The cluster's leases: remaining time, attached keys, and revoke.
struct LeasesView: View {
    var connection: ConnectionModel

    @State private var model = LeasesModel()
    @State private var revoking: Int64?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leases")
                    .font(.headline)
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Refresh") { Task { await model.load(from: connection) } }
                    .help("Load the leases again")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Table(model.leases) {
                TableColumn("ID") { lease in
                    Text(String(lease.id, radix: 16))
                        .monospaced()
                        .textSelection(.enabled)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Remaining") { lease in
                    Text(lease.ttl < 0 ? String(localized: "expired") : String(localized: "\(lease.ttl) s"))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Granted") { lease in
                    Text("\(lease.grantedTTL) s")
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Keys") { lease in
                    let keys = lease.keys.map { displayString(for: $0) }
                    Text(
                        keys.isEmpty
                            ? String(localized: "none", comment: "No keys attached to a lease")
                            : keys.joined(separator: ", "))
                        .lineLimit(2)
                        .help(keys.joined(separator: "\n"))
                }
                TableColumn(Text(verbatim: "")) { lease in
                    Button("Revoke...") { revoking = lease.id }
                        .help("Revoke the lease, which deletes its keys")
                }
                .width(70)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 360)
        .task { await model.load(from: connection) }
        .confirmationDialog(
            "Revoke lease \(revoking.map { String($0, radix: 16) } ?? "")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
        ) {
            Button("Revoke Lease", role: .destructive) {
                guard let id = revoking else { return }
                Task { await model.revoke(id, from: connection) }
            }
        } message: {
            Text("Every key attached to it is deleted. This cannot be undone.")
        }
    }
}
