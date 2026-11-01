import SwiftUI

struct ApprovalCard: View {
    let approval: DSHApprovalRequest
    var savedDecision: Bool? = nil
    let onDecision: (Bool) async throws -> Void
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @State private var attemptedDecision: Bool?
    @State private var expired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permission required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(approval.toolName)
                .font(.subheadline.weight(.semibold))
            Text(approval.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Reject", role: .destructive) { submit(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Allow once") { submit(true) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isSubmitting || expired)
            if isSubmitting { ProgressView("正在提交决定") }
            if expired { Text("审批已过期，请等待电脑同步最新状态。").font(.caption).foregroundStyle(.secondary) }
            if let submissionError {
                Text(submissionError).font(.caption).foregroundStyle(.red)
            }
            if let attemptedDecision, !expired, !isSubmitting {
                Text(attemptedDecision ? "上次选择：允许一次，结果待确认。" : "上次选择：拒绝，结果待确认。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(attemptedDecision ? "重试允许一次" : "重试拒绝") { submit(attemptedDecision) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .onAppear { if attemptedDecision == nil { attemptedDecision = savedDecision } }
        .task(id: approval.expiresAt) {
            guard let expiresAt = approval.expiresAt else { return }
            let delay = Double(expiresAt) / 1_000 - Date().timeIntervalSince1970
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            expired = true
        }
    }
    private func submit(_ allow: Bool) {
        guard !isSubmitting, !expired else { return }
        attemptedDecision = allow
        submissionError = nil
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do { try await onDecision(allow) }
            catch { submissionError = error.localizedDescription }
        }
    }
}

struct ApprovalCard_Previews: PreviewProvider {
    static var previews: some View {
        ApprovalCard(approval: DSHApprovalRequest(id: "approval", sessionId: "session",
                                                  toolName: "shell", reason: "Run the requested command?"),
                     onDecision: { _ in })
            .padding()
    }
}
