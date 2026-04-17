import Foundation

final class ClaudeQuestionBridge {
    private let rootURL: URL
    private let latestPromptURL: URL

    init(rootURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-questions")) {
        self.rootURL = rootURL
        latestPromptURL = rootURL.appendingPathComponent("latest-question.json")
    }

    func write(prompt: ClaudeQuestionPrompt) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(prompt) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: latestPromptURL, options: .atomic)
        } catch {
            return
        }
    }

    func fetchLatestPrompt() -> ClaudeQuestionPrompt? {
        guard let data = try? Data(contentsOf: latestPromptURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let prompt = try? decoder.decode(ClaudeQuestionPrompt.self, from: data)
        if prompt?.isExpired == true {
            clear()
            return nil
        }
        return prompt
    }

    func markResolved(id: String) {
        guard let prompt = fetchLatestPrompt(), prompt.id == id else {
            return
        }

        clear()
    }

    func clear() {
        try? FileManager.default.removeItem(at: latestPromptURL)
    }
}
