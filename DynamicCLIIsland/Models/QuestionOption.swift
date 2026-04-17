import Foundation

struct QuestionOption: Equatable, Codable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var value: String
    var isDefault: Bool
}
