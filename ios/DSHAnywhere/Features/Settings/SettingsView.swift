import SwiftUI

/// Everything that is about the connection rather than about a conversation.
/// Previously these controls were scattered across the sessions toolbar, which
/// gave them no home and left the relay address impossible to inspect in-app.
struct SettingsView: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showForgetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sessions") {
                    Toggle(isOn: Binding(
                        get: { model.groupsSessionsByWorkspace },
                        set: model.setGroupsSessionsByWorkspace
                    )) {
                        Label("Group by workspace", systemImage: "square.grid.2x2")
                    }
                    Toggle(isOn: Binding(
                        get: { model.showArchivedSessions },
                        set: model.setShowArchived
                    )) {
                        Label("Show archived", systemImage: "archivebox")
                    }
                }

                Section {
                    if model.machines.isEmpty {
                        Text("No paired Macs yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.machines, id: \.machineId) { machine in
                            Button {
                                model.switchMachine(machine)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(machine.machineName)
                                            .foregroundStyle(.primary)
                                        Text(machine.relayBaseURL.absoluteString)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if machine.machineId == model.activeMachine?.machineId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.removeMachine(machine)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Pairing another Mac adds it here instead of replacing the current one. Tap to switch, swipe to remove.")
                }

                Section("Connection") {
                    LabeledContent("Machine") {
                        Text(model.machineName)
                    }
                    LabeledContent("Status") {
                        Text(statusLabel)
                            .foregroundStyle(statusColor)
                    }
                    if let address = relayAddress {
                        LabeledContent("Relay") {
                            Text(address)
                                .textSelection(.enabled)
                        }
                    }
                    if !model.machineID.isEmpty {
                        LabeledContent("Machine ID") {
                            Text(model.machineID)
                                .textSelection(.enabled)
                                .font(.footnote.monospaced())
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showForgetConfirmation = true
                    } label: {
                        Label("Disconnect this iPhone", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(!model.isPaired)
                } footer: {
                    Text("Disconnecting removes the device token from this iPhone's keychain. The Mac keeps running.")
                }

                Section("About") {
                    LabeledContent("Version") {
                        Text(Self.versionDescription)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Disconnect this iPhone?",
                                isPresented: $showForgetConfirmation,
                                titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    model.forgetPairing()
                    dismiss()
                }
            } message: {
                Text("You will need the Mac's machine ID and pairing secret to pair again.")
            }
        }
    }

    /// The pairing screen saves the address, but nothing surfaced it afterwards.
    private var relayAddress: String? {
        let stored = UserDefaults.standard.string(forKey: "dsh-anywhere.server-address") ?? model.serverAddress
        return stored.isEmpty ? nil : stored
    }

    private var statusLabel: String {
        switch model.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environmentObject(DSHAppModel.preview())
    }
}
