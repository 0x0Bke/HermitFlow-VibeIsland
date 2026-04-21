import Foundation
import SwiftUI

enum CLIProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case openCode
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .openCode:
            return "OpenCode"
        case .generic:
            return "CLI"
        }
    }

    var tint: Color {
        switch self {
        case .claude:
            return Color(red: 0.96, green: 0.58, blue: 0.29)
        case .codex:
            return Color(red: 0.33, green: 0.78, blue: 0.95)
        case .openCode:
            return Color(red: 0.49, green: 0.83, blue: 0.53)
        case .generic:
            return Color(red: 0.54, green: 0.72, blue: 0.99)
        }
    }
}

enum CLIJobStage: String, Codable {
    case queued
    case running
    case blocked
    case success
    case failed

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .blocked:
            return "Blocked"
        case .success:
            return "Success"
        case .failed:
            return "Failed"
        }
    }
}

struct CLIJob: Identifiable, Codable, Hashable {
    var id: String
    var provider: CLIProvider
    var title: String
    var detail: String
    var progress: Double
    var stage: CLIJobStage
    var etaSeconds: Int?
    var updatedAt: Date

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var progressPercent: Int {
        Int(clampedProgress * 100)
    }

    var statusLine: String {
        if let etaSeconds, stage == .running {
            return "\(stage.label) · ETA \(etaSeconds)s"
        }

        return stage.label
    }
}

struct ProgressEnvelope: Codable {
    var generatedAt: Date
    var tasks: [CLIJob]
}
