import SwiftUI

struct QuestionOptionButtonsView: View {
    let options: [QuestionOption]
    let selectedOptionID: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Button(action: { onSelect(option.id) }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedOptionID == option.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selectedOptionID == option.id ? Color(red: 0.32, green: 0.96, blue: 0.38) : Color.white.opacity(0.38))
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let detail = option.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(Color.white.opacity(0.66))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedOptionID == option.id ? Color(red: 0.12, green: 0.26, blue: 0.18).opacity(0.96) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selectedOptionID == option.id ? Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.42) : Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
