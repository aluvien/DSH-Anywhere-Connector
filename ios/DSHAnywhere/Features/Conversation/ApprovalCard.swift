import SwiftUI

struct ApprovalCard: View {
    let approval: DSHApprovalRequest
    let onDecision: (Bool) -> Void

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
                Button("Reject", role: .destructive) { onDecision(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Allow once") { onDecision(true) }
                    .buttonStyle(.borderedProminent)
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
