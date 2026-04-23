//
//  OpenCodeSQLiteReader.swift
//  HermitFlow
//
//  Read-only fallback for recent OpenCode sessions.
//

import Foundation

struct OpenCodeSQLiteReader: @unchecked Sendable {
    private let fileManager: FileManager
    private let databaseURL: URL
    private let recentSessionLimit: Int
    private let sessionLookback: TimeInterval
    private let freshSuccessWindow: TimeInterval
    private let sqliteReadClient = OpenCodeSQLiteReadClient(cacheTTL: 1.0)

    init(
        fileManager: FileManager = .default,
        databaseURL: URL = FilePaths.openCodeDatabase,
        recentSessionLimit: Int = 6,
        sessionLookback: TimeInterval = 6 * 60 * 60,
        freshSuccessWindow: TimeInterval = 1.25
    ) {
        self.fileManager = fileManager
        self.databaseURL = databaseURL
        self.recentSessionLimit = recentSessionLimit
        self.sessionLookback = sessionLookback
        self.freshSuccessWindow = freshSuccessWindow
    }

    func fetchActivity() -> ActivitySourceSnapshot {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return ActivitySourceSnapshot(
                sessions: [],
                statusMessage: "Waiting for OpenCode activity",
                lastUpdatedAt: .now,
                errorMessage: nil,
                approvalRequest: nil,
                usageSnapshots: []
            )
        }

        let now = Date()
        let sessions = fetchRecentSessions(now: now)
        let statusMessage = sessions.isEmpty
            ? "Waiting for OpenCode activity"
            : "Watching OpenCode activity"

        return ActivitySourceSnapshot(
            sessions: sessions,
            statusMessage: statusMessage,
            lastUpdatedAt: sessions.map(\.updatedAt).max() ?? now,
            errorMessage: nil,
            approvalRequest: nil,
            usageSnapshots: []
        )
    }

    func healthIssues() -> [DiagnosticIssue] {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return [
                SourceErrorMapper.issue(
                    source: "OpenCode",
                    severity: .info,
                    message: "OpenCode SQLite state was not found. Live hook events will still work when OpenCode loads the HermitFlow plugin.",
                    recoverySuggestion: nil,
                    isRepairable: false
                )
            ]
        }

        return []
    }

    private func fetchRecentSessions(now: Date) -> [AgentSessionSnapshot] {
        let sql = """
        select json_object(
          'id', id,
          'title', title,
          'directory', directory,
          'timeUpdated', time_updated,
          'latestAssistantMessage', (
            select data
            from message
            where message.session_id = session.id
              and json_extract(message.data, '$.role') = 'assistant'
            order by time_updated desc
            limit 1
          ),
          'latestPart', (
            select data
            from part
            where part.session_id = session.id
            order by time_updated desc
            limit 1
          )
        )
        from session
        where time_archived is null
        order by time_updated desc
        limit \(recentSessionLimit);
        """

        return (runSQLiteRows(sql: sql) ?? [])
            .compactMap { row in
                makeSession(from: row, now: now)
            }
    }

    private func makeSession(from row: String, now: Date) -> AgentSessionSnapshot? {
        guard let data = row.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = raw["id"] as? String,
              !id.isEmpty else {
            return nil
        }

        let title = normalizedString(raw["title"]) ?? "OpenCode Session"
        let directory = normalizedString(raw["directory"])
        let updatedMilliseconds = doubleValue(raw["timeUpdated"]) ?? 0
        let updatedAt = Date(timeIntervalSince1970: updatedMilliseconds / 1000)
        guard now.timeIntervalSince(updatedAt) <= sessionLookback else {
            return nil
        }

        let activityState = activityState(from: raw, updatedAt: updatedAt, now: now)
        let focusTarget = FocusTarget(
            clientOrigin: .openCodeCLI,
            sessionID: id,
            displayName: "OpenCode CLI",
            cwd: directory,
            terminalClient: .unknown,
            terminalSessionHint: nil,
            workspaceHint: directory
        )

        return AgentSessionSnapshot(
            id: id,
            origin: .openCode,
            title: title,
            detail: directory ?? "Watching OpenCode activity",
            activityState: activityState,
            runningDetail: nil,
            updatedAt: updatedAt,
            cwd: directory,
            focusTarget: focusTarget,
            freshness: .stale
        )
    }

    private func activityState(
        from raw: [String: Any],
        updatedAt: Date,
        now: Date
    ) -> IslandCodexActivityState {
        guard now.timeIntervalSince(updatedAt) <= freshSuccessWindow else {
            return .idle
        }

        if let latestPart = jsonDictionaryString(raw["latestPart"]),
           let partType = normalizedString(latestPart["type"])?.lowercased(),
           partType == "step-finish",
           let reason = normalizedString(latestPart["reason"])?.lowercased(),
           reason != "tool-calls" {
            return .success
        }

        guard let latestAssistant = jsonDictionaryString(raw["latestAssistantMessage"]),
              let completedAt = value(at: ["time", "completed"], in: latestAssistant),
              doubleValue(completedAt) != nil else {
            return .idle
        }

        let finish = normalizedString(latestAssistant["finish"])?.lowercased()
        return finish == "tool-calls" ? .idle : .success
    }

    private func runSQLiteRows(sql: String) -> [String]? {
        let output = sqliteReadClient.query(databaseURL: databaseURL, sql: sql)
        let rows = output?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        return rows.isEmpty ? nil : rows
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func jsonDictionaryString(_ value: Any?) -> [String: Any]? {
        guard let string = normalizedString(value),
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }

    private func value(at path: [String], in payload: [String: Any]) -> Any? {
        var current: Any = payload
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }

        return current
    }
}

private final class OpenCodeSQLiteReadClient: @unchecked Sendable {
    private struct CacheEntry {
        let output: String?
        let storedAt: Date
    }

    private let cacheTTL: TimeInterval
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    init(cacheTTL: TimeInterval) {
        self.cacheTTL = cacheTTL
    }

    func query(databaseURL: URL, sql: String, now: Date = .now) -> String? {
        let key = "\(databaseURL.path)|\(sql)"
        lock.lock()
        if let entry = cache[key], now.timeIntervalSince(entry.storedAt) < cacheTTL {
            lock.unlock()
            return entry.output
        }
        lock.unlock()

        let output = runSQLite(databaseURL: databaseURL, sql: sql)

        lock.lock()
        cache[key] = CacheEntry(output: output, storedAt: now)
        lock.unlock()

        return output
    }

    private func runSQLite(databaseURL: URL, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, sql]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
