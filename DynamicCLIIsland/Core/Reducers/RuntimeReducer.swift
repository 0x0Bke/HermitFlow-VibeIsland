//
//  RuntimeReducer.swift
//  HermitFlow
//
//  Phase 4 reducer migration.
//

import Foundation

struct RuntimeReducer {
    struct State: Equatable {
        var sessionState = SessionReducer.State()
        var approvalState = ApprovalReducer.State()
        var sessions: [AgentSessionSnapshot] = []
        var tasks: [CLIJob] = []
        var codexStatus: IslandCodexActivityState = .idle
        var statusMessage = "Waiting for CLI status"
        var lastUpdatedAt: Date = .now
        var errorMessage: String?
        var focusTarget: FocusTarget?
        var approvalRequest: ApprovalRequest?
        var approvalDiagnostic: ApprovalDiagnostic?
        var usageSnapshots: [ProviderUsageSnapshot] = []
        var usageProviderState: UsageProviderState = .empty
    }

    private var sessionReducer = SessionReducer()
    private var approvalReducer = ApprovalReducer()

    mutating func apply(_ event: IslandEvent, to state: inout State) {
        sessionReducer.apply(event, state: &state.sessionState)
        approvalReducer.apply(event, state: &state.approvalState)

        switch event {
        case let .focusTargetUpdated(target):
            state.focusTarget = target
        case .diagnosticUpdated:
            state.approvalDiagnostic = state.approvalState.diagnostic
        case let .runtimeStatusMessageUpdated(message):
            state.statusMessage = message
        case let .runtimeErrorUpdated(message):
            state.errorMessage = message?.isEmpty == true ? nil : message
        case let .runtimeLastUpdated(date):
            state.lastUpdatedAt = date
        case let .usageSnapshotsUpdated(snapshots):
            state.usageSnapshots = snapshots
        case let .usageProviderStateUpdated(usageProviderState):
            state.usageProviderState = usageProviderState
            state.usageSnapshots = usageProviderState.legacySnapshots
        case .approvalRequested, .approvalResolved:
            state.approvalRequest = approvalReducer.resolvedApproval(
                state: state.approvalState,
                previousApprovalRequest: state.approvalRequest,
                incomingApprovalRequest: state.approvalState.currentRequest
            )
            state.approvalDiagnostic = state.approvalState.diagnostic
        case .sessionStarted, .sessionUpdated, .sessionCompleted, .sessionsReconciled:
            break
        }

        recomputeSessionDerivedState(&state)
    }

    mutating func apply(_ events: [IslandEvent], to state: inout State) {
        for event in events {
            apply(event, to: &state)
        }
    }

    func sessionEvent(from task: CLIJob) -> SessionEvent {
        sessionReducer.sessionEvent(from: task)
    }

    mutating func setApprovalPreviewRequest(_ request: ApprovalRequest?, state: inout State) {
        approvalReducer.setPreviewRequest(request, state: &state.approvalState)
        state.approvalRequest = approvalReducer.resolvedApproval(
            state: state.approvalState,
            previousApprovalRequest: state.approvalRequest,
            incomingApprovalRequest: state.approvalState.currentRequest
        )
        state.approvalDiagnostic = state.approvalState.diagnostic
    }

    mutating func setCollapsedApprovalRequestID(_ requestID: String?, state: inout State) {
        approvalReducer.syncCollapsedRequestID(requestID, state: &state.approvalState)
    }

    mutating func setApprovalDiagnostic(_ diagnostic: ApprovalDiagnostic?, state: inout State) {
        approvalReducer.setDiagnostic(diagnostic, state: &state.approvalState)
        state.approvalDiagnostic = state.approvalState.diagnostic
    }

    private mutating func recomputeSessionDerivedState(_ state: inout State) {
        let visibleSessions = sessionReducer.visibleSessions(from: state.sessionState, now: state.lastUpdatedAt)
        state.sessions = visibleSessions
        state.tasks = sessionReducer.tasks(from: visibleSessions)
        state.codexStatus = sessionReducer.deriveStatus(from: visibleSessions, errorMessage: state.errorMessage)
    }
}
