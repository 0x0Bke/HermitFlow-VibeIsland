import Foundation

final class FocusRouter {
    func preferredTarget(from sessions: [AgentSessionSnapshot], approvalRequest: ApprovalRequest?) -> FocusTarget? {
        if let approvalTarget = approvalRequest?.focusTarget {
            return approvalTarget
        }

        return sessions
            .compactMap(\.focusTarget)
            .sorted(by: compareTargets)
            .first
    }

    private func compareTargets(_ lhs: FocusTarget, _ rhs: FocusTarget) -> Bool {
        let leftPriority = priority(for: lhs.clientOrigin)
        let rightPriority = priority(for: rhs.clientOrigin)
        if leftPriority != rightPriority {
            return leftPriority > rightPriority
        }

        return lhs.sessionID > rhs.sessionID
    }

    private func priority(for origin: FocusClientOrigin) -> Int {
        switch origin {
        case .claudeVSCode:
            return 2
        case .claudeCLI:
            return 1
        case .codexDesktop:
            return 3
        case .codexVSCode:
            return 2
        case .codexCLI:
            return 1
        case .openCodeCLI:
            return 1
        case .unknown:
            return 0
        }
    }
}
