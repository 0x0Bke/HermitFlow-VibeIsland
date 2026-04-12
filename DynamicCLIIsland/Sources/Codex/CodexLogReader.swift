//
//  CodexLogReader.swift
//  HermitFlow
//
//  Local Codex log discovery for diagnostics and fallback context.
//

import Foundation

struct CodexLogReader {
    private let fileManager: FileManager
    private let historyURL: URL
    private let tuiLogURL: URL

    init(
        fileManager: FileManager = .default,
        historyURL: URL = FilePaths.codexHome.appendingPathComponent("history.jsonl"),
        tuiLogURL: URL = FilePaths.codexHome.appendingPathComponent("log/codex-tui.log")
    ) {
        self.fileManager = fileManager
        self.historyURL = historyURL
        self.tuiLogURL = tuiLogURL
    }

    func healthIssues() -> [DiagnosticIssue] {
        if fileManager.fileExists(atPath: historyURL.path) || fileManager.fileExists(atPath: tuiLogURL.path) {
            return []
        }

        return [
            SourceErrorMapper.issue(
                source: "Codex",
                severity: .info,
                message: "Codex history logs are not available. Historical recovery will be limited until local logs are created."
            )
        ]
    }
}
