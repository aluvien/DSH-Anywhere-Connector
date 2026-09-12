import SwiftUI

/// Renders an `ask_user_question` request so it can actually be answered from
/// the phone. The model's tool call stays parked on the Mac until every
/// question in the request has an answer, so the card submits one complete
/// payload rather than a partial one.
struct QuestionCard: View {
    let request: DSHQuestionRequest
    let onAnswer: ([DSHQuestionAnswer]) -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "questionmark.bubble.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)

            ForEach(request.questions) { question in
                questionBody(question)
            }

            HStack {
                Spacer()
                Button("Send answer") { submitCompleteAnswers() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || !isComplete)
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
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            HStack(spacing: 8) {
                TextField(options.isEmpty ? "Type your answer" : "Other answer",
                          text: customBinding(question.id))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { submitCompleteAnswers() }
                if isMulti || options.isEmpty {
                    Button("Send") { submitCompleteAnswers() }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting || !hasAnswer(question))
                }
            }
        }
    }

    private func optionButton(_ question: DSHQuestion, _ option: DSHQuestionOption,
                              isMulti: Bool) -> some View {
        let isSelected = selections[question.id]?.contains(option.label) == true
        return Button {
            guard !isSubmitting else { return }
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
                    Text(option.label)
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

    private func customBinding(_ questionID: String) -> Binding<String> {
        Binding(
            get: { custom[questionID] ?? "" },
            set: { custom[questionID] = $0 }
        )
    }

    private func hasAnswer(_ question: DSHQuestion) -> Bool {
        if selections[question.id]?.isEmpty == false { return true }
        return !(custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isComplete: Bool {
        request.questions.allSatisfy(hasAnswer)
    }

    private func submitCompleteAnswers() {
        guard !isSubmitting, isComplete else { return }
        isSubmitting = true
        onAnswer(request.questions.map { question in
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DSHQuestionAnswer(
                id: question.id,
                selected: Array(selections[question.id] ?? []).sorted(),
                custom: text.isEmpty ? nil : text
            )
        })
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
