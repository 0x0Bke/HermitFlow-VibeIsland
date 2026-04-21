//
//  OpenCodeUsageSnapshot.swift
//  HermitFlow
//
//  Local-first OpenCode third-party provider usage model.
//

import Foundation

enum OpenCodeUsageSourceKind: String, Codable, Hashable {
    case remoteProvider
}

struct OpenCodeLabeledUsageWindow: Equatable, Codable, Hashable {
    var id: String
    var label: String
    var window: OpenCodeUsageWindow
}

struct OpenCodeUsageWindow: Equatable, Codable, Hashable {
    var usedPercentage: Double
    var resetsAt: Date?

    var roundedUsedPercentage: Int {
        Int((min(max(usedPercentage, 0), 1) * 100).rounded())
    }

    var leftPercentage: Double {
        max(0, 1 - usedPercentage)
    }

    var roundedLeftPercentage: Int {
        Int((min(max(leftPercentage, 0), 1) * 100).rounded())
    }
}

struct OpenCodeUsageSnapshot: Equatable, Codable, Hashable {
    var customWindows: [OpenCodeLabeledUsageWindow]
    var capturedAt: Date?
    var providerID: String?
    var providerDisplayName: String?
    var modelID: String?
    var sourceKind: OpenCodeUsageSourceKind?

    static let empty = OpenCodeUsageSnapshot(
        customWindows: [],
        capturedAt: nil,
        providerID: nil,
        providerDisplayName: nil,
        modelID: nil,
        sourceKind: nil
    )

    var isEmpty: Bool {
        customWindows.isEmpty
    }

    var displayWindows: [OpenCodeLabeledUsageWindow] {
        customWindows
    }
}
