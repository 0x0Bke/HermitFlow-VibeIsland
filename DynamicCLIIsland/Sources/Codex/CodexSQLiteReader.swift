//
//  CodexSQLiteReader.swift
//  HermitFlow
//
//  Local Codex SQLite discovery for startup recovery and diagnostics.
//

import Foundation

struct CodexSQLiteReader {
    private let fileManager: FileManager
    private let codexHome: URL

    init(
        fileManager: FileManager = .default,
        codexHome: URL = FilePaths.codexHome
    ) {
        self.fileManager = fileManager
        self.codexHome = codexHome
    }

    func latestStateDatabaseURL() -> URL? {
        latestDatabaseURL(prefix: "state_", fallbackName: "state_5.sqlite")
    }

    func latestLogsDatabaseURL() -> URL? {
        latestDatabaseURL(prefix: "logs_", fallbackName: "logs_1.sqlite")
    }

    func healthIssues() -> [DiagnosticIssue] {
        if latestStateDatabaseURL() != nil || latestLogsDatabaseURL() != nil {
            return []
        }

        return [
            SourceErrorMapper.issue(
                source: "Codex",
                severity: .info,
                message: "Codex SQLite state was not found. File-based session recovery will rely on other local artifacts.",
                recoverySuggestion: nil,
                isRepairable: false
            )
        ]
    }

    private func latestDatabaseURL(prefix: String, fallbackName: String) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fileManager.fileExists(atPath: codexHome.appendingPathComponent(fallbackName).path)
                ? codexHome.appendingPathComponent(fallbackName)
                : nil
        }

        let candidates = contents.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
        if let latest = candidates.max(by: modificationDateAscending) {
            return latest
        }

        let fallbackURL = codexHome.appendingPathComponent(fallbackName)
        return fileManager.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    private func modificationDateAscending(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return lhsDate < rhsDate
    }
}
