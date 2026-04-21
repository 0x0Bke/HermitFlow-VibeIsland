//
//  OpenCodeUsageCardView.swift
//  HermitFlow
//
//  Local-first OpenCode usage view.
//

import SwiftUI

struct OpenCodeUsageCardView: View {
    let snapshot: OpenCodeUsageSnapshot
    let displayType: UsageDisplayType

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 12) {
                ForEach(snapshot.displayWindows, id: \.id) { item in
                    metricCard(title: item.label, window: item.window, subtitle: subtitle(for: item))
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
                            Color(red: 0.13, green: 0.17, blue: 0.22).opacity(0.96),
                            Color(red: 0.08, green: 0.11, blue: 0.16).opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.41, green: 0.82, blue: 0.58).opacity(0.24), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            if let updatedText = UsageSummaryFormatter.updatedText(snapshot.capturedAt) {
                Text("Updated \(updatedText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private var headerTitle: String {
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            return "OpenCode · \(providerDisplayName)"
        }

        return "OpenCode"
    }

    private func subtitle(for item: OpenCodeLabeledUsageWindow) -> String {
        "\(item.label) \(displayType.englishSubtitleSuffix)"
    }

    private func metricCard(title: String, window: OpenCodeUsageWindow, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.41, green: 0.82, blue: 0.58))

            Text(displayType.percentageText(used: window.roundedUsedPercentage, remaining: window.roundedLeftPercentage))
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
