//
//  CodexSessionReader.swift
//  HermitFlow
//
//  Local Codex session directory discovery for fallback reconciliation.
//

import Foundation

struct CodexSessionReader {
    private let fileManager: FileManager
    private let sessionsDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        sessionsDirectoryURL: URL = FilePaths.codexHome.appendingPathComponent("sessions", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.sessionsDirectoryURL = sessionsDirectoryURL
    }

    func sessionsDirectoryExists() -> Bool {
        fileManager.fileExists(atPath: sessionsDirectoryURL.path)
    }

    func latestRolloutURL() -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latest: (url: URL, modifiedAt: Date)?
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl" else {
                continue
            }

            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if latest == nil || modifiedAt > latest!.modifiedAt {
                latest = (fileURL, modifiedAt)
            }
        }

        return latest?.url
    }

    func healthIssues() -> [DiagnosticIssue] {
        guard sessionsDirectoryExists() else {
            return [
                SourceErrorMapper.issue(
                    source: "Codex",
                    severity: .info,
                    message: "Codex session artifacts are not present yet. Real-time file watching will stay idle until local sessions appear."
                )
            ]
        }

        return []
    }
}
