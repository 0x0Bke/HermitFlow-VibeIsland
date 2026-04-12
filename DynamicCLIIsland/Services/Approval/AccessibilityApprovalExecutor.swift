//
//  AccessibilityApprovalExecutor.swift
//  HermitFlow
//
//  Phase 5 approval subsystem executor.
//

import Foundation

@MainActor
final class AccessibilityApprovalExecutor: ApprovalExecutor {
    private let focusLauncher: FocusLauncher
    private let accessibilityPermissionMonitor: AccessibilityPermissionMonitor

    init(
        focusLauncher: FocusLauncher,
        accessibilityPermissionMonitor: AccessibilityPermissionMonitor
    ) {
        self.focusLauncher = focusLauncher
        self.accessibilityPermissionMonitor = accessibilityPermissionMonitor
    }

    func execute(decision: ApprovalDecision, request: ApprovalRequest) -> ApprovalExecutionResult {
        guard let target = request.focusTarget else {
            return .failed(
                diagnostic: ApprovalDiagnostic(
                    message: "没有可用的目标窗口，无法自动审批。",
                    source: request.source,
                    severity: .warning
                )
            )
        }

        guard accessibilityPermissionMonitor.isTrusted() else {
            guard focusLauncher.bringToFront(target) else {
                return .failed(
                    diagnostic: ApprovalDiagnostic(
                        message: "Unable to locate \(target.displayName)",
                        source: request.source,
                        severity: .error
                    )
                )
            }

            return .routedToManualHandling(
                statusMessage: "缺少辅助功能权限，正在打开 \(target.displayName) 以手动处理审批",
                diagnostic: ApprovalDiagnostic(
                    message: "缺少辅助功能权限，已回退为手动处理。",
                    source: request.source,
                    severity: .warning,
                    recoverySuggestion: "请在系统设置中授予辅助功能权限后重试自动审批。"
                )
            )
        }

        let result = focusLauncher.performApproval(decision, for: target)
        switch result {
        case .success:
            return .succeeded(statusMessage: "\(decision.progressMessage) in \(target.displayName)：自动审批成功")
        case .routedToWindow:
            return .routedToManualHandling(
                statusMessage: "已打开 \(target.displayName)，请手动处理审批"
            )
        case .applicationNotFound:
            return .failed(
                diagnostic: ApprovalDiagnostic(
                    message: "Unable to locate \(target.displayName)",
                    source: request.source,
                    severity: .error
                )
            )
        default:
            guard focusLauncher.bringToFront(target) else {
                return .failed(
                    diagnostic: ApprovalDiagnostic(
                        message: "Unable to locate \(target.displayName)",
                        source: request.source,
                        severity: .error
                    )
                )
            }

            return .routedToManualHandling(
                statusMessage: "\(result.diagnosticMessage)，正在打开 \(target.displayName) 以手动处理",
                diagnostic: ApprovalDiagnostic(
                    message: result.diagnosticMessage,
                    source: request.source,
                    severity: .warning
                )
            )
        }
    }
}
