//
//  CodexRolloutUsageSource.swift
//  HermitFlow
//
//  Phase 6 local-first usage source.
//

import Foundation

final class CodexRolloutUsageSource: UsageSource, @unchecked Sendable {
    typealias Snapshot = CodexUsageSnapshot

    func fetchUsageSnapshot() -> CodexUsageSnapshot? {
        try? CodexUsageLoader.load()
    }
}
