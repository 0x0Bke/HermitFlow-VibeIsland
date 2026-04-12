//
//  ClaudeHookHealthChecker.swift
//  HermitFlow
//
//  Structured local health checks for Claude hook integration.
//

import Foundation

struct ClaudeHookHealthChecker {
    private let installer: ClaudeHookInstaller
    private let callbackServer: ClaudeHTTPCallbackServer

    init(
        installer: ClaudeHookInstaller = ClaudeHookInstaller(),
        callbackServer: ClaudeHTTPCallbackServer = ClaudeHTTPCallbackServer()
    ) {
        self.installer = installer
        self.callbackServer = callbackServer
    }

    func healthReport() -> SourceHealthReport {
        let installerReport = installer.healthReport()
        let callbackReport = callbackServer.healthReport()
        let issues = installerReport.issues + callbackReport.issues
        return SourceHealthReport(sourceName: "Claude", issues: issues)
    }
}
