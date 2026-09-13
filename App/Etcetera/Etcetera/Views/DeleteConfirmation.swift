//
//  DeleteConfirmation.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI

/// A key to delete, with everything below it when `subtreePrefix` is set.
struct DeleteTarget: Hashable {
    var key: Data
    var subtreePrefix: String?
}

/// Counts what a delete removes, then asks before doing it. See SPEC 4.5.
struct DeleteConfirmation: ViewModifier {
    @Binding var target: DeleteTarget?
    var connection: ConnectionModel
    var onDeleted: (DeletePlan) -> Void

    @State private var plan: DeletePlan?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .task(id: target) {
                guard let target else { return }
                do {
                    plan = try await connection.planDelete(key: target.key, subtreePrefix: target.subtreePrefix)
                } catch {
                    errorMessage = ConnectionModel.message(for: error)
                    self.target = nil
                }
            }
            .confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible, presenting: plan) { plan in
                Button("Delete \(plan.affected) Keys", role: .destructive) {
                    Task {
                        do {
                            try await connection.delete(plan)
                            onDeleted(plan)
                        } catch {
                            errorMessage = ConnectionModel.message(for: error)
                        }
                    }
                }
            } message: { plan in
                Text(message(for: plan))
            }
            .alert("Delete Failed", isPresented: errorPresented) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { plan != nil },
            set: { presented in
                if !presented {
                    plan = nil
                    target = nil
                }
            })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var title: String {
        guard let plan else { return "" }
        if plan.subtreePrefix != nil {
            return String(localized: "Delete \(plan.affected) keys?")
        }
        return String(localized: "Delete \(displayString(for: plan.key))?")
    }

    private func message(for plan: DeletePlan) -> String {
        guard let prefix = plan.subtreePrefix else { return String(localized: "This cannot be undone.") }
        if plan.key.isEmpty {
            return String(localized: "This deletes every key under \(prefix). It cannot be undone.")
        }
        return String(
            localized: "This deletes \(displayString(for: plan.key)) and every key under \(prefix). It cannot be undone.")
    }
}

extension View {
    func deleteConfirmation(
        _ target: Binding<DeleteTarget?>, connection: ConnectionModel, onDeleted: @escaping (DeletePlan) -> Void
    ) -> some View {
        modifier(DeleteConfirmation(target: target, connection: connection, onDeleted: onDeleted))
    }
}
