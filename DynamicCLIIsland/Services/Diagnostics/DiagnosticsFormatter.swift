//
//  DiagnosticsFormatter.swift
//  HermitFlow
//
//  UI-friendly formatting helpers for structured source diagnostics.
//

import Foundation

enum DiagnosticsFormatter {
    static func headline(for report: SourceHealthReport) -> String {
        switch report.overallHealth {
        case .healthy:
            return "\(report.sourceName) ready"
        case .warning:
            return "\(report.sourceName) needs attention"
        case .degraded:
            return "\(report.sourceName) degraded"
        }
    }

    static func issueSummary(_ issue: DiagnosticIssue) -> String {
        if let recoverySuggestion = issue.recoverySuggestion, !recoverySuggestion.isEmpty {
            return "\(issue.message) \(recoverySuggestion)"
        }

        return issue.message
    }
}
