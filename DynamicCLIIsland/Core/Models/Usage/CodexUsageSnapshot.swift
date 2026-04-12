//
//  CodexUsageSnapshot.swift
//  HermitFlow
//
//  Phase 6 local-first usage model.
//

import Foundation

struct CodexUsageWindow: Equatable, Codable, Hashable, Identifiable {
    var key: String
    var label: String
    var usedPercentage: Double
    var leftPercentage: Double
    var windowMinutes: Int
    var resetsAt: Date?

    var id: String {
        "\(key)-\(windowMinutes)"
    }

    var roundedUsedPercentage: Int {
        Int((min(max(usedPercentage, 0), 1) * 100).rounded())
    }
}

struct CodexUsageSnapshot: Equatable, Codable, Hashable {
    var sourceFilePath: String
    var capturedAt: Date?
    var planType: String?
    var limitID: String?
    var windows: [CodexUsageWindow]

    static let empty = CodexUsageSnapshot(
        sourceFilePath: "",
        capturedAt: nil,
        planType: nil,
        limitID: nil,
        windows: [],
    )

    var isEmpty: Bool {
        windows.isEmpty
    }

    // TODO: Remove this alias once remaining callers reference `CodexUsageWindow` directly.
    typealias Window = CodexUsageWindow
}
