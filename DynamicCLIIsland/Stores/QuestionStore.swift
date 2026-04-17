import Foundation
import SwiftUI

@MainActor
final class QuestionStore: ObservableObject {
    @Published private(set) var currentPrompt: ClaudeQuestionPrompt?
    @Published private(set) var selectedOptionID: String?
    @Published var textAnswer: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var supportsSubmission = true

    func update(with prompt: ClaudeQuestionPrompt?, supportsSubmission: Bool = true) {
        let previousPromptID = currentPrompt?.id
        currentPrompt = prompt
        errorMessage = nil
        isSubmitting = false
        self.supportsSubmission = supportsSubmission

        guard let prompt else {
            selectedOptionID = nil
            textAnswer = ""
            return
        }

        if previousPromptID != prompt.id {
            selectedOptionID = nil
            textAnswer = ""
        }

        if selectedOptionID == nil {
            selectedOptionID = prompt.options.first(where: \.isDefault)?.id
        }

        if textAnswer.isEmpty, let defaultText = prompt.defaultText, !defaultText.isEmpty {
            textAnswer = defaultText
        }
    }

    func clear() {
        currentPrompt = nil
        selectedOptionID = nil
        textAnswer = ""
        errorMessage = nil
        isSubmitting = false
        supportsSubmission = true
    }

    func selectOption(id: String) {
        guard currentPrompt?.options.contains(where: { $0.id == id }) == true else {
            return
        }

        selectedOptionID = id
        errorMessage = nil
    }

    func setTextAnswer(_ text: String) {
        textAnswer = text
        errorMessage = nil
    }

    func makeResponse() -> ClaudeQuestionResponse? {
        guard let prompt = currentPrompt, !prompt.isExpired else {
            errorMessage = "Question prompt expired"
            return nil
        }

        guard supportsSubmission else {
            errorMessage = "Answer this question in Claude to continue"
            return nil
        }

        let trimmedText = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedOption = prompt.options.first(where: { $0.id == selectedOptionID })

        let needsOption = prompt.hasOptions && !prompt.allowsFreeText
        let needsText = prompt.requiresTextInput
        let hasAnswerText = !trimmedText.isEmpty

        guard (!needsOption || selectedOption != nil), (!needsText || hasAnswerText), (selectedOption != nil || hasAnswerText) else {
            errorMessage = "Select an option or enter an answer to continue"
            return nil
        }

        let summaryParts: [String] = [selectedOption?.title, hasAnswerText ? trimmedText : nil]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        let summary = summaryParts.isEmpty ? "Question answered" : summaryParts.joined(separator: " · ")
        errorMessage = nil

        return ClaudeQuestionResponse(
            selectedOptionID: selectedOption?.id,
            selectedOptionValue: selectedOption?.value,
            textAnswer: hasAnswerText ? trimmedText : nil,
            displaySummary: summary
        )
    }

    func canSubmit() -> Bool {
        guard let prompt = currentPrompt, !prompt.isExpired else {
            return false
        }

        guard supportsSubmission else {
            return false
        }

        let hasOption = prompt.options.contains(where: { $0.id == selectedOptionID })
        let hasText = !textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if prompt.requiresTextInput {
            return hasText
        }

        if prompt.hasOptions && !prompt.allowsFreeText {
            return hasOption
        }

        return hasOption || hasText
    }

    func setSubmitting(_ submitting: Bool) {
        isSubmitting = submitting
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
    }
}
