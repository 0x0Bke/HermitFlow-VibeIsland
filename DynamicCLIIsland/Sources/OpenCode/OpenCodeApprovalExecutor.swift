//
//  OpenCodeApprovalExecutor.swift
//  HermitFlow
//
//  Resolves OpenCode permission prompts through the OpenCode server API.
//

import Foundation

@MainActor
final class OpenCodeApprovalExecutor: ApprovalExecutor {
    private let bridge: OpenCodeHookBridge

    init(bridge: OpenCodeHookBridge = .shared) {
        self.bridge = bridge
    }

    func execute(decision: ApprovalDecision, request: ApprovalRequest) -> ApprovalExecutionResult {
        switch bridge.resolveApproval(id: request.id, decision: decision) {
        case .succeeded:
            return .succeeded(statusMessage: "\(decision.progressMessage)：OpenCode 已收到审批结果")
        case .notFound:
            return .failed(
                diagnostic: ApprovalDiagnostic(
                    message: "OpenCode approval request expired",
                    source: request.source,
                    severity: .error
                )
            )
        }
    }
}
