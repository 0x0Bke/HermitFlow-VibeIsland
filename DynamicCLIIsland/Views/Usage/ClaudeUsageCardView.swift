//
//  ClaudeUsageCardView.swift
//  HermitFlow
//
//  Phase 6 local-first usage view.
//

import SwiftUI

struct ClaudeUsageCardView: View {
    let snapshot: ClaudeUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 12) {
                if let fiveHour = snapshot.fiveHour {
                    metricCard(title: "5h", window: fiveHour, subtitle: "5 hour window")
                }

                if let sevenDay = snapshot.sevenDay {
                    metricCard(title: "7d", window: sevenDay, subtitle: "7 day window")
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
                            Color(red: 0.15, green: 0.18, blue: 0.25).opacity(0.96),
                            Color(red: 0.09, green: 0.12, blue: 0.19).opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.28, green: 0.52, blue: 0.92).opacity(0.24), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            if let updatedText = UsageSummaryFormatter.updatedText(snapshot.cachedAt) {
                Text("Updated \(updatedText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private var headerTitle: String {
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            return "Claude Code · \(providerDisplayName)"
        }

        return "Claude Code"
    }

    private func metricCard(title: String, window: ClaudeUsageWindow, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.48, green: 0.84, blue: 0.99))

            Text("\(window.roundedUsedPercentage)%")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))

            if let resetText = UsageSummaryFormatter.resetText(window.resetsAt) {
                Text("Resets \(resetText)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}
