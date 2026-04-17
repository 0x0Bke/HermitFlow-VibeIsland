import Foundation

struct ClaudeQuestionResponse: Equatable, Codable {
    var selectedOptionID: String?
    var selectedOptionValue: String?
    var textAnswer: String?
    var displaySummary: String

    var isEmpty: Bool {
        let optionEmpty = selectedOptionID?.isEmpty != false && selectedOptionValue?.isEmpty != false
        let textEmpty = textAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        return optionEmpty && textEmpty
    }
}
