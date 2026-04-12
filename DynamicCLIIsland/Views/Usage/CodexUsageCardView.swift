//
//  CodexUsageCardView.swift
//  HermitFlow
//
//  Phase 6 local-first usage view.
//

import SwiftUI

struct CodexUsageCardView: View {
    let snapshot: CodexUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.windows) { window in
                    windowRow(window)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.17, blue: 0.23).opacity(0.96),
                            Color(red: 0.08, green: 0.11, blue: 0.16).opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.02, green: 0.71, blue: 0.83).opacity(0.24), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Codex")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            if let planType = snapshot.planType, !planType.isEmpty {
                Text(planType)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 0.02, green: 0.71, blue: 0.83))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.02, green: 0.71, blue: 0.83).opacity(0.14))
                    )
            }

            Spacer(minLength: 8)

            if let updatedText = UsageSummaryFormatter.updatedText(snapshot.capturedAt) {
                Text("Updated \(updatedText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private func windowRow(_ window: CodexUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(window.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.02, green: 0.71, blue: 0.83))
                    .frame(width: 28, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))

                        Capsule(style: .continuous)
                            .fill(Color(red: 0.02, green: 0.71, blue: 0.83))
                            .frame(width: max(proxy.size.width * window.usedPercentage, window.usedPercentage > 0 ? 4 : 0))
                    }
                }
                .frame(height: 5)

                Text("\(window.roundedUsedPercentage)%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("\(window.windowMinutes)m")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))

                if let resetText = UsageSummaryFormatter.resetText(window.resetsAt) {
                    Text("Resets \(resetText)")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.54))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}
