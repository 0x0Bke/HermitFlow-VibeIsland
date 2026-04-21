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
    let openCodeUsageSnapshot: OpenCodeUsageSnapshot?
    let displayType: UsageDisplayType

    init(
        claudeUsageSnapshot: ClaudeUsageSnapshot?,
        codexUsageSnapshot: CodexUsageSnapshot?,
        openCodeUsageSnapshot: OpenCodeUsageSnapshot? = nil,
        displayType: UsageDisplayType
    ) {
        self.claudeUsageSnapshot = claudeUsageSnapshot
        self.codexUsageSnapshot = codexUsageSnapshot
        self.openCodeUsageSnapshot = openCodeUsageSnapshot
        self.displayType = displayType
    }

    var body: some View {
        if claudeUsageSnapshot != nil || codexUsageSnapshot != nil || openCodeUsageSnapshot != nil {
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
                    ClaudeUsageCardView(snapshot: claudeUsageSnapshot, displayType: displayType)
                }

                if let codexUsageSnapshot, !codexUsageSnapshot.isEmpty {
                    CodexUsageCardView(snapshot: codexUsageSnapshot, displayType: displayType)
                }

                if let openCodeUsageSnapshot, !openCodeUsageSnapshot.isEmpty {
                    OpenCodeUsageCardView(snapshot: openCodeUsageSnapshot, displayType: displayType)
                }
            }
        }
    }

    private var sourceLabel: String {
        if claudeUsageSnapshot?.sourceKind == .remoteProvider
            || openCodeUsageSnapshot?.sourceKind == .remoteProvider {
            return "Hybrid"
        }

        return "Local"
    }
}
