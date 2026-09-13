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

                Section {
                    if let error = model.devicesError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if model.pairedDevices.isEmpty {
                        Text("No devices reported.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pairedDevices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                    Text(Date(timeIntervalSince1970: Double(device.createdAt) / 1_000),
                                         style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.deviceId == model.currentDeviceId {
                                    // The Relay refuses a self-revoke, so the
                                    // row says why instead of offering it.
                                    Text("This iPhone")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if device.deviceId != model.currentDeviceId {
                                    Button(role: .destructive) {
                                        model.revokeDevice(device)
                                    } label: {
                                        Label("Revoke", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Devices paired to this Mac, as reported by the relay. Revoking one signs that device out immediately.")
                }

                Section {
                    Picker("Language", selection: Binding(
                        get: { model.language },
                        set: model.setLanguage
                    )) {
                        ForEach(DSHLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } footer: {
                    Text("Follow System uses your device language. The choice applies immediately.")
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
            .task { model.refreshPairedDevices() }
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
