import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The creation surface is shared by the Remote home and conversation header.
struct NewSessionSheet: View {
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    private let initialWorkspaceID: String?
    @State private var workspaceID: String
    @State private var permissionMode = "workspace-write"
    @State private var sessionTitle = ""
    @State private var workingDirectory = ""
    @State private var branch = "main"
    @State private var sessionMode = "standard"
    @State private var selectedProvider = ""
    @State private var selectedModel = ""
    @State private var selectedReasoningEffort: String?
    @State private var initialPrompt = ""
    @State private var initialAttachments: [DSHStagedAttachment] = []
    @State private var selectedInitialPhotos: [PhotosPickerItem] = []
    @State private var showInitialPhotoPicker = false
    @State private var showInitialFileImporter = false
    @State private var showInitialCamera = false
    @State private var initialCapturedPhoto: UIImage?
    @State private var initialPreviewImage: UIImage?
    @State private var showInitialPreview = false
    @State private var showInitialContextPopover = false
    @State private var showInitialCommandMenu = false

    init(initialWorkspaceID: String? = nil, initialPrompt: String = "") {
        self.initialWorkspaceID = initialWorkspaceID
        _workspaceID = State(initialValue: initialWorkspaceID ?? "")
        _initialPrompt = State(initialValue: initialPrompt)
    }

    private var selectedWorkspace: DSHWorkspaceOption? {
        model.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        ZStack {
            // Opaque surface. Tapping the empty region deliberately does NOT
            // dismiss: the draft + staged attachments would be lost with no
            // confirmation, which is what made the sheet feel broken.
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 26) {
                    compactConfiguration
                        .padding(.horizontal, 6)

                    if !initialAttachments.isEmpty {
                        initialAttachmentStrip
                            .padding(.horizontal, 6)
                    }

                    initialPromptEditor
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: 44, height: 44)
                                .dshFloatingChrome(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    Text("新建任务")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(DSHHeaderBackdrop())
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(true)
        }
        .presentationBackground(Color(.systemBackground))
        .sheet(isPresented: $showInitialCommandMenu) {
            CommandMenuSheet(
                onCommand: { command in
                    showInitialCommandMenu = false
                    initialPrompt = appendCommand(command, to: initialPrompt)
                },
                onDismiss: { showInitialCommandMenu = false }
            )
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $showInitialPhotoPicker,
                      selection: $selectedInitialPhotos,
                      maxSelectionCount: 10,
                      matching: .images)
        .fullScreenCover(isPresented: $showInitialCamera) {
            DSHCameraPicker(image: $initialCapturedPhoto)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showInitialPreview) {
            if let initialPreviewImage {
                DSHImageViewer(image: initialPreviewImage, name: "预览")
            }
        }
        .onChange(of: initialCapturedPhoto) { _, photo in
            guard let photo else { return }
            initialCapturedPhoto = nil
            Task { @MainActor in
                let raw = await Task.detached(priority: .userInitiated) {
                    photo.jpegData(compressionQuality: 0.9)
                }.value
                guard let raw else {
                    model.errorMessage = "无法读取图片，请重试。"
                    return
                }
                let optimized = await optimizedPhotoDataOffMain(raw)
                initialAttachments.append(DSHStagedAttachment(name: "camera.jpg",
                                                              data: optimized,
                                                              isImage: true))
            }
        }
        .fileImporter(isPresented: $showInitialFileImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    initialAttachments.append(DSHStagedAttachment(
                        name: url.lastPathComponent,
                        data: data,
                        isImage: ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
                    ))
                }
            }
        }
        .onChange(of: selectedInitialPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedInitialPhotos = []
            Task { @MainActor in
                var staged = 0
                for item in items.prefix(10) {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                        let optimized = await optimizedPhotoDataOffMain(data)
                        initialAttachments.append(DSHStagedAttachment(name: "photo.jpg",
                                                                      data: optimized,
                                                                      isImage: true))
                        staged += 1
                    } catch {
                        continue
                    }
                }
                if staged == 0 {
                    model.errorMessage = "无法读取图片，请重试。"
                }
            }
        }
        .onAppear {
            if workspaceID.isEmpty, let first = model.workspaces.first {
                selectWorkspace(first)
            }
            // If the project disappeared between tapping the button and
            // opening the sheet, fall back to the first current workspace.
            if initialWorkspaceID != nil, selectedWorkspace == nil,
               let first = model.workspaces.first {
                selectWorkspace(first)
            }
            if workingDirectory.isEmpty,
               let cwd = model.sessions.first(where: { $0.workspaceId == workspaceID })?.cwd {
                workingDirectory = cwd
            }
            if selectedProvider.isEmpty, let catalog = model.modelCatalog {
                selectedProvider = catalog.default.provider
                selectedModel = catalog.default.model
                selectedReasoningEffort = catalog.default.reasoningEffort
            }
        }
        .onChange(of: model.machineID) { _, _ in
            workspaceID = ""
            workingDirectory = ""
            branch = "main"
        }
        .onChange(of: model.workspaces) { _, workspaces in
            if workspaceID.isEmpty, let first = workspaces.first {
                selectWorkspace(first)
            }
        }
        .onChange(of: model.modelCatalog) { _, catalog in
            guard selectedModel.isEmpty, let catalog else { return }
            selectedProvider = catalog.default.provider
            selectedModel = catalog.default.model
            selectedReasoningEffort = catalog.default.reasoningEffort
        }
    }

    /// The two visible selectors mirror the compact information cluster in the
    /// reference: machine and project. The project menu also contains the
    /// branch/worktree and mode sections, keeping those choices available
    /// without adding rows that are absent from the Remote compose surface.
    private var compactConfiguration: some View {
        VStack(alignment: .leading, spacing: 20) {
            machineSelector
            workspaceSelector
        }
        .padding(.horizontal, 14)
    }

    private var machineSelector: some View {
        Menu {
            if model.machines.isEmpty {
                Text(model.machineName.isEmpty ? "Mac" : model.machineName)
            } else {
                ForEach(model.machines, id: \.machineId) { machine in
                    Button {
                        model.switchMachine(machine)
                    } label: {
                        Label(machine.machineName,
                              systemImage: machine.machineId == model.activeMachine?.machineId
                                ? "checkmark" : "desktopcomputer")
                    }
                }
            }
        } label: {
            newSessionInfoRow(icon: "desktopcomputer",
                              title: model.machineName.isEmpty ? "Mac" : model.machineName)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var workspaceSelector: some View {
        Menu {
            Section("项目") {
                if model.workspaces.isEmpty {
                    Text("暂无可用工作区")
                } else {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            selectWorkspace(workspace)
                        } label: {
                            Label(workspace.name,
                                  systemImage: workspace.id == workspaceID ? "checkmark" : "folder")
                        }
                    }
                }
            }
            Divider()
            Section("分支") {
                Button {
                    branch = ""
                } label: {
                    Label("不使用工作树", systemImage: branch.isEmpty ? "checkmark" : "arrow.triangle.branch")
                }
                ForEach(branchOptions, id: \.self) { option in
                    Button {
                        branch = option
                    } label: {
                        Label(option, systemImage: branch == option ? "checkmark" : "arrow.triangle.branch")
                    }
                }
            }
            Section("模式") {
                modeButton("standard", title: "标准模式", icon: "sparkles")
                modeButton("ptc", title: "PTC 模式", icon: "list.clipboard")
                modeButton("custom", title: "自建模式", icon: "slider.horizontal.3")
            }
        } label: {
            newSessionInfoRow(icon: "folder",
                              title: selectedWorkspace?.name ?? displayedWorkingDirectory)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var branchSelector: some View {
        Menu {
            Button {
                branch = ""
            } label: {
                Label("不使用工作树", systemImage: branch.isEmpty ? "checkmark" : "arrow.triangle.branch")
            }
            ForEach(branchOptions, id: \.self) { option in
                Button {
                    branch = option
                } label: {
                    Label(option, systemImage: branch == option ? "checkmark" : "arrow.triangle.branch")
                }
            }
        } label: {
            newSessionInfoRow(icon: "arrow.triangle.branch",
                              title: branch.isEmpty ? "不使用工作树" : branch)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private var modeSelector: some View {
        Menu {
            modeButton("standard", title: "标准模式", icon: "sparkles")
            modeButton("ptc", title: "PTC 模式", icon: "list.clipboard")
            modeButton("custom", title: "自建模式", icon: "slider.horizontal.3")
        } label: {
            newSessionInfoRow(icon: "cpu", title: sessionModeLabel)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private func modeButton(_ mode: String, title: String, icon: String) -> some View {
        Button { sessionMode = mode } label: {
            Label(title, systemImage: sessionMode == mode ? "checkmark" : icon)
        }
    }

    private func newSessionInfoRow(icon: String, title: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var displayedWorkingDirectory: String {
        let path = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return selectedWorkspace?.name ?? "选择工作区" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return path }
        let suffix = components.dropFirst(2).joined(separator: "/")
        return suffix.isEmpty ? "~" : "~/\(suffix)"
    }

    private var branchOptions: [String] {
        var values = Set(model.sessions
            .filter { workspaceID.isEmpty || $0.workspaceId == workspaceID }
            .compactMap { $0.branch?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        values.insert("main")
        return values.sorted { lhs, rhs in
            if lhs == "main" { return true }
            if rhs == "main" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private var sessionModeLabel: String {
        switch sessionMode {
        case "ptc": return "PTC 模式"
        case "custom": return "自建模式"
        default: return "标准模式"
        }
    }

    private func selectWorkspace(_ workspace: DSHWorkspaceOption) {
        workspaceID = workspace.id
        guard let recent = model.sessions
            .filter({ $0.workspaceId == workspace.id })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            workingDirectory = ""
            branch = "main"
            return
        }
        workingDirectory = recent.cwd ?? ""
        branch = recent.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"
        if branch.isEmpty { branch = "main" }
    }

    private var machineInfo: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.machineName.isEmpty ? "Mac" : model.machineName)
                    .font(.headline)
                Text(machineStatusLabel)
                    .font(.caption)
                    .foregroundStyle(machineStatusColor)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var machineStatusLabel: String {
        switch model.deviceStatus {
        case .offline: return "离线"
        case .error: return "连接错误"
        case .online: return "已连接"
        case .approvalRequired: return "需要确认权限"
        }
    }

    private var machineStatusColor: Color {
        switch model.deviceStatus {
        case .offline: return .gray
        case .error: return .red
        case .online: return .green
        case .approvalRequired: return .yellow
        }
    }

    private var workspaceChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Workspace")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if model.workspaces.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No workspace is available yet")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Menu {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            workspaceID = workspace.id
                        } label: {
                            Label(workspace.name, systemImage: workspace.id == workspaceID ? "checkmark" : "folder")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        Text(selectedWorkspace?.name ?? "Select workspace")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace " + (selectedWorkspace?.name ?? ""))
            }
        }
    }

    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("模式与权限")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 1) {
                sessionModeOption(mode: "standard", title: "标准模式", detail: "适合日常问答与代码任务。", icon: "sparkles")
                sessionModeOption(mode: "ptc", title: "PTC 模式", detail: "先规划，再执行代码任务。", icon: "list.clipboard")
                sessionModeOption(mode: "custom", title: "自建模式", detail: "使用本机 Harness 的自定义预设。", icon: "slider.horizontal.3")
                Divider().padding(.horizontal, 16)
                permissionOption(
                    mode: "read-only",
                    title: "仅可查看",
                    detail: "只能读取工作区内容。",
                    icon: "eye"
                )
                permissionOption(
                    mode: "workspace-write",
                    title: "工作区内修改",
                    detail: "可以读取并修改所选工作区文件。",
                    icon: "folder"
                )
                permissionOption(
                    mode: "danger-full-access",
                    title: "完全权限",
                    detail: "可以读写工作区之外的文件。",
                    icon: "lock.open"
                )
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func sessionModeOption(mode: String, title: String, detail: String, icon: String) -> some View {
        Button { sessionMode = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(sessionMode == mode ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .medium))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: sessionMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(sessionMode == mode ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pathAndBranchChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("项目目录与分支")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    TextField("项目目录（可选）", text: $workingDirectory)
                        .textFieldStyle(.plain)
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    TextField("分支", text: $branch)
                        .textFieldStyle(.plain)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// The first prompt uses the same compact composer as an existing
    /// conversation. Its plus action is the same three-entry native menu;
    /// selecting files only stages them locally until Create/send commits the
    /// new session.
    private var initialPromptEditor: some View {
        DSHRemoteComposer(text: $initialPrompt,
                          placeholder: "在 \(model.machineName.isEmpty ? "Mac" : model.machineName) 上工作",
                          hasAttachments: !initialAttachments.isEmpty,
                          autofocus: true,
                          showsMicrophone: false,
                          onSubmit: createSession,
                          slashCommands: DSHSlashCommands,
                          onSlashCommand: { command in
                              initialPrompt = dshCompleteSlashCommand(command, in: initialPrompt)
                          }) {
            if model.collapseComposerControls {
                DSHComposerQuickActionsMenu(
                    onCommand: { command in
                        initialPrompt = appendCommand(command, to: initialPrompt)
                    },
                    onPhoto: { showInitialPhotoPicker = true },
                    onFile: { showInitialFileImporter = true },
                    onCamera: { showInitialCamera = true }
                )
            } else {
                HStack(spacing: 0) {
                    Button { showInitialCommandMenu = true } label: {
                        Image(systemName: "slash.circle").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Commands")
                    Button { showInitialPhotoPicker = true } label: {
                        Image(systemName: "photo").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Attach photos")
                    Button { showInitialFileImporter = true } label: {
                        Image(systemName: "paperclip").frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Attach file")
                }
                .font(.system(size: DSHComposerGlyphHeight))
                .buttonStyle(.plain)
            }
        } configuration: {
            DSHComposerPermissionPicker(mode: $permissionMode)
            Spacer(minLength: 0)
            // Same ring control as the conversation composer. There is no
            // session (and therefore no usage) yet, so it only explains that.
            Button { showInitialContextPopover = true } label: {
                DSHContextRing(ratio: 0)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂无上下文用量数据")
            .popover(isPresented: $showInitialContextPopover, arrowEdge: .bottom) {
                Text("新建会话暂无上下文用量数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
            }
            DSHModelConfigurationPicker(
                catalog: model.modelCatalog,
                selection: initialModelSelection,
                fallbackName: initialModelLabel,
                fallbackEfforts: selectedModelReasoning?.efforts ?? [],
                compact: true,
                onCommit: { _ in }
            )
        } submit: {
            Button(action: createSession) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(canCreateSession ? Color.accentColor : Color(.systemGray5), in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(!canCreateSession)
            .accessibilityLabel("Create session")
        }
    }

    private var canCreateSession: Bool {
        !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !initialAttachments.isEmpty
    }

    private var initialAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(initialAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage, let image = UIImage(data: attachment.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    initialPreviewImage = image
                                    showInitialPreview = true
                                }
                        }
                        Label(attachment.name, systemImage: attachment.isImage ? "photo" : "paperclip")
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            initialAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除附件")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: .capsule)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var selectedModelReasoning: DSHModelReasoning? {
        guard let catalog = model.modelCatalog else { return nil }
        if let group = catalog.groups.first(where: { $0.id == selectedProvider }),
           let item = group.models.first(where: { $0.id == selectedModel }) {
            return item.reasoning
        }
        return catalog.groups.lazy
            .compactMap { $0.models.first(where: { $0.id == selectedModel })?.reasoning }
            .first
    }

    /// The new-session composer keeps the same model picker state shape as a
    /// live conversation.  The selection stays local until Create is pressed,
    /// because there is no session to notify yet.
    private var initialModelSelection: Binding<DSHModelSelection> {
        Binding(
            get: {
                if !selectedModel.isEmpty {
                    return DSHModelSelection(
                        provider: selectedProvider.isEmpty ? "deepseek" : selectedProvider,
                        model: selectedModel,
                        reasoningEffort: selectedReasoningEffort
                    )
                }
                return model.modelCatalog?.default
                    ?? DSHModelSelection(provider: "", model: "", reasoningEffort: nil)
            },
            set: { selection in
                selectedProvider = selection.provider
                selectedModel = selection.model
                selectedReasoningEffort = selection.reasoningEffort
            }
        )
    }

    private var initialModelLabel: String {
        guard !selectedModel.isEmpty else { return "选择模型" }
        return model.modelLabel(for: DSHModelSelection(
            provider: selectedProvider.isEmpty ? "deepseek" : selectedProvider,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort
        ))
    }

    private func appendCommand(_ command: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/\(command) " : "\(text)\n/\(command) "
    }

    private func permissionOption(mode: String, title: String, detail: String, icon: String) -> some View {
        Button { permissionMode = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(permissionMode == mode ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: permissionMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(permissionMode == mode ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(permissionMode == mode ? .isSelected : [])
    }

    private func createSession() {
        guard !model.workspaces.isEmpty else { return }
        let selection = selectedModel.isEmpty ? nil : DSHModelSelection(
            provider: selectedProvider.isEmpty ? "deepseek" : selectedProvider,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort
        )
        model.createSession(in: selectedWorkspace,
                            title: sessionTitle.isEmpty ? "新会话" : sessionTitle,
                            workingDirectory: workingDirectory,
                            branch: branch,
                            mode: sessionMode,
                            model: selection,
                            permissionMode: permissionMode,
                            initialPrompt: initialPrompt,
                            initialAttachments: initialAttachments)
        dismiss()
    }
}

// MARK: - ChatGPT Remote task home

private enum DSHRemoteHomeMetrics {
    /// Both project titles and their child conversations resolve against this
    /// exact anchor; they no longer depend on two independently tuned paddings.
    static let projectTextInset: CGFloat = 47
}

private struct DSHRemoteHomeWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The production home for DSH Anywhere: project cards, task rows, one stable
/// header, and native controls for search and starting work.
struct DSHRemoteHomeView: View {
    @EnvironmentObject private var model: DSHAppModel
    @State private var navigationPath: [String] = []
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var homeContentWidth: CGFloat = 0
    @State private var showNewTask = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--dsh-preview-new-session")
        #else
        return false
        #endif
    }()
    @State private var newTaskWorkspaceID: String?
    @State private var newTaskPrompt = ""
    @State private var didRefresh = false
    @State private var renameWorkspaceID = ""
    @State private var renameWorkspaceText = ""
    @State private var showRenameWorkspace = false
    @State private var pendingWorkspaceDeletion: DSHSessionGroup?
    @State private var showDeleteWorkspaceConfirmation = false

    private var groupedSessions: [DSHSessionGroup] {
        model.sessions
            .groupedForList(.byWorkspace, showArchived: model.showArchivedSessions)
            .filter { !model.hiddenWorkspaceIDs.contains($0.id) }
            .map { group in
                let title = group.id == DSHSessionGroup.flatGroupID
                    ? group.title
                    : model.workspaceDisplayName(for: group.id, fallback: group.title)
                return DSHSessionGroup(id: group.id, title: title,
                                       sessions: group.sessions,
                                       isUnfiled: group.isUnfiled)
            }
    }

    private var flatSessions: [DSHSessionSummary] {
        model.sessions
            .groupedForList(.flat, showArchived: model.showArchivedSessions)
            .flatMap(\.sessions)
            .filter { session in
                guard let workspaceID = session.workspaceId else { return true }
                return !model.hiddenWorkspaceIDs.contains(workspaceID)
            }
    }

    private var hasArchivedSessions: Bool {
        model.sessions.contains { $0.archived == true }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedGroupedSessions: [DSHSessionGroup] {
        guard !searchQuery.isEmpty else { return groupedSessions }
        return groupedSessions.compactMap { group in
            let sessions = group.sessions.filter { session in
                session.title.localizedCaseInsensitiveContains(searchQuery)
                    || (session.workspaceName ?? "").localizedCaseInsensitiveContains(searchQuery)
            }
            guard !sessions.isEmpty || group.title.localizedCaseInsensitiveContains(searchQuery) else { return nil }
            return DSHSessionGroup(id: group.id, title: group.title,
                                   sessions: sessions, isUnfiled: group.isUnfiled)
        }
    }

    private var displayedFlatSessions: [DSHSessionSummary] {
        guard !searchQuery.isEmpty else { return flatSessions }
        return flatSessions.filter { session in
            session.title.localizedCaseInsensitiveContains(searchQuery)
                || (session.workspaceName ?? "").localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var deviceName: String {
        let value = model.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Mac" : value
    }

    private var deviceStatusColor: Color {
        switch model.deviceStatus {
        case .offline: return .gray
        case .error: return .red
        case .online: return .green
        case .approvalRequired: return .yellow
        }
    }

    private var deviceStatusLabel: String {
        switch model.deviceStatus {
        case .offline: return DSHLocalization.string("Offline")
        case .error: return DSHLocalization.string("Connection error")
        case .online: return DSHLocalization.string("Connected")
        case .approvalRequired: return DSHLocalization.string("Permission confirmation required")
        }
    }

    /// A session snapshot is authoritative only after the first one arrives.
    /// Treat the socket handshake as a separate loading phase so a reconnect
    /// never flashes an empty task browser before the existing tasks are
    /// restored. Once the machine is known to be offline/failed, switch to the
    /// actionable unreachable state instead of spinning forever.
    private var isLoadingTasks: Bool {
        guard !model.hasLoadedSessions else { return false }
        switch model.connectionState {
        case .connecting, .reconnecting:
            return true
        case .connected:
            return model.deviceStatus != .offline && model.deviceStatus != .error
        case .disconnected, .failed:
            return false
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if isLoadingTasks {
                        remoteLoadingState
                    } else if model.groupsSessionsByWorkspace {
                        if displayedGroupedSessions.isEmpty {
                            remoteEmptyState
                        } else {
                            Text("项目")
                                .font(.system(size: 17, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(displayedGroupedSessions) { group in
                                remoteProjectSection(group)
                            }
                        }
                    } else {
                        if displayedFlatSessions.isEmpty {
                            remoteEmptyState
                        } else {
                            ForEach(displayedFlatSessions) { session in
                                NavigationLink(value: session.id) {
                                    DSHRemoteTaskRow(session: session, showWorkspaceName: true, flatStyle: true)
                                        .environmentObject(model)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { archiveAction(for: session) }
                            }
                        }
                    }

                    if hasArchivedSessions {
                        archivedDivider
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .id(model.groupsSessionsByWorkspace ? "remote-workspaces" : "remote-flat")
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                model.refreshSessions(includeArchived: model.showArchivedSessions)
                model.sendModelCatalog()
            }
            .background(Color(.systemBackground))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DSHRemoteHomeWidthPreferenceKey.self,
                                           value: proxy.size.width)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !showSearch { remoteHeader }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar { remoteHomeToolbar }
            .toolbarBackground(.visible, for: .bottomBar)
            .toolbarBackground(.ultraThinMaterial, for: .bottomBar)
            .navigationDestination(for: String.self) { id in
                ConversationView(sessionID: id)
            }
            .transaction { transaction in
                // A task snapshot can contain hundreds of changed sessions
                // after a reconnect. Do not animate the entire list tree.
                transaction.animation = nil
            }
            // Full-screen so the composer sits above the keyboard and the
            // surface stays opaque like the Remote reference. Dismissal is
            // explicit via the back button to avoid losing a typed draft.
            .fullScreenCover(isPresented: $showNewTask, onDismiss: {
                newTaskPrompt = ""
                newTaskWorkspaceID = nil
            }) {
                NewSessionSheet(initialWorkspaceID: newTaskWorkspaceID,
                                initialPrompt: newTaskPrompt)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .alert("重命名项目", isPresented: $showRenameWorkspace) {
                TextField("项目名称", text: $renameWorkspaceText)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    model.renameWorkspace(id: renameWorkspaceID, to: renameWorkspaceText)
                }
            }
            .confirmationDialog("删除项目？", isPresented: $showDeleteWorkspaceConfirmation,
                                titleVisibility: .visible,
                                presenting: pendingWorkspaceDeletion) { group in
                Button("删除并归档会话", role: .destructive) {
                    model.deleteWorkspace(group)
                }
                Button("取消", role: .cancel) { }
            } message: { group in
                Text("将删除项目“\(group.title)”并归档其中的 \(group.sessions.count) 个会话。项目目录和历史记录仍保留在 Mac 上。")
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                guard let sessionID else { return }
                if navigationPath.last != sessionID {
                    navigationPath.append(sessionID)
                }
                model.selectedSessionID = nil
            }
            .task {
                if !model.hasLoadedSessions {
                    model.refreshSessions()
                }
            }
            .onPreferenceChange(DSHRemoteHomeWidthPreferenceKey.self) { width in
                guard width > 0, abs(homeContentWidth - width) > 0.5 else { return }
                homeContentWidth = width
            }
        }
    }

    private var remoteLoadingState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 116)
            ProgressView()
                .controlSize(.large)
                .tint(.secondary)
            Text(DSHLocalization.string("Loading tasks…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 116)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DSHLocalization.string("Loading tasks…"))
    }

    private var remoteHeader: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("远程")
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(deviceStatusColor)
                        .frame(width: 7, height: 7)
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(deviceName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button { refreshTasks() } label: {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .dshFloatingChrome(Circle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新会话列表")

                Spacer(minLength: 0)

                Menu {
                    Button { openNewTask() } label: {
                        HStack(spacing: 8) {
                            DSHRemoteComposeGlyph(size: 18)
                            Text("新建任务")
                        }
                    }
                    Button { refreshTasks() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Section("排序") {
                        Button { model.setGroupsSessionsByWorkspace(true) } label: {
                            Label("按项目", systemImage: model.groupsSessionsByWorkspace ? "checkmark" : "folder")
                        }
                        Button { model.setGroupsSessionsByWorkspace(false) } label: {
                            Label("按时间倒序排列", systemImage: model.groupsSessionsByWorkspace ? "clock" : "checkmark")
                        }
                    }
                    Divider()
                    Section("管理") {
                        Button { model.setShowArchived(true) } label: {
                            Label("已归档任务", systemImage: "archivebox")
                        }
                        Button { showSettings = true } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .dshFloatingChrome(Circle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多选项")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(DSHHeaderBackdrop())
    }

    @ViewBuilder
    private func remoteProjectSection(_ group: DSHSessionGroup) -> some View {
        let expanded = !model.isGroupCollapsed(group.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    toggleGroup(group, expanded: expanded)
                } label: {
                    DSHRemoteFolderGlyph(expanded: expanded)
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)

                Button {
                    toggleGroup(group, expanded: expanded)
                } label: {
                    Text(group.title.isEmpty ? DSHLocalization.string("Sessions") : group.title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.leading, DSHRemoteHomeMetrics.projectTextInset - 8 - 28)

                Spacer(minLength: 6)

                Button { openNewTask(for: group) } label: {
                    DSHRemoteComposeGlyph(size: 20)
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .tint(.secondary)
                .accessibilityLabel("在项目中新建任务")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 11)
            .contextMenu {
                Button { toggleGroup(group, expanded: expanded) } label: {
                    Label(expanded ? "收起项目" : "展开项目",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                Button { refreshTasks() } label: { Label("刷新项目", systemImage: "arrow.clockwise") }
                if !group.isUnfiled {
                    Button { beginRename(group) } label: { Label("重命名项目", systemImage: "pencil") }
                    Button(role: .destructive) { beginDelete(group) } label: { Label("删除项目", systemImage: "trash") }
                }
            }

            if expanded {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: session.id) {
                        DSHRemoteTaskRow(session: session,
                                         showWorkspaceName: false,
                                         flatStyle: false,
                                         projectStyle: true)
                            .environmentObject(model)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { archiveAction(for: session) }

                    if index < group.sessions.count - 1 { Spacer().frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var remoteEmptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 96)
            Image(systemName: model.deviceStatus == .online
                  ? "bubble.left.and.bubble.right"
                  : "icloud.slash")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
            Text(model.deviceStatus == .online
                 ? DSHLocalization.string("No tasks yet")
                 : "\(deviceName) \(DSHLocalization.string("is unreachable"))")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.deviceStatus == .online
                 ? DSHLocalization.string("Start one on a connected machine.")
                 : DSHLocalization.string("Bring a machine online to start a session."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if model.deviceStatus == .online { openNewTask() } else { showSettings = true }
            } label: {
                Text(model.deviceStatus == .online
                     ? DSHLocalization.string("New task")
                     : DSHLocalization.string("Troubleshoot"))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Spacer(minLength: 96)
        }
        .frame(maxWidth: .infinity)
    }

    /// Native toolbar semantics keep the bottom controls aligned with the
    /// system glass and keyboard inset on every supported iOS version.
    @ToolbarContentBuilder
    private var remoteHomeToolbar: some ToolbarContent {
        if showSearch {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    TextField("搜索聊天", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFieldFocused)
                        .submitLabel(.search)
                        .frame(width: homeSearchWidth)
                        .accessibilityIdentifier("home-search-field")
                        .task { searchFieldFocused = true }

                    Button {
                        searchText = ""
                        showSearch = false
                        searchFieldFocused = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭搜索")
                }
                .layoutPriority(1)
            }
        } else {
            // Keep the two actions as separate native toolbar items. A wide
            // custom group can be treated as one overflowing item by iOS and
            // the system then drops the leading search control altogether.
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showSearch = true
                    searchFieldFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .medium))
                        Text("搜索聊天")
                            .lineLimit(1)
                    }
                    .frame(width: homeSearchWidth, height: 44, alignment: .leading)
                }
                .accessibilityLabel("搜索聊天")
                .accessibilityIdentifier("home-search-button")
            }

            ToolbarItem(placement: .bottomBar) {
                Button { openNewTask() } label: {
                    HStack(spacing: 8) {
                        DSHRemoteComposeGlyph(size: 17)
                        Text("聊天").fixedSize()
                    }
                    .padding(.horizontal, 8)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("新建聊天")
                .accessibilityIdentifier("home-new-chat-button")
            }
        }
    }

    /// Reserve the trailing chat action and toolbar margins while allowing
    /// the search control to fill the remaining width on each device.
    private var homeSearchWidth: CGFloat {
        let reservedWidth: CGFloat = showSearch ? 56 : 184
        let fallbackWidth: CGFloat = showSearch ? 220 : 224
        let available = homeContentWidth > 0 ? homeContentWidth : 402
        // The system bottom bar adds its own margins around each item. Keep
        // enough room for the trailing action so iOS does not hide this item,
        // while retaining the broad search field from the original home.
        return min(236, max(190, min(available - reservedWidth, fallbackWidth)))
    }

    private var archivedDivider: some View {
        Button {
            model.setShowArchived(!model.showArchivedSessions)
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.28)).frame(height: 1)
                Text(DSHLocalization.string(model.showArchivedSessions ? "Hide archived" : "Show archived"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Image(systemName: model.showArchivedSessions ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Rectangle().fill(Color.secondary.opacity(0.28)).frame(height: 1)
            }
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func archiveAction(for session: DSHSessionSummary) -> some View {
        Button {
            model.archive(session, archived: session.archived != true)
        } label: {
            Label(DSHLocalization.string(session.archived == true ? "Unarchive" : "Archive"),
                  systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox")
        }
    }

    private func toggleGroup(_ group: DSHSessionGroup, expanded: Bool) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            model.setGroup(group.id, collapsed: expanded)
        }
    }

    private func openNewTask(for group: DSHSessionGroup) {
        let workspace = group.sessions.first.flatMap { session -> DSHWorkspaceOption? in
            guard let id = session.workspaceId else { return nil }
            return DSHWorkspaceOption(id: id,
                                      name: model.workspaceDisplayName(for: id,
                                                                        fallback: session.workspaceName ?? group.title))
        }
        openNewTask(for: workspace)
    }

    private func openNewTask(for workspace: DSHWorkspaceOption? = nil) {
        newTaskWorkspaceID = workspace?.id
        showNewTask = true
    }

    private func beginRename(_ group: DSHSessionGroup) {
        renameWorkspaceID = group.id
        renameWorkspaceText = group.title
        showRenameWorkspace = true
    }

    private func beginDelete(_ group: DSHSessionGroup) {
        pendingWorkspaceDeletion = group
        showDeleteWorkspaceConfirmation = true
    }

    private func refreshTasks() {
        model.refreshSessions()
        didRefresh = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didRefresh = false
        }
    }
}

/// A task row intentionally contains enough context to be useful without
/// opening it: title, project (in flat mode), mode/model, running/unread state,
/// and the last activity time. Project-group rows use the same plain indented
/// typography as Remote; flat rows retain the chevron/date treatment.
private struct DSHRemoteTaskRow: View {
    @EnvironmentObject private var model: DSHAppModel
    let session: DSHSessionSummary
    let showWorkspaceName: Bool
    let flatStyle: Bool
    /// Project-group rows use the same quiet, indented text rhythm as Remote:
    /// no tile, no card and no extra disclosure glyph. The surrounding
    /// project header already supplies the visual grouping.
    let projectStyle: Bool

    init(session: DSHSessionSummary,
         showWorkspaceName: Bool,
         flatStyle: Bool,
         projectStyle: Bool = false) {
        self.session = session
        self.showWorkspaceName = showWorkspaceName
        self.flatStyle = flatStyle
        self.projectStyle = projectStyle
    }

    private var title: String {
        let value = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? DSHLocalization.string("New session") : value
    }

    private var unread: Bool { model.isSessionUnread(session) }

    private var iconName: String {
        if session.running == true { return "arrow.triangle.2.circlepath" }
        let mode = (session.mode ?? session.agentPreset ?? "").lowercased()
        if mode.contains("ptc") || mode.contains("plan") { return "list.clipboard" }
        let lowerTitle = title.lowercased()
        if lowerTitle.contains("bash") || lowerTitle.contains("command") || lowerTitle.contains("run") {
            return "terminal"
        }
        if lowerTitle.contains("refactor") || lowerTitle.contains("code") {
            return "doc.text"
        }
        return "bubble.left"
    }

    private var iconColor: Color {
        if session.running == true { return .accentColor }
        if unread { return .green }
        return .secondary
    }

    private var updatedLabel: String {
        guard session.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return DSHLocalization.string("Yesterday")
        }
        return Self.dayFormatter.string(from: date)
    }

    private var workspaceLabel: String? {
        guard showWorkspaceName,
              let workspace = session.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty else { return nil }
        return workspace
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    var body: some View {
        if projectStyle {
            projectRow
        } else {
            standardRow
        }
    }

    private var projectRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .leading) { sessionDotGutter }
        .padding(.leading, DSHRemoteHomeMetrics.projectTextInset)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Traffic-light dot floating in the gutter left of the title: it never
    /// takes title margin, and rows with and without a dot align identically.
    @ViewBuilder
    private var sessionDotGutter: some View {
        switch model.sessionDot(for: session) {
        case .red:
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .offset(x: -21)
                .accessibilityLabel("出错")
        case .yellow:
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
                .offset(x: -21)
                .accessibilityLabel("需要确认")
        case .green:
            Circle().fill(Color.green).frame(width: 7, height: 7)
                .offset(x: -21)
                .accessibilityLabel(session.running == true ? "Running" : "Unread")
        case .none:
            EmptyView()
        }
    }

    private var standardRow: some View {
        HStack(spacing: 12) {
            if !flatStyle {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("会话图标")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .font(.system(size: 17, weight: unread ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if flatStyle, !updatedLabel.isEmpty {
                        Text(updatedLabel)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .overlay(alignment: .leading) { sessionDotGutter }
                if flatStyle, let workspaceLabel {
                    Text(workspaceLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if flatStyle {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
            }
        }
        .padding(.leading, flatStyle ? 16 : 20)
        .padding(.trailing, flatStyle ? 16 : 20)
        .padding(.vertical, flatStyle ? 11 : 9)
        .contentShape(Rectangle())
    }
}
