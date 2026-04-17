import Foundation

struct ClaudeQuestionPrompt: Equatable, Codable, Identifiable {
    var id: String
    var sessionID: String
    var title: String
    var message: String?
    var detail: String?
    var options: [QuestionOption]
    var allowsFreeText: Bool
    var placeholder: String?
    var defaultText: String?
    var createdAt: Date
    var expiresAt: Date?
    var source: SessionOrigin?

    var hasOptions: Bool {
        !options.isEmpty
    }

    var requiresTextInput: Bool {
        guard allowsFreeText else {
            return false
        }

        return options.isEmpty
    }

    var isExpired: Bool {
        guard let expiresAt else {
            return false
        }

        return Date() >= expiresAt
    }
}
