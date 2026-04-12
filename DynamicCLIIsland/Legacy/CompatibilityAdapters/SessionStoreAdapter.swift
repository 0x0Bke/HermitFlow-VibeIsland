//
//  SessionStoreAdapter.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Temporary compatibility seam around the legacy `SessionStore`.
///
/// The reducer-backed `RuntimeStore` now owns the preferred mutation path.
/// This adapter remains available only for compatibility until the remaining
/// snapshot-based call sites are migrated.
final class SessionStoreAdapter {
    let store: SessionStore

    init(store: SessionStore = SessionStore()) {
        self.store = store
    }

    func apply(activitySnapshot: ActivitySourceSnapshot) -> IslandRuntimeState {
        store.apply(activitySnapshot: activitySnapshot)
    }

    func apply(
        progressEnvelope: ProgressEnvelope,
        sourceLabel: String,
        errorMessage: String?
    ) -> IslandRuntimeState {
        store.apply(
            progressEnvelope: progressEnvelope,
            sourceLabel: sourceLabel,
            errorMessage: errorMessage
        )
    }

    func makeFailureState(
        statusMessage: String,
        errorMessage: String,
        lastUpdatedAt: Date = .now
    ) -> IslandRuntimeState {
        store.makeFailureState(
            statusMessage: statusMessage,
            errorMessage: errorMessage,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}
