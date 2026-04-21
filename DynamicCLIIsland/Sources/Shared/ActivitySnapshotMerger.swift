//
//  ActivitySnapshotMerger.swift
//  HermitFlow
//
//  Phase 4 shared source helpers.
//

import Foundation

enum ActivitySnapshotMerger {
    static func merge(_ lhs: ActivitySourceSnapshot, _ rhs: ActivitySourceSnapshot) -> ActivitySourceSnapshot {
        let sessions = (lhs.sessions + rhs.sessions).sorted { left, right in
            if left.activityState != right.activityState {
                return priority(for: left.activityState) > priority(for: right.activityState)
            }
            return left.updatedAt > right.updatedAt
        }

        let statusMessage: String
        if !lhs.sessions.isEmpty, !rhs.sessions.isEmpty {
            let originNames = orderedOriginNames(for: lhs.sessions + rhs.sessions)
            statusMessage = "Watching \(originNames.joined(separator: " + ")) activity"
        } else if !lhs.sessions.isEmpty {
            statusMessage = lhs.statusMessage
        } else if !rhs.sessions.isEmpty {
            statusMessage = rhs.statusMessage
        } else {
            statusMessage = "Waiting for Codex / Claude activity"
        }

        let lastUpdatedAt = max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
        let approvalRequest = ApprovalRequestMerger.merge(lhs.approvalRequest, rhs.approvalRequest)
        let errorMessage = [lhs.errorMessage, rhs.errorMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return ActivitySourceSnapshot(
            sessions: sessions,
            statusMessage: statusMessage,
            lastUpdatedAt: lastUpdatedAt,
            errorMessage: errorMessage.isEmpty ? nil : errorMessage,
            approvalRequest: approvalRequest,
            usageSnapshots: mergeUsageSnapshots(lhs.usageSnapshots, rhs.usageSnapshots)
        )
    }

    private static func mergeUsageSnapshots(
        _ lhs: [ProviderUsageSnapshot],
        _ rhs: [ProviderUsageSnapshot]
    ) -> [ProviderUsageSnapshot] {
        let merged = lhs + rhs
        var bestByOrigin: [SessionOrigin: ProviderUsageSnapshot] = [:]

        for snapshot in merged {
            if let existing = bestByOrigin[snapshot.origin], existing.updatedAt >= snapshot.updatedAt {
                continue
            }
            bestByOrigin[snapshot.origin] = snapshot
        }

        return bestByOrigin.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func priority(for state: IslandCodexActivityState) -> Int {
        switch state {
        case .failure:
            return 3
        case .running:
            return 2
        case .success:
            return 1
        case .idle:
            return 0
        }
    }

    private static func orderedOriginNames(for sessions: [AgentSessionSnapshot]) -> [String] {
        let order: [SessionOrigin] = [.codex, .claude, .openCode, .generic]
        let presentOrigins = Set(sessions.map(\.origin))
        return order
            .filter { presentOrigins.contains($0) }
            .map(displayName(for:))
    }

    private static func displayName(for origin: SessionOrigin) -> String {
        switch origin {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .openCode:
            return "OpenCode"
        case .generic:
            return "CLI"
        }
    }
}
