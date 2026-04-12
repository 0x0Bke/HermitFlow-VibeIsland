import Foundation

/// Legacy snapshot transformer retained during the Phase 4 reducer migration.
///
/// `RuntimeStore` now prefers reducer-owned state updates routed through
/// `IslandEvent`, but this type remains available as a compatibility seam
/// while older file/demo flows and adapters are still being retired.
final class SessionStore {
    private let panelVisibilityThreshold: TimeInterval = 60 * 60
    private(set) var sessions: [AgentSessionSnapshot] = []

    func apply(activitySnapshot: ActivitySourceSnapshot) -> IslandRuntimeState {
        let visibleSessions = filterPanelVisibleSessions(activitySnapshot.sessions)
        sessions = sortedSessions(visibleSessions)

        return IslandRuntimeState(
            sessions: sessions,
            tasks: sessions.map(makeTask(from:)),
            codexStatus: deriveStatus(from: sessions, errorMessage: activitySnapshot.errorMessage),
            statusMessage: activitySnapshot.statusMessage,
            lastUpdatedAt: activitySnapshot.lastUpdatedAt,
            errorMessage: activitySnapshot.errorMessage,
            approvalRequest: activitySnapshot.approvalRequest,
            usageSnapshots: activitySnapshot.usageSnapshots
        )
    }

    func apply(progressEnvelope: ProgressEnvelope, sourceLabel: String, errorMessage: String?) -> IslandRuntimeState {
        let sortedTasks = progressEnvelope.tasks.sorted { lhs, rhs in
            if lhs.stage == .running && rhs.stage != .running {
                return true
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        sessions = sortedTasks.map(makeSession(from:))

        return IslandRuntimeState(
            sessions: sessions,
            tasks: sortedTasks,
            codexStatus: deriveStatus(from: sortedTasks, errorMessage: errorMessage),
            statusMessage: sourceLabel,
            lastUpdatedAt: progressEnvelope.generatedAt,
            errorMessage: errorMessage,
            approvalRequest: nil,
            usageSnapshots: []
        )
    }

    func makeFailureState(statusMessage: String, errorMessage: String, lastUpdatedAt: Date = .now) -> IslandRuntimeState {
        sessions = []

        return IslandRuntimeState(
            sessions: [],
            tasks: [],
            codexStatus: .failure,
            statusMessage: statusMessage,
            lastUpdatedAt: lastUpdatedAt,
            errorMessage: errorMessage,
            approvalRequest: nil,
            usageSnapshots: []
        )
    }

    private func filterPanelVisibleSessions(_ sessions: [AgentSessionSnapshot], now: Date = .now) -> [AgentSessionSnapshot] {
        sessions.filter { now.timeIntervalSince($0.updatedAt) <= panelVisibilityThreshold }
    }

    private func sortedSessions(_ sessions: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
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

    private func deriveStatus(from sessions: [AgentSessionSnapshot], errorMessage: String?) -> IslandCodexActivityState {
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

    private func deriveStatus(from tasks: [CLIJob], errorMessage: String?) -> IslandCodexActivityState {
        if errorMessage != nil || tasks.contains(where: { $0.stage == .failed }) {
            return .failure
        }
        if tasks.contains(where: { [.queued, .running, .blocked].contains($0.stage) }) {
            return .running
        }
        if tasks.contains(where: { $0.stage == .success }) {
            return .success
        }
        return .idle
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

    private func makeSession(from task: CLIJob) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: task.id,
            origin: origin(for: task.provider),
            title: task.title,
            detail: task.detail,
            activityState: activityState(for: task.stage),
            updatedAt: task.updatedAt,
            cwd: nil,
            focusTarget: nil,
            freshness: .live
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
        case .success:
            return 1
        case .failure:
            return 1
        }
    }

    private func origin(for provider: CLIProvider) -> SessionOrigin {
        switch provider {
        case .claude:
            return .claude
        case .codex:
            return .codex
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
