//
//  ApprovalExecutor.swift
//  HermitFlow
//
//  Phase 5 approval subsystem abstraction.
//

import Foundation

enum ApprovalExecutionOutcome: Equatable {
    case succeeded
    case routedToManualHandling
    case failed
}

struct ApprovalExecutionResult: Equatable {
    let outcome: ApprovalExecutionOutcome
    let statusMessage: String?
    let diagnostic: ApprovalDiagnostic?
    let shouldResolveRequest: Bool

    static func succeeded(statusMessage: String? = nil) -> ApprovalExecutionResult {
        ApprovalExecutionResult(
            outcome: .succeeded,
            statusMessage: statusMessage,
            diagnostic: nil,
            shouldResolveRequest: true
        )
    }

    static func routedToManualHandling(
        statusMessage: String? = nil,
        diagnostic: ApprovalDiagnostic? = nil
    ) -> ApprovalExecutionResult {
        ApprovalExecutionResult(
            outcome: .routedToManualHandling,
            statusMessage: statusMessage,
            diagnostic: diagnostic,
            shouldResolveRequest: false
        )
    }

    static func failed(
        statusMessage: String? = nil,
        diagnostic: ApprovalDiagnostic? = nil,
        shouldResolveRequest: Bool = false
    ) -> ApprovalExecutionResult {
        ApprovalExecutionResult(
            outcome: .failed,
            statusMessage: statusMessage,
            diagnostic: diagnostic,
            shouldResolveRequest: shouldResolveRequest
        )
    }
}

@MainActor
protocol ApprovalExecutor {
    func execute(decision: ApprovalDecision, request: ApprovalRequest) -> ApprovalExecutionResult
}
