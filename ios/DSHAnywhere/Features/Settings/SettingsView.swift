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
                    Toggle(isOn: Binding(
                        get: { model.collapseComposerControls },
                        set: model.setCollapseComposerControls
                    )) {
                        Label("Collapse composer controls", systemImage: "rectangle.compress.vertical")
                    }
                    Toggle(isOn: Binding(
                        get: { model.showUsageFooter },
                        set: model.setShowUsageFooter
                    )) {
                        Label("Show session usage", systemImage: "chart.bar.xaxis")
                    }
                    Toggle(isOn: Binding(
                        get: { model.showMessageActionsByDefault },
                        set: model.setShowMessageActionsByDefault
                    )) {
                        Label("Show message actions by default", systemImage: "ellipsis.circle")
                    }
                }
                .listRowBackground(settingsSectionBackground)

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
                .listRowBackground(settingsSectionBackground)

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
                .listRowBackground(settingsSectionBackground)

                Section {
                    Picker("Language", selection: Binding<DSHLanguage>(
                        get: { model.language },
                        // Keep the setter as an explicit closure. Newer
                        // Swift compilers have crashed while lowering a
                        // method reference here during CI's IR generation.
                        set: { value in model.setLanguage(value) }
                    )) {
                        ForEach(DSHLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } footer: {
                    Text("Follow System uses your device language. The choice applies immediately.")
                }
                .listRowBackground(settingsSectionBackground)

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
                .listRowBackground(settingsSectionBackground)

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
                .listRowBackground(settingsSectionBackground)

                Section("About") {
                    LabeledContent("Version") {
                        Text(Self.versionDescription)
                    }
                }
                .listRowBackground(settingsSectionBackground)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .listRowSeparator(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { settingsHeader }
            .toolbar(.hidden, for: .navigationBar)
            .task { model.refreshPairedDevices() }
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

    /// A stable 44pt glass header keeps Settings in the same visual family as
    /// the Home and Conversation pages. The native navigation bar is hidden so
    /// it cannot introduce a second title or differently-sized Done button.
    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .dshFloatingChrome(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close settings")

            Spacer(minLength: 0)
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 52, minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(DSHHeaderBackdrop())
    }

    /// Keep every section on the same quiet grouped surface. Connection state
    /// remains visible through its status text instead of competing row tints.
    private var settingsSectionBackground: Color {
        Color(.secondarySystemGroupedBackground)
    }

    /// The pairing screen saves the address, but nothing surfaced it afterwards.
    private var relayAddress: String? {
        let stored = UserDefaults.standard.string(forKey: "dsh-anywhere.server-address") ?? model.serverAddress
        return stored.isEmpty ? nil : stored
    }

    private var statusLabel: String {
        switch model.deviceStatus {
        case .online: return DSHLocalization.string("Connected")
        case .approvalRequired: return DSHLocalization.string("Permission confirmation required")
        case .error: return DSHLocalization.string("Connection failed")
        case .offline: return DSHLocalization.string("Disconnected")
        }
    }

    private var statusColor: Color {
        switch model.deviceStatus {
        case .online: return .green
        case .approvalRequired: return .yellow
        case .error: return .red
        case .offline: return .gray
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
