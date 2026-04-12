//
//  SessionEvent.swift
//  HermitFlow
//
//  Phase 4 event model.
//

import Foundation

struct SessionEvent: Hashable, Identifiable {
    let id: String
    let origin: SessionOrigin
    let title: String
    let detail: String
    let activityState: IslandCodexActivityState
    let updatedAt: Date
    let cwd: String?
    let focusTarget: FocusTarget?
    let freshness: SessionFreshness

    init(snapshot: AgentSessionSnapshot) {
        id = snapshot.id
        origin = snapshot.origin
        title = snapshot.title
        detail = snapshot.detail
        activityState = snapshot.activityState
        updatedAt = snapshot.updatedAt
        cwd = snapshot.cwd
        focusTarget = snapshot.focusTarget
        freshness = snapshot.freshness
    }

    init(
        id: String,
        origin: SessionOrigin,
        title: String,
        detail: String,
        activityState: IslandCodexActivityState,
        updatedAt: Date,
        cwd: String?,
        focusTarget: FocusTarget?,
        freshness: SessionFreshness
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.detail = detail
        self.activityState = activityState
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.focusTarget = focusTarget
        self.freshness = freshness
    }

    var snapshot: AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id,
            origin: origin,
            title: title,
            detail: detail,
            activityState: activityState,
            updatedAt: updatedAt,
            cwd: cwd,
            focusTarget: focusTarget,
            freshness: freshness
        )
    }
}
