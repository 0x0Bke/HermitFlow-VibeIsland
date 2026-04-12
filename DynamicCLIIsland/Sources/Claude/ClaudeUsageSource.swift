//
//  ClaudeUsageSource.swift
//  HermitFlow
//
//  Phase 6 local-first usage source.
//

import Foundation

final class ClaudeUsageSource: UsageSource, @unchecked Sendable {
    typealias Snapshot = ClaudeUsageSnapshot

    func fetchUsageSnapshot() -> ClaudeUsageSnapshot? {
        try? ClaudeUsageLoader.load()
    }
}
