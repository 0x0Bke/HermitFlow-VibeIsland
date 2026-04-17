import Foundation

final class ClaudeQuestionSource {
    private let localClaudeSource: LocalClaudeSource
    private let bridge: ClaudeQuestionBridge

    init(
        localClaudeSource: LocalClaudeSource = LocalClaudeSource(),
        bridge: ClaudeQuestionBridge = ClaudeQuestionBridge()
    ) {
        self.localClaudeSource = localClaudeSource
        self.bridge = bridge
    }

    func fetchLatestQuestionPrompt() -> ClaudeQuestionPrompt? {
        if let prompt = localClaudeSource.fetchLatestQuestionPrompt() {
            bridge.write(prompt: prompt)
            return prompt
        }

        return bridge.fetchLatestPrompt()
    }

    func resolveQuestion(id: String, response: ClaudeQuestionResponse) -> Bool {
        let resolved = localClaudeSource.resolveQuestion(id: id, response: response)
        if resolved {
            bridge.markResolved(id: id)
        }
        return resolved
    }

    func dismissQuestion(id: String) -> Bool {
        let dismissed = localClaudeSource.dismissQuestion(id: id)
        if dismissed {
            bridge.markResolved(id: id)
        }
        return dismissed
    }

    func isPromptSubmittable(id: String) -> Bool {
        localClaudeSource.isQuestionSubmittable(id: id)
    }
}
