//
//  OpenCodeUsageSource.swift
//  HermitFlow
//
//  Local-first OpenCode usage source.
//

import Foundation

final class OpenCodeUsageSource: UsageSource, @unchecked Sendable {
    typealias Snapshot = OpenCodeUsageSnapshot

    func fetchUsageSnapshot() -> OpenCodeUsageSnapshot? {
        try? OpenCodeUsageLoader.load()
    }
}
