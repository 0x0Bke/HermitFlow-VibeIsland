import SwiftUI

struct QuestionTextInputView: View {
    let prompt: ClaudeQuestionPrompt
    @ObservedObject var questionStore: QuestionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Answer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.56))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.32))

                if questionStore.textAnswer.isEmpty, let placeholder = prompt.placeholder, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { questionStore.textAnswer },
                    set: { questionStore.setTextAnswer($0) }
                ))
                .scrollContentBackground(.hidden)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .frame(minHeight: 86)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}
