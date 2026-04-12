//
//  ClaudeUsageSnapshot.swift
//  HermitFlow
//
//  Phase 6 local-first usage model.
//

import Foundation

enum ClaudeUsageSourceKind: String, Codable, Hashable {
    case localCache
    case remoteProvider
}

struct ClaudeUsageWindow: Equatable, Codable, Hashable {
    var usedPercentage: Double
    var resetsAt: Date?

    var roundedUsedPercentage: Int {
        Int((min(max(usedPercentage, 0), 1) * 100).rounded())
    }

    var leftPercentage: Double {
        max(0, 1 - usedPercentage)
    }
}

struct ClaudeUsageSnapshot: Equatable, Codable, Hashable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    var cachedAt: Date?
    var providerID: String?
    var providerDisplayName: String?
    var sourceKind: ClaudeUsageSourceKind?

    static let empty = ClaudeUsageSnapshot(
        fiveHour: nil,
        sevenDay: nil,
        cachedAt: nil,
        providerID: nil,
        providerDisplayName: nil,
        sourceKind: nil
    )

    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }

    // TODO: Remove these compatibility aliases once all usage views read the normalized fields.
    var fiveHourWindow: ClaudeUsageWindow? {
        fiveHour
    }

    var sevenDayWindow: ClaudeUsageWindow? {
        sevenDay
    }
}
