//
//  UsageSource.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Shared abstraction for local-first Claude and Codex usage integrations.
///
/// Implementations should read from local artifacts only and fail gracefully
/// when usage data is unavailable.
protocol UsageSource {
    associatedtype Snapshot

    func fetchUsageSnapshot() -> Snapshot?
}
