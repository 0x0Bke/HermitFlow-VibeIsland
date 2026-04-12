//
//  ApprovalDiagnostic.swift
//  HermitFlow
//
//  Phase 5 approval subsystem model.
//

import Foundation

struct ApprovalDiagnostic: Equatable, Hashable {
    enum Severity: String, Equatable, Hashable {
        case info
        case warning
        case error
    }

    let message: String
    let source: SessionOrigin?
    let severity: Severity
    let recoverySuggestion: String?

    init(
        message: String,
        source: SessionOrigin? = nil,
        severity: Severity = .info,
        recoverySuggestion: String? = nil
    ) {
        self.message = message
        self.source = source
        self.severity = severity
        self.recoverySuggestion = recoverySuggestion
    }
}
