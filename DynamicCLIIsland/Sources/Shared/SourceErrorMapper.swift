//
//  SourceErrorMapper.swift
//  HermitFlow
//
//  Shared helpers for turning local source failures into structured diagnostics.
//

import Foundation

enum SourceErrorMapper {
    static func issue(
        source: String,
        severity: DiagnosticIssue.Severity,
        message: String,
        recoverySuggestion: String? = nil,
        isRepairable: Bool = false
    ) -> DiagnosticIssue {
        DiagnosticIssue(
            source: source,
            severity: severity,
            message: message,
            recoverySuggestion: recoverySuggestion,
            isRepairable: isRepairable
        )
    }

    static func issue(
        source: String,
        error: Error,
        severity: DiagnosticIssue.Severity = .warning,
        recoverySuggestion: String? = nil,
        isRepairable: Bool = false
    ) -> DiagnosticIssue {
        issue(
            source: source,
            severity: severity,
            message: error.localizedDescription,
            recoverySuggestion: recoverySuggestion,
            isRepairable: isRepairable
        )
    }

    static func report(source: String, issues: [DiagnosticIssue]) -> SourceHealthReport {
        SourceHealthReport(sourceName: source, issues: issues)
    }
}
