//
//  UsageProviderState.swift
//  HermitFlow
//
//  Phase 6 local-first usage model.
//

import Foundation

struct UsageProviderState: Equatable, Hashable {
    var claude: ClaudeUsageSnapshot?
    var codex: CodexUsageSnapshot?

    static let empty = UsageProviderState(claude: nil, codex: nil)

    var hasAnyUsage: Bool {
        hasClaudeUsage || hasCodexUsage
    }

    var hasClaudeUsage: Bool {
        guard let claude else { return false }
        return !claude.isEmpty
    }

    var hasCodexUsage: Bool {
        guard let codex else { return false }
        return !codex.isEmpty
    }

    var usageCardCount: Int {
        (hasClaudeUsage ? 1 : 0) + (hasCodexUsage ? 1 : 0)
    }

    var legacySnapshots: [ProviderUsageSnapshot] {
        var snapshots: [ProviderUsageSnapshot] = []

        if let claude, !claude.isEmpty {
            snapshots.append(
                ProviderUsageSnapshot(
                    origin: .claude,
                    shortWindowRemaining: claude.fiveHour?.leftPercentage ?? 0,
                    longWindowRemaining: claude.sevenDay?.leftPercentage ?? 0,
                    updatedAt: claude.cachedAt ?? .distantPast
                )
            )
        }

        if let codex, !codex.isEmpty {
            let sortedWindows = codex.windows.sorted { $0.windowMinutes < $1.windowMinutes }
            snapshots.append(
                ProviderUsageSnapshot(
                    origin: .codex,
                    shortWindowRemaining: sortedWindows.first?.leftPercentage ?? 0,
                    longWindowRemaining: sortedWindows.last?.leftPercentage ?? 0,
                    updatedAt: codex.capturedAt ?? .distantPast
                )
            )
        }

        return snapshots
    }
}
