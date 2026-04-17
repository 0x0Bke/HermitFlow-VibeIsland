import SwiftUI

struct QuestionPromptCardView: View {
    let prompt: ClaudeQuestionPrompt
    @ObservedObject var questionStore: QuestionStore
    let timestampText: String
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    var pinsActions = false
    var fillsAvailableHeight = false

    var body: some View {
        Group {
            if pinsActions {
                pinnedLayout
            } else {
                regularLayout
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsAvailableHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            contentSections
            actionBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinnedLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                contentSections
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                actionBar
                    .padding(16)
                    .background(footerBackground)
            }
        }
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.99, green: 0.80, blue: 0.46))

                        Text("Claude Needs Input")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(prompt.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(timestampText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.48))
            }

            if let message = prompt.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = prompt.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prompt.hasOptions {
                QuestionOptionButtonsView(
                    options: prompt.options,
                    selectedOptionID: questionStore.selectedOptionID,
                    onSelect: questionStore.selectOption(id:)
                )
            }

            if prompt.allowsFreeText {
                QuestionTextInputView(prompt: prompt, questionStore: questionStore)
            }

            if let errorMessage = questionStore.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !questionStore.supportsSubmission {
                Text("Answer in Claude CLI or the Claude extension. HermitFlow is mirroring this prompt only.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: onDismiss) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onSubmit) {
                HStack(spacing: 6) {
                    if questionStore.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(questionStore.supportsSubmission ? "Send Answer" : "Answer In Claude")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(questionStore.canSubmit() ? Color(red: 0.13, green: 0.77, blue: 0.37) : Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!questionStore.canSubmit() || questionStore.isSubmitting)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.19, green: 0.16, blue: 0.09),
                        Color(red: 0.09, green: 0.09, blue: 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color(red: 0.99, green: 0.80, blue: 0.46).opacity(0.26), lineWidth: 1)
    }

    private var footerBackground: some View {
        Color(red: 0.09, green: 0.09, blue: 0.08)
    }
}
