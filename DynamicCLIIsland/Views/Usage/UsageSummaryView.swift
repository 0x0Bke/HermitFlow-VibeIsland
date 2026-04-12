//
//  UsageSummaryView.swift
//  HermitFlow
//
//  Phase 6 local-first usage view.
//

import SwiftUI

struct UsageSummaryView: View {
    let claudeUsageSnapshot: ClaudeUsageSnapshot?
    let codexUsageSnapshot: CodexUsageSnapshot?

    var body: some View {
        if claudeUsageSnapshot != nil || codexUsageSnapshot != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Usage")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))

                    Spacer(minLength: 8)

                    Text(sourceLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }

                if let claudeUsageSnapshot, !claudeUsageSnapshot.isEmpty {
                    ClaudeUsageCardView(snapshot: claudeUsageSnapshot)
                }

                if let codexUsageSnapshot, !codexUsageSnapshot.isEmpty {
                    CodexUsageCardView(snapshot: codexUsageSnapshot)
                }
            }
        }
    }

    private var sourceLabel: String {
        if claudeUsageSnapshot?.sourceKind == .remoteProvider {
            return "Hybrid"
        }

        return "Local"
    }
}
