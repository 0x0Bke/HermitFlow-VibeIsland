//
//  FocusRouting.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Shared abstraction for focus-target selection and foreground launching policy.
///
/// The existing `FocusRouter` will be adapted to this protocol in a later phase.
protocol FocusRouting {
    func preferredTarget(
        from sessions: [AgentSessionSnapshot],
        approvalRequest: ApprovalRequest?
    ) -> FocusTarget?
}
