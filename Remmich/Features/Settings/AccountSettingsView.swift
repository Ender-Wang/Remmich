import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("User", value: "ender@remmich.local")
                    LabeledContent("Server", value: "Demo library")
                    LabeledContent("Access", value: "Read only")
                }

                Section("Connection") {
                    LabeledContent("Address", value: "Not connected")
                    LabeledContent("Automatic switching", value: "Coming in M2")
                }

                Section {
                    Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remmich")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("account-settings")
    }
}
