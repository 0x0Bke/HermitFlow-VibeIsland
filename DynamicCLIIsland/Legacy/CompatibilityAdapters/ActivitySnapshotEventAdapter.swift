//
//  ActivitySnapshotEventAdapter.swift
//  HermitFlow
//
//  Phase 4 snapshot-to-event bridge.
//

import Foundation

enum ActivitySnapshotEventAdapter {
    static func events(
        from snapshot: ActivitySourceSnapshot,
        knownSessionIDs: Set<String>
    ) -> [IslandEvent] {
        var events: [IslandEvent] = snapshot.sessions.map { session in
            let payload = SessionEvent(snapshot: session)

            if [.success, .failure].contains(session.activityState) {
                return .sessionCompleted(payload)
            }

            if knownSessionIDs.contains(session.id) {
                return .sessionUpdated(payload)
            }

            return .sessionStarted(payload)
        }

        events.append(.sessionsReconciled(currentSessionIDs: snapshot.sessions.map(\.id), capturedAt: snapshot.lastUpdatedAt))
        if let approvalRequest = snapshot.approvalRequest {
            events.append(.approvalRequested(ApprovalEvent(request: approvalRequest)))
        }
        events.append(.runtimeStatusMessageUpdated(snapshot.statusMessage))
        events.append(.runtimeErrorUpdated(snapshot.errorMessage))
        events.append(.runtimeLastUpdated(snapshot.lastUpdatedAt))
        events.append(.usageSnapshotsUpdated(snapshot.usageSnapshots))
        return events
    }
}
