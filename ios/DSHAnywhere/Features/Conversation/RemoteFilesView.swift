import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ImageIO

struct DSHRemoteFilesPanel: View {
    let sessionID: String
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = 0
    @State private var paths = [""]
    @State private var listing: DSHWorkspaceFiles?
    @State private var loading = false
    @State private var error: String?
    @State private var selected: DSHFileReference?
    @State private var loadID = UUID()

    private var outputLinks: [DSHFileReference] {
        model.fileReferences(for: sessionID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("文件来源", selection: $source) {
                        Text("工作区").tag(0)
                        Text("对话文件").tag(1)
                    }.pickerStyle(.segmented)
                }
                if source == 0 {
                    Section {
                        if paths.count > 1 {
                            Button { paths.removeLast(); loadID = UUID() } label: { Label("上一级", systemImage: "chevron.left") }
                        }
                        Text(paths.last?.isEmpty == false ? paths.last! : "工作区根目录")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if loading { ProgressView("正在读取电脑目录…") }
                        if let error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                            Button("重新读取") { loadID = UUID() }
                        }
                        if let listing {
                            ForEach(listing.entries.sorted { left, right in
                                let leftDirectory = left.type == "directory", rightDirectory = right.type == "directory"
                                return leftDirectory != rightDirectory ? leftDirectory : left.name.localizedStandardCompare(right.name) == .orderedAscending
                            }) { entry in
                                Button {
                                    let path = listing.path.isEmpty ? entry.name : listing.path + "/" + entry.name
                                    if entry.type == "directory" { paths.append(path); loadID = UUID() }
                                    else { selected = DSHFileReference(sessionID: sessionID, path: path) }
                                } label: { fileRow(name: entry.name, type: entry.type, size: entry.size) }
                                    .disabled(entry.type == "other" || loading)
                            }
                            if listing.entries.isEmpty { Text("此目录为空").foregroundStyle(.secondary) }
                            if listing.truncated { Text("电脑限制了本次目录条目数，列表尚未包含所有文件。").font(.caption).foregroundStyle(.secondary) }
                        }
                    } footer: {
                        Text("按当前会话的工作区浏览。文件是否可读由电脑上的 Harness 判断。")
                    }
                } else {
                    Section("对话中的文件") {
                        if outputLinks.isEmpty { Text("当前已加载的记录中没有可读取的文件").foregroundStyle(.secondary) }
                        ForEach(outputLinks) { reference in
                            Button { selected = reference } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(reference.name, systemImage: "doc").foregroundStyle(Color.primary)
                                    Text(reference.path).font(.caption).foregroundStyle(Color.secondary).lineLimit(2).truncationMode(.middle)
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                    Section("已上传的文件") {
                        if model.attachments(for: sessionID).isEmpty { Text("暂无上传记录").foregroundStyle(.secondary) }
                        ForEach(model.attachments(for: sessionID)) { attachment in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(attachment.name, systemImage: "paperclip")
                                Text("上传记录").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("会话文件").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { loadID = UUID() }
            .task(id: loadID) { await load() }
            .sheet(item: $selected) { DSHRemoteFilePreview(reference: $0) }
        }
    }

    private func fileRow(name: String, type: String, size: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: type == "directory" ? "folder" : "doc").frame(width: 24).foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).foregroundStyle(Color.primary).lineLimit(2).truncationMode(.middle)
                if let size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(Color.secondary) }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary)
        }.frame(minHeight: 44)
    }

    @MainActor private func load() async {
        let identity = loadID
        loading = true; listing = nil; error = nil
        do {
            let result = try await model.workspaceFiles(sessionID: sessionID, path: paths.last ?? "")
            guard !Task.isCancelled, identity == loadID else { return }
            listing = result
        } catch is CancellationError { return }
        catch { if identity == loadID { self.error = error.localizedDescription } }
        if identity == loadID { loading = false }
    }
}

struct DSHRemoteFilePreview: View {
    let reference: DSHFileReference
    @EnvironmentObject private var model: DSHAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var received = 0
    @State private var total: Int?
    @State private var failure: String?
    @State private var attempt = UUID()
    @State private var textPreview: String?
    @State private var imagePreview: UIImage?
    @State private var quickLookURL: URL?
    @StateObject private var fileLifetime = DSHPreviewFileLifetime()

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    if let textPreview {
                        ScrollView {
                            if localURL.pathExtension.lowercased() == "md" {
                                MarkdownBlockText(text: textPreview).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(textPreview).font(.body.monospaced()).textSelection(.enabled).lineSpacing(4)
                                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let imagePreview {
                        VStack {
                            Image(uiImage: imagePreview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(reference.name)
                            Button("打开系统预览") { quickLookURL = localURL }.frame(minHeight: 44)
                        }.padding(8)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                            Text(reference.name).multilineTextAlignment(.center).textSelection(.enabled)
                            if QLPreviewController.canPreview(localURL as NSURL) {
                                Button("打开系统预览") { quickLookURL = localURL }.buttonStyle(.borderedProminent)
                            } else { Text("此格式暂不支持预览，可通过分享保存或在其他 App 中打开。").foregroundStyle(.secondary) }
                        }.padding()
                    }
                } else if let failure {
                    VStack(spacing: 16) {
                        Text(failure).textSelection(.enabled)
                        Button("重新下载") { self.failure = nil; attempt = UUID() }.buttonStyle(.borderedProminent)
                    }.padding()
                } else {
                    VStack(spacing: 12) {
                        if let total, total > 0 { ProgressView(value: Double(received), total: Double(total)).frame(maxWidth: 240) }
                        else { ProgressView() }
                        Text(received == 0 ? "正在读取电脑文件…" : "已下载 \(ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file))")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding()
                }
            }
            .navigationTitle(reference.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let localURL { ShareLink(item: localURL) { Label("分享或存储", systemImage: "square.and.arrow.up") } }
                }
            }
            .task(id: attempt) {
                received = 0; total = nil
                do {
                    let url = try await model.downloadFile(reference) { bytes, size in received = bytes; total = size }
                    guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return }
                    let isText = UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true ||
                        ["md", "json", "yaml", "yml", "swift", "js", "ts", "tsx", "py", "sh", "sql", "log"].contains(url.pathExtension.lowercased())
                    if isText, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                       let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.contains("\0") {
                        textPreview = text
                    }
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                       let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2_048
                       ] as CFDictionary) { imagePreview = UIImage(cgImage: cgImage) }
                    fileLifetime.url = url
                    localURL = url
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
            .quickLookPreview($quickLookURL)
        }
    }
}

/// A preview can temporarily disappear behind Quick Look or a share sheet.
/// Keep its file until the owning view is released, rather than deleting a
/// file that a system presentation is still using on every onDisappear.
private final class DSHPreviewFileLifetime: ObservableObject {
    var url: URL?
    deinit {
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
