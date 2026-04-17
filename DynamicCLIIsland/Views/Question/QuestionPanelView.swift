import SwiftUI

struct QuestionPanelView: View {
    let prompt: ClaudeQuestionPrompt
    @ObservedObject var questionStore: QuestionStore
    let timestampText: String
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        QuestionPromptCardView(
            prompt: prompt,
            questionStore: questionStore,
            timestampText: timestampText,
            onSubmit: onSubmit,
            onDismiss: onDismiss,
            pinsActions: true
        )
    }
}
