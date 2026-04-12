//
//  ClaudeHookInstaller.swift
//  HermitFlow
//
//  Local-only installer wrapper for Claude hook lifecycle management.
//

import Foundation

struct ClaudeHookInstaller: HookInstaller {
    private let source: LocalClaudeSource

    init(source: LocalClaudeSource = LocalClaudeSource()) {
        self.source = source
    }

    func install() throws {
        try source.installHooks()
    }

    func uninstall() throws {
        try source.uninstallHooks()
    }

    func resync() throws {
        try source.installHooks()
    }

    func healthReport() -> SourceHealthReport {
        source.hookHealthReport()
    }
}
