//
//  DiagnosticIssue.swift
//  HermitFlow
//
//  Structured local diagnostics model for source health reporting.
//

import Foundation

struct DiagnosticIssue: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case info
        case warning
        case error
    }

    let id: String
    let source: String
    let severity: Severity
    let message: String
    let recoverySuggestion: String?
    let isRepairable: Bool

    init(
        id: String = UUID().uuidString,
        source: String,
        severity: Severity,
        message: String,
        recoverySuggestion: String? = nil,
        isRepairable: Bool = false
    ) {
        self.id = id
        self.source = source
        self.severity = severity
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRepairable = isRepairable
    }
}
