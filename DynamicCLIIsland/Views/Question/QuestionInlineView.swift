import SwiftUI

struct QuestionInlineView: View {
    @ObservedObject var store: ProgressStore
    let prompt: ClaudeQuestionPrompt
    let header: AnyView
    let timestampText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                headerRow
                    .padding(.horizontal, 36)
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(chromeBackground)
            .zIndex(1)

            QuestionPromptCardView(
                prompt: prompt,
                questionStore: store.questionInputStore,
                timestampText: timestampText,
                onSubmit: store.submitQuestionAnswer,
                onDismiss: store.dismissQuestionPrompt,
                pinsActions: true,
                fillsAvailableHeight: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chromeBackground)
    }

    private var focusTarget: FocusTarget? {
        store.sessions.first(where: {
            $0.id == prompt.sessionID || $0.focusTarget?.sessionID == prompt.sessionID
        })?.focusTarget
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.99, green: 0.80, blue: 0.46))

            Text("Claude Needs Input")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            if !store.questionInputStore.supportsSubmission {
                Text("Mirror Only")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            Spacer(minLength: 8)

            if let focusTarget = focusTarget {
                Button(action: { store.bringForward(focusTarget) }) {
                    Text("Open")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.74))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chromeBackground: some View {
        Color(red: 0.09, green: 0.09, blue: 0.08)
    }
}
