//
//  SourceHealthReport.swift
//  HermitFlow
//
//  Structured local health report for runtime integrations.
//

import Foundation

struct SourceHealthReport: Identifiable, Hashable, Sendable {
    enum OverallHealth: String, Hashable, Sendable {
        case healthy
        case warning
        case degraded
    }

    let sourceName: String
    let overallHealth: OverallHealth
    let issues: [DiagnosticIssue]

    var id: String { sourceName }
    var hasIssues: Bool { !issues.isEmpty }

    init(sourceName: String, issues: [DiagnosticIssue]) {
        self.sourceName = sourceName
        self.issues = issues

        if issues.contains(where: { $0.severity == .error }) {
            overallHealth = .degraded
        } else if issues.isEmpty {
            overallHealth = .healthy
        } else {
            overallHealth = .warning
        }
    }
}
