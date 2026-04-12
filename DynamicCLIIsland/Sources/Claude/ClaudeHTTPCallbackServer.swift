//
//  ClaudeHTTPCallbackServer.swift
//  HermitFlow
//
//  Thin boundary around the local Claude hook callback listener.
//

import Foundation

struct ClaudeHTTPCallbackServer {
    private let source: LocalClaudeSource

    init(source: LocalClaudeSource = LocalClaudeSource()) {
        self.source = source
    }

    func start() {
        source.startCallbackServer()
    }

    func healthReport() -> SourceHealthReport {
        source.callbackServerHealthReport()
    }
}
