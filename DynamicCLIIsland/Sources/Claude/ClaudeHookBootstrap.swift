//
//  ClaudeHookBootstrap.swift
//  HermitFlow
//
//  Startup bootstrap for Claude hook installation and callback readiness.
//

import Foundation

struct ClaudeHookBootstrap {
    private let installer: ClaudeHookInstaller
    private let callbackServer: ClaudeHTTPCallbackServer
    private let healthChecker: ClaudeHookHealthChecker

    init(
        installer: ClaudeHookInstaller = ClaudeHookInstaller(),
        callbackServer: ClaudeHTTPCallbackServer = ClaudeHTTPCallbackServer(),
        healthChecker: ClaudeHookHealthChecker = ClaudeHookHealthChecker()
    ) {
        self.installer = installer
        self.callbackServer = callbackServer
        self.healthChecker = healthChecker
    }

    @discardableResult
    func bootstrap() -> SourceHealthReport {
        callbackServer.start()
        do {
            try installer.resync()
        } catch {
            return SourceHealthReport(
                sourceName: "Claude",
                issues: [
                    SourceErrorMapper.issue(
                        source: "Claude",
                        error: error,
                        severity: .error,
                        recoverySuggestion: "Use “Resync Claude Hooks” to repair the managed hook entries.",
                        isRepairable: true
                    )
                ]
            )
        }

        return healthChecker.healthReport()
    }
}
