//
//  SessionReducer.swift
//  HermitFlow
//
//  Phase 4 reducer migration.
//

import Foundation

struct SessionReducer {
    struct State: Equatable {
        var sessionsByID: [String: AgentSessionSnapshot] = [:]
    }

    private let panelVisibilityThreshold: TimeInterval = 60 * 60

    mutating func apply(_ event: IslandEvent, state: inout State) {
        switch event {
        case let .sessionStarted(payload),
             let .sessionUpdated(payload),
             let .sessionCompleted(payload):
            state.sessionsByID[payload.id] = payload.snapshot
        case let .sessionsReconciled(currentSessionIDs, _):
            let visibleIDs = Set(currentSessionIDs)
            state.sessionsByID = state.sessionsByID.filter { visibleIDs.contains($0.key) }
        default:
            break
        }
    }

    func visibleSessions(from state: State, now: Date) -> [AgentSessionSnapshot] {
        sortedSessions(
            state.sessionsByID.values.filter { now.timeIntervalSince($0.updatedAt) <= panelVisibilityThreshold }
        )
    }

    func tasks(from sessions: [AgentSessionSnapshot]) -> [CLIJob] {
        sessions.map(makeTask(from:))
    }

    func deriveStatus(from sessions: [AgentSessionSnapshot], errorMessage: String?) -> IslandCodexActivityState {
        if errorMessage != nil || sessions.contains(where: { $0.activityState == .failure }) {
            return .failure
        }
        if sessions.contains(where: { $0.activityState == .running }) {
            return .running
        }
        if sessions.contains(where: { $0.activityState == .success }) {
            return .success
        }
        return .idle
    }

    func sessionEvent(from task: CLIJob) -> SessionEvent {
        let activityState = activityState(for: task.stage)

        return SessionEvent(
            id: task.id,
            origin: origin(for: task.provider),
            title: task.title,
            detail: task.detail,
            activityState: activityState,
            runningDetail: activityState == .running ? .working : nil,
            updatedAt: task.updatedAt,
            cwd: nil,
            focusTarget: nil,
            freshness: .live
        )
    }

    private func sortedSessions<S: Sequence>(_ sessions: S) -> [AgentSessionSnapshot] where S.Element == AgentSessionSnapshot {
        sessions.sorted { lhs, rhs in
            let leftPriority = statusPriority(lhs.activityState)
            let rightPriority = statusPriority(rhs.activityState)
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            if lhs.freshness != rhs.freshness {
                return freshnessPriority(lhs.freshness) > freshnessPriority(rhs.freshness)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func makeTask(from session: AgentSessionSnapshot) -> CLIJob {
        CLIJob(
            id: session.id,
            provider: session.origin.provider,
            title: session.title,
            detail: session.detail,
            progress: progress(for: session.activityState),
            stage: stage(for: session.activityState),
            etaSeconds: nil,
            updatedAt: session.updatedAt
        )
    }

    private func stage(for activityState: IslandCodexActivityState) -> CLIJobStage {
        switch activityState {
        case .idle:
            return .queued
        case .running:
            return .running
        case .success:
            return .success
        case .failure:
            return .failed
        }
    }

    private func activityState(for stage: CLIJobStage) -> IslandCodexActivityState {
        switch stage {
        case .queued:
            return .idle
        case .running, .blocked:
            return .running
        case .success:
            return .success
        case .failed:
            return .failure
        }
    }

    private func progress(for activityState: IslandCodexActivityState) -> Double {
        switch activityState {
        case .idle:
            return 0
        case .running:
            return 0.5
        case .success, .failure:
            return 1
        }
    }

    private func origin(for provider: CLIProvider) -> SessionOrigin {
        switch provider {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .openCode:
            return .openCode
        case .generic:
            return .generic
        }
    }

    private func statusPriority(_ state: IslandCodexActivityState) -> Int {
        switch state {
        case .failure:
            return 3
        case .running:
            return 2
        case .success:
            return 1
        case .idle:
            return 0
        }
    }

    private func freshnessPriority(_ freshness: SessionFreshness) -> Int {
        switch freshness {
        case .live:
            return 1
        case .stale:
            return 0
        }
    }
}
