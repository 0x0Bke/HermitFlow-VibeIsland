import SwiftUI

struct QuestionTextInputView: View {
    let prompt: ClaudeQuestionPrompt
    @ObservedObject var questionStore: QuestionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentGreen)

                Text("Your Answer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.10, blue: 0.10))

                if questionStore.textAnswer.isEmpty, let placeholder = prompt.placeholder, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { questionStore.textAnswer },
                    set: { questionStore.setTextAnswer($0) }
                ))
                .hiddenScrollContentBackgroundIfAvailable()
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .frame(minHeight: 74)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(accentGreen.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private var accentGreen: Color {
        Color(red: 0.42, green: 0.90, blue: 0.68)
    }
}

private extension View {
    @ViewBuilder
    func hiddenScrollContentBackgroundIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
