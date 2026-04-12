//
//  IslandEvent.swift
//  HermitFlow
//
//  Phase 4 event model.
//

import Foundation

enum IslandEvent: Hashable {
    case sessionStarted(SessionEvent)
    case sessionUpdated(SessionEvent)
    case sessionCompleted(SessionEvent)
    case sessionsReconciled(currentSessionIDs: [String], capturedAt: Date)
    case approvalRequested(ApprovalEvent)
    case approvalResolved(ApprovalEvent)
    case focusTargetUpdated(FocusTarget?)
    case diagnosticUpdated(DiagnosticsEvent)
    case runtimeStatusMessageUpdated(String)
    case runtimeErrorUpdated(String?)
    case runtimeLastUpdated(Date)
    case usageSnapshotsUpdated([ProviderUsageSnapshot])
    case usageProviderStateUpdated(UsageProviderState)
}
