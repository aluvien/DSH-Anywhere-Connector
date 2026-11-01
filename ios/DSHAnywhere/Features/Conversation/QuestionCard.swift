import SwiftUI

struct DSHQuestionDraft: Codable, Equatable {
    let questions: [DSHQuestion]
    var selections: [String: Set<String>]
    var custom: [String: String]
    var skipped: Set<String>
}

/// Renders an `ask_user_question` request so it can actually be answered from
/// the phone. The model's tool call stays parked on the Mac until every
/// question in the request has an answer, so the card submits one complete
/// payload rather than a partial one.
struct QuestionCard: View {
    let request: DSHQuestionRequest
    var savedDraft: DSHQuestionDraft? = nil
    var onDraftChange: ((DSHQuestionDraft) -> Void)? = nil
    var onCancel: (() async throws -> Void)? = nil
    let onAnswer: ([DSHQuestionAnswer]) async throws -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var skipped: Set<String> = []
    @State private var isSubmitting = false
    @State private var showPlan = false
    @State private var cancellationError: String?
    @State private var restoredDraft = false
    @State private var expired = false

    private var planReview: DSHQuestion? {
        guard request.questions.count == 1, let question = request.questions.first,
              question.intent?.kind == "plan-review", question.multiSelect != true,
              let detail = question.detail, !detail.isEmpty,
              let options = question.options, options.count == 2,
              options.contains(where: { $0.label == question.intent?.approve }) else { return nil }
        return question
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "questionmark.bubble.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)

            if planReview != nil {
                Button("全屏阅读计划") { showPlan = true }
                    .buttonStyle(.bordered)
            }

            ForEach(request.questions) { question in
                questionBody(question)
            }
            .disabled(isSubmitting || expired)
            if expired { Text("问题已过期，请等待电脑同步最新状态。 ").font(.caption).foregroundStyle(.secondary) }

            HStack {
                if let onCancel {
                    Button(planReview == nil ? "取消提问" : "继续讨论") {
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        cancellationError = nil
                        Task { @MainActor in
                            defer { isSubmitting = false }
                            do { try await onCancel() }
                            catch { cancellationError = error.localizedDescription }
                        }
                    }
                    .disabled(isSubmitting || expired)
                }
                Spacer()
                Button("Send answer") { submitCompleteAnswers() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || expired || !isComplete)
            }
            if let cancellationError {
                Text(cancellationError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !restoredDraft else { return }
            restoredDraft = true
            if let savedDraft, savedDraft.questions == request.questions {
                selections = savedDraft.selections
                custom = savedDraft.custom
                skipped = savedDraft.skipped
            }
        }
        .onChange(of: selections) { _, _ in persistDraft() }
        .onChange(of: custom) { _, _ in persistDraft() }
        .onChange(of: skipped) { _, _ in persistDraft() }
        .task(id: request.expiresAt) {
            guard let expiresAt = request.expiresAt else { return }
            let delay = Double(expiresAt) / 1_000 - Date().timeIntervalSince1970
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            expired = true
        }
        .sheet(isPresented: $showPlan) {
            NavigationStack {
                ScrollView {
                    MarkdownBlockText(text: planReview?.detail ?? "")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("计划审阅")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showPlan = false }
                    }
                }
            }
        }
    }

    private var title: String {
        if request.questions.count == 1, let header = request.questions[0].header, !header.isEmpty {
            return header
        }
        return request.questions.count == 1 ? "Question" : "\(request.questions.count) questions"
    }

    @ViewBuilder
    private func questionBody(_ question: DSHQuestion) -> some View {
        let options = question.options ?? []
        let isMulti = question.multiSelect == true
        VStack(alignment: .leading, spacing: 10) {
            if request.questions.count > 1, let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let detail = question.detail, !detail.isEmpty {
                ScrollView {
                    MarkdownBlockText(text: detail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        optionButton(question, option, isMulti: isMulti)
                    }
                }
            }

            TextField(options.isEmpty ? "Type your answer" : "Other answer",
                      text: customBinding(question.id, isMulti: isMulti))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { submitCompleteAnswers() }
            if planReview == nil {
              Button(skipped.contains(question.id) ? "取消跳过" : "跳过此问题") {
                if skipped.contains(question.id) {
                    skipped.remove(question.id)
                } else {
                    selections[question.id] = []
                    custom[question.id] = ""
                    skipped.insert(question.id)
                }
            }
            .font(.caption)
            .disabled(isSubmitting)
            }
        }
    }

    private func optionButton(_ question: DSHQuestion, _ option: DSHQuestionOption,
                              isMulti: Bool) -> some View {
        let isSelected = selections[question.id]?.contains(option.label) == true
        return Button {
            guard !isSubmitting else { return }
            skipped.remove(question.id)
            if isMulti {
                var current = selections[question.id] ?? []
                if current.contains(option.label) { current.remove(option.label) }
                else { current.insert(option.label) }
                selections[question.id] = current
            } else {
                // Single-select: a tap is the whole answer, so submit as soon as
                // the request has no other outstanding question.
                selections[question.id] = [option.label]
                custom[question.id] = ""
                submitCompleteAnswers()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(isSelected: isSelected, isMulti: isMulti))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(planReview?.id == question.id
                         ? (option.label == question.intent?.approve ? "批准计划并执行" : option.label)
                         : option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func symbol(isSelected: Bool, isMulti: Bool) -> String {
        if isMulti { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func customBinding(_ questionID: String, isMulti: Bool) -> Binding<String> {
        Binding(
            get: { custom[questionID] ?? "" },
            set: {
                custom[questionID] = $0
                if !$0.isEmpty {
                    skipped.remove(questionID)
                    if !isMulti { selections[questionID] = [] }
                }
            }
        )
    }

    private func hasAnswer(_ question: DSHQuestion) -> Bool {
        if skipped.contains(question.id) { return true }
        if selections[question.id]?.isEmpty == false { return true }
        return !(custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isComplete: Bool {
        request.questions.allSatisfy(hasAnswer)
    }

    private func submitCompleteAnswers() {
        guard !isSubmitting, !expired, isComplete else { return }
        isSubmitting = true
        cancellationError = nil
        persistDraft()
        let answers = request.questions.map { question in
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DSHQuestionAnswer(
                id: question.id,
                selected: Array(selections[question.id] ?? []).sorted(),
                custom: text.isEmpty ? nil : text
            )
        }
        Task { @MainActor in
            defer { isSubmitting = false }
            do { try await onAnswer(answers) }
            catch { cancellationError = error.localizedDescription }
        }
    }

    private func persistDraft() {
        onDraftChange?(DSHQuestionDraft(questions: request.questions, selections: selections, custom: custom, skipped: skipped))
    }
}

struct QuestionCard_Previews: PreviewProvider {
    static var previews: some View {
        QuestionCard(
            request: DSHQuestionRequest(
                id: "question",
                sessionId: "session",
                questions: [
                    DSHQuestion(id: "mode", question: "Which mode should I use?",
                                header: "Choose Mode",
                                options: [
                                    DSHQuestionOption(label: "Fast", description: "Fewer checks"),
                                    DSHQuestionOption(label: "Careful", description: "Verify each step"),
                                ]),
                    DSHQuestion(id: "extra", question: "Anything else to include?"),
                ]
            ),
            onAnswer: { _ in }
        )
        .padding()
    }
}
