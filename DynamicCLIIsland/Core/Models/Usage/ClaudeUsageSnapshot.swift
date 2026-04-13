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

struct ClaudeLabeledUsageWindow: Equatable, Codable, Hashable {
    var id: String
    var label: String
    var window: ClaudeUsageWindow
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
    var customWindows: [ClaudeLabeledUsageWindow] = []
    var cachedAt: Date?
    var providerID: String?
    var providerDisplayName: String?
    var sourceKind: ClaudeUsageSourceKind?

    enum CodingKeys: String, CodingKey {
        case fiveHour
        case sevenDay
        case customWindows
        case cachedAt
        case providerID
        case providerDisplayName
        case sourceKind
    }

    init(
        fiveHour: ClaudeUsageWindow?,
        sevenDay: ClaudeUsageWindow?,
        customWindows: [ClaudeLabeledUsageWindow] = [],
        cachedAt: Date?,
        providerID: String?,
        providerDisplayName: String?,
        sourceKind: ClaudeUsageSourceKind?
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.customWindows = customWindows
        self.cachedAt = cachedAt
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.sourceKind = sourceKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .sevenDay)
        customWindows = try container.decodeIfPresent([ClaudeLabeledUsageWindow].self, forKey: .customWindows) ?? []
        cachedAt = try container.decodeIfPresent(Date.self, forKey: .cachedAt)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        providerDisplayName = try container.decodeIfPresent(String.self, forKey: .providerDisplayName)
        sourceKind = try container.decodeIfPresent(ClaudeUsageSourceKind.self, forKey: .sourceKind)
    }

    static let empty = ClaudeUsageSnapshot(
        fiveHour: nil,
        sevenDay: nil,
        customWindows: [],
        cachedAt: nil,
        providerID: nil,
        providerDisplayName: nil,
        sourceKind: nil
    )

    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && customWindows.isEmpty
    }

    var displayWindows: [ClaudeLabeledUsageWindow] {
        if !customWindows.isEmpty {
            return customWindows
        }

        var windows: [ClaudeLabeledUsageWindow] = []
        if let fiveHour {
            windows.append(ClaudeLabeledUsageWindow(id: "five_hour", label: "5h", window: fiveHour))
        }
        if let sevenDay {
            windows.append(ClaudeLabeledUsageWindow(id: "seven_day", label: "wk", window: sevenDay))
        }
        return windows
    }

    // TODO: Remove these compatibility aliases once all usage views read the normalized fields.
    var fiveHourWindow: ClaudeUsageWindow? {
        fiveHour
    }

    var sevenDayWindow: ClaudeUsageWindow? {
        sevenDay
    }
}
