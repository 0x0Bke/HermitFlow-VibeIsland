//
//  HTTPHookApprovalExecutor.swift
//  HermitFlow
//
//  Phase 5 approval subsystem executor.
//

import Foundation

@MainActor
final class HTTPHookApprovalExecutor: ApprovalExecutor {
    private let localClaudeSource: LocalClaudeSource

    init(localClaudeSource: LocalClaudeSource) {
        self.localClaudeSource = localClaudeSource
    }

    func execute(decision: ApprovalDecision, request: ApprovalRequest) -> ApprovalExecutionResult {
        if localClaudeSource.resolveApproval(id: request.id, decision: decision) {
            return .succeeded(statusMessage: "\(decision.progressMessage)：Claude Code 已收到审批结果")
        }

        return .failed(
            diagnostic: ApprovalDiagnostic(
                message: "Approval request expired",
                source: request.source,
                severity: .error
            )
        )
    }
}
