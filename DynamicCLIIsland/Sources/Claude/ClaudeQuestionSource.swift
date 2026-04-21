import Foundation

final class ClaudeQuestionSource {
    private let localClaudeSource: LocalClaudeSource
    private let openCodeBridge: OpenCodeHookBridge
    private let bridge: ClaudeQuestionBridge

    init(
        localClaudeSource: LocalClaudeSource = LocalClaudeSource(),
        openCodeBridge: OpenCodeHookBridge = .shared,
        bridge: ClaudeQuestionBridge = ClaudeQuestionBridge()
    ) {
        self.localClaudeSource = localClaudeSource
        self.openCodeBridge = openCodeBridge
        self.bridge = bridge
    }

    func fetchLatestQuestionPrompt() -> ClaudeQuestionPrompt? {
        let claudePrompt = localClaudeSource.fetchLatestQuestionPrompt()
        let openCodePrompt = openCodeBridge.latestQuestionPrompt()

        if let prompt = claudePrompt {
            bridge.write(prompt: prompt)
        }

        let bridgedClaudePrompt = claudePrompt == nil ? bridge.fetchLatestPrompt() : nil
        return [claudePrompt, openCodePrompt, bridgedClaudePrompt]
            .compactMap { $0 }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func resolveQuestion(id: String, response: ClaudeQuestionResponse) -> Bool {
        let resolved: Bool
        if id.hasPrefix("opencode-question:") {
            resolved = openCodeBridge.resolveQuestion(id: id, response: response)
        } else {
            resolved = localClaudeSource.resolveQuestion(id: id, response: response)
                || openCodeBridge.resolveQuestion(id: id, response: response)
        }

        if resolved, !id.hasPrefix("opencode-question:") {
            bridge.markResolved(id: id)
        }
        return resolved
    }

    func dismissQuestion(id: String) -> Bool {
        let dismissed: Bool
        if id.hasPrefix("opencode-question:") {
            dismissed = openCodeBridge.dismissQuestion(id: id)
        } else {
            dismissed = localClaudeSource.dismissQuestion(id: id)
                || openCodeBridge.dismissQuestion(id: id)
        }

        if dismissed, !id.hasPrefix("opencode-question:") {
            bridge.markResolved(id: id)
        }
        return dismissed
    }

    func isPromptSubmittable(id: String) -> Bool {
        if id.hasPrefix("opencode-question:") {
            return openCodeBridge.isQuestionSubmittable(id: id)
        }
        return localClaudeSource.isQuestionSubmittable(id: id)
            || openCodeBridge.isQuestionSubmittable(id: id)
    }
}
