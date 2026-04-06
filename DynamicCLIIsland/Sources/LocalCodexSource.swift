import AppKit
import Foundation
import Network

struct LocalCodexSource: @unchecked Sendable {
    private let stateDatabaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
    private let logsDatabaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/logs_1.sqlite")
    private let sessionsDirectoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private let globalStateURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/.codex-global-state.json")
    private let tuiLogURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/log/codex-tui.log")
    private let recentThreadLimit = 8
    private let idleSessionLookback: TimeInterval = 6 * 60 * 60
    private let unconfirmedDesktopSessionLookback: TimeInterval = 5 * 60
    private let fallbackTUILookback: TimeInterval = 6 * 60 * 60
    private let staleSessionThreshold: TimeInterval = 3 * 60
    private let recentSessionScanBytes = 768 * 1024
    private let runningSignalMaxAge: TimeInterval = 30
    private let terminalStatusHold: TimeInterval = 18
    private let successSettleDelay: TimeInterval = 1
    private let shellSnapshotsDirectoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/shell_snapshots")
    private let sessionFileLocator = SessionFileLocator(
        rootURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    )
    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func fetchActivity() -> ActivitySourceSnapshot {
        guard
            FileManager.default.fileExists(atPath: stateDatabaseURL.path),
            FileManager.default.fileExists(atPath: logsDatabaseURL.path)
        else {
            return ActivitySourceSnapshot(
                sessions: [],
                statusMessage: "Local Codex state unavailable",
                lastUpdatedAt: .now,
                errorMessage: nil,
                approvalRequest: nil
            )
        }

        let threadSnapshots = fetchRecentThreadSnapshots(limit: recentThreadLimit)
        guard !threadSnapshots.isEmpty else {
            return ActivitySourceSnapshot(
                sessions: [],
                statusMessage: "Waiting for Codex activity",
                lastUpdatedAt: .now,
                errorMessage: nil,
                approvalRequest: nil
            )
        }

        var sessions: [AgentSessionSnapshot] = []
        var newestApprovalRequest: ApprovalRequest?
        let globalState = fetchGlobalState()

        for threadSnapshot in threadSnapshots {
            let sessionFileURL = fetchSessionFileURL(for: threadSnapshot.threadID)
            let sessionMeta = sessionFileURL.flatMap(fetchSessionMeta(from:))
            let sessionHints = sessionFileURL.flatMap(fetchSessionActivityHints(from:))
            let terminalClient = detectTerminalClient(for: threadSnapshot.threadID)
            let resolvedCWD = resolvedWorkingDirectory(sessionMeta: sessionMeta, threadSnapshot: threadSnapshot)
            let hasActiveWorkspaceMatch = hasActiveWorkspaceMatch(cwd: resolvedCWD, globalState: globalState)
            let shouldPreferDesktopOrigin = hasActiveWorkspaceMatch && threadSnapshot.threadSource == "vscode"
            let focusTarget = makeFocusTarget(
                threadID: threadSnapshot.threadID,
                sessionMeta: sessionMeta,
                fallbackSource: threadSnapshot.threadSource,
                fallbackCWD: resolvedCWD,
                terminalClient: terminalClient,
                preferDesktopOrigin: shouldPreferDesktopOrigin
            )
            let approvalRequest = sessionFileURL.flatMap { fetchPendingApproval(in: $0, focusTarget: focusTarget) }
            let activityState = approvalRequest != nil ? .running : deriveActivityState(from: threadSnapshot, sessionHints: sessionHints)
            let updatedAt = Date(timeIntervalSince1970: max(threadSnapshot.threadUpdatedAt, sessionHints?.latestKnownAt ?? 0))
            let freshness = sessionFreshness(
                activityState: activityState,
                updatedAt: updatedAt,
                focusTarget: focusTarget
            )
            let clientOrigin = focusTarget?.clientOrigin
            let isUnavailableDesktopSession = if let clientOrigin,
                                                clientOrigin == .codexDesktop || clientOrigin == .codexVSCode {
                !isClientRunning(clientOrigin) && !hasActiveWorkspaceMatch
            } else {
                false
            }
            let hasExplicitOrigin = if let sessionMeta {
                sessionMeta.originDescription != "Local Codex"
            } else {
                threadSnapshot.threadSource == "vscode" || threadSnapshot.threadSource == "cli"
            }
            let isPresentableSession = approvalRequest != nil
                || focusTarget != nil
                || !resolvedCWD.isEmpty
                || hasExplicitOrigin

            if isUnavailableDesktopSession {
                continue
            }

            if !isPresentableSession {
                continue
            }

            if let approvalRequest,
               newestApprovalRequest == nil || approvalRequest.createdAt > newestApprovalRequest!.createdAt {
                newestApprovalRequest = approvalRequest
            }

            let shouldIncludeSession = approvalRequest != nil
                || activityState != .idle
                || shouldRetainIdleSession(
                    updatedAt: updatedAt,
                    focusTarget: focusTarget,
                    hasWorkingDirectory: !resolvedCWD.isEmpty,
                    hasActiveWorkspaceMatch: hasActiveWorkspaceMatch
                )
            guard shouldIncludeSession else {
                continue
            }

            let detail = !resolvedCWD.isEmpty
                ? resolvedCWD
                : "Watching local Codex activity"

            sessions.append(
                AgentSessionSnapshot(
                    id: threadSnapshot.threadID,
                    origin: .codex,
                    title: sessionTitle(
                        sessionMeta: sessionMeta,
                        fallbackSource: threadSnapshot.threadSource,
                        terminalClient: terminalClient,
                        preferDesktopOrigin: shouldPreferDesktopOrigin
                    ),
                    detail: detail,
                    activityState: activityState,
                    updatedAt: updatedAt,
                    cwd: resolvedCWD.isEmpty ? nil : resolvedCWD,
                    focusTarget: focusTarget,
                    freshness: freshness
                )
            )
        }

        let knownThreadIDs = Set(threadSnapshots.map(\.threadID))
        sessions.append(contentsOf: fetchFallbackCLISessions(excluding: knownThreadIDs))

        let lastUpdatedAt = sessions.map(\.updatedAt).max() ?? .now
        let statusMessage: String
        if sessions.isEmpty {
            statusMessage = "Waiting for Codex activity"
        } else if sessions.count > 1 {
            statusMessage = "Watching \(sessions.count) local Codex sessions"
        } else {
            statusMessage = "Watching local Codex activity"
        }

        return ActivitySourceSnapshot(
            sessions: sessions,
            statusMessage: statusMessage,
            lastUpdatedAt: lastUpdatedAt,
            errorMessage: nil,
            approvalRequest: newestApprovalRequest
        )
    }

    func fetchLatestApprovalRequest() -> ApprovalRequest? {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return nil
        }

        let threadReferences = fetchRecentThreadReferences(limit: 4)
        guard !threadReferences.isEmpty else {
            return nil
        }

        let globalState = fetchGlobalState()
        var newestApprovalRequest: ApprovalRequest?

        for threadReference in threadReferences {
            let sessionFileURL = fetchSessionFileURL(for: threadReference.threadID)
            let sessionMeta = sessionFileURL.flatMap(fetchSessionMeta(from:))
            let terminalClient = detectTerminalClient(for: threadReference.threadID)
            let resolvedCWD = resolvedWorkingDirectory(sessionMeta: sessionMeta, fallbackCWD: threadReference.cwd)
            let hasActiveWorkspaceMatch = hasActiveWorkspaceMatch(cwd: resolvedCWD, globalState: globalState)
            let shouldPreferDesktopOrigin = hasActiveWorkspaceMatch && threadReference.threadSource == "vscode"
            let focusTarget = makeFocusTarget(
                threadID: threadReference.threadID,
                sessionMeta: sessionMeta,
                fallbackSource: threadReference.threadSource,
                fallbackCWD: resolvedCWD,
                terminalClient: terminalClient,
                preferDesktopOrigin: shouldPreferDesktopOrigin
            )

            guard let sessionFileURL,
                  let approvalRequest = fetchPendingApproval(in: sessionFileURL, focusTarget: focusTarget) else {
                continue
            }

            if newestApprovalRequest == nil || approvalRequest.createdAt > newestApprovalRequest!.createdAt {
                newestApprovalRequest = approvalRequest
            }
        }

        return newestApprovalRequest
    }

    private func deriveActivityState(
        from snapshot: LocalCodexThreadSnapshot,
        sessionHints: LocalCodexSessionActivityHints?
    ) -> IslandCodexActivityState {
        let now = Date().timeIntervalSince1970
        let latestCompletionAt = max(snapshot.completedAt, sessionHints?.taskCompletedAt ?? 0)
        let latestFailureAt = max(snapshot.failedAt, sessionHints?.taskFailedAt ?? 0)
        let latestTerminalAt = max(latestCompletionAt, latestFailureAt)
        let latestExplicitRunningAt = max(
            snapshot.inProgressAt,
            snapshot.turnActivityAt,
            snapshot.streamingActivityAt,
            sessionHints?.taskStartedAt ?? 0
        )

        if latestFailureAt > 0,
           now - latestFailureAt <= terminalStatusHold,
           latestFailureAt >= latestCompletionAt,
           latestFailureAt >= latestExplicitRunningAt {
            return .failure
        }

        if latestCompletionAt > 0,
           now - latestCompletionAt >= successSettleDelay,
           now - latestCompletionAt <= terminalStatusHold,
           latestCompletionAt >= latestFailureAt,
           latestCompletionAt >= latestExplicitRunningAt {
            return .success
        }

        if latestExplicitRunningAt > 0,
           now - latestExplicitRunningAt <= runningSignalMaxAge,
           latestExplicitRunningAt >= latestTerminalAt {
            return .running
        }

        return .idle
    }

    private func fetchRecentThreadSnapshots(limit: Int) -> [LocalCodexThreadSnapshot] {
        fetchRecentThreadReferences(limit: limit).compactMap(makeThreadSnapshot(from:))
    }

    private func fetchRecentThreadReferences(limit: Int) -> [RecentThreadReference] {
        let latestThreadSQL = """
        select id || '|' || updated_at || '|' || source || '|' || cwd
        from threads
        where archived = 0
        order by updated_at desc
        limit \(limit);
        """

        guard
            let latestThreadRows = runSQLiteRows(databaseURL: stateDatabaseURL, sql: latestThreadSQL),
            !latestThreadRows.isEmpty
        else {
            return []
        }

        return latestThreadRows.compactMap(makeThreadReference(from:))
    }

    private func makeThreadReference(from row: String) -> RecentThreadReference? {
        let threadParts = row.split(separator: "|", omittingEmptySubsequences: false)
        guard threadParts.count >= 4 else {
            return nil
        }

        return RecentThreadReference(
            threadID: String(threadParts[0]),
            threadUpdatedAt: TimeInterval(threadParts[1]) ?? 0,
            threadSource: String(threadParts[2]),
            cwd: String(threadParts[3])
        )
    }

    private func makeThreadSnapshot(from reference: RecentThreadReference) -> LocalCodexThreadSnapshot? {
        let threadID = reference.threadID
        let threadUpdatedAt = reference.threadUpdatedAt
        let threadSource = reference.threadSource
        let threadCWD = reference.cwd
        let escapedThreadID = threadID.replacingOccurrences(of: "'", with: "''")
        let logsSQL = """
        select
            coalesce(max(case when feedback_log_body like '%"status":"in_progress"%' then ts end), 0),
            coalesce(max(case when feedback_log_body like '%response.completed%' then ts end), 0),
            coalesce(max(case when feedback_log_body like '%response.failed%' then ts end), 0),
            coalesce(max(case when level in ('ERROR', 'WARN') and (feedback_log_body like '%failed%' or feedback_log_body like '%error%' or feedback_log_body like '%last_error%') then ts end), 0),
            coalesce(max(case when feedback_log_body like '%session_task.turn%' or feedback_log_body like '%submission_dispatch%' then ts end), 0),
            coalesce(max(case
                when feedback_log_body like '%response.output_text.delta%'
                  or feedback_log_body like '%response.function_call_arguments.delta%'
                  or feedback_log_body like '%response.output_item.added%'
                then ts end), 0)
        from logs
        where thread_id = '\(escapedThreadID)';
        """

        guard
            let logRow = runSQLiteQuery(databaseURL: logsDatabaseURL, sql: logsSQL),
            !logRow.isEmpty
        else {
            return LocalCodexThreadSnapshot(
                threadID: threadID,
                threadUpdatedAt: threadUpdatedAt,
                threadSource: threadSource,
                cwd: threadCWD,
                inProgressAt: 0,
                completedAt: 0,
                failedAt: 0,
                turnActivityAt: 0,
                streamingActivityAt: 0
            )
        }

        let logParts = logRow.split(separator: "|", omittingEmptySubsequences: false)
        guard logParts.count == 6 else {
            return LocalCodexThreadSnapshot(
                threadID: threadID,
                threadUpdatedAt: threadUpdatedAt,
                threadSource: threadSource,
                cwd: threadCWD,
                inProgressAt: 0,
                completedAt: 0,
                failedAt: 0,
                turnActivityAt: 0,
                streamingActivityAt: 0
            )
        }

        let explicitFailureAt = TimeInterval(logParts[2]) ?? 0
        let errorFailureAt = TimeInterval(logParts[3]) ?? 0

        return LocalCodexThreadSnapshot(
            threadID: threadID,
            threadUpdatedAt: threadUpdatedAt,
            threadSource: threadSource,
            cwd: threadCWD,
            inProgressAt: TimeInterval(logParts[0]) ?? 0,
            completedAt: TimeInterval(logParts[1]) ?? 0,
            failedAt: max(explicitFailureAt, errorFailureAt),
            turnActivityAt: TimeInterval(logParts[4]) ?? 0,
            streamingActivityAt: TimeInterval(logParts[5]) ?? 0
        )
    }

    private func fetchSessionFileURL(for threadID: String) -> URL? {
        sessionFileLocator.fileURL(for: threadID)
    }

    private func fetchSessionMeta(from fileURL: URL) -> LocalCodexSessionMeta? {
        guard
            let firstLine = readFirstLine(from: fileURL),
            let data = firstLine.data(using: .utf8),
            let record = try? JSONDecoder().decode(LocalCodexSessionMetaRecord.self, from: data)
        else {
            return nil
        }

        return LocalCodexSessionMeta(
            cwd: record.payload.cwd,
            originator: record.payload.originator,
            source: record.payload.source
        )
    }

    private func fetchGlobalState() -> LocalCodexGlobalState? {
        guard
            let data = try? Data(contentsOf: globalStateURL),
            let state = try? JSONDecoder().decode(LocalCodexGlobalState.self, from: data)
        else {
            return nil
        }

        return state
    }

    private func readFirstLine(from fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        var data = Data()
        while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                data.append(chunk.prefix(upTo: newlineIndex))
                break
            }

            data.append(chunk)

            if data.count >= 1_000_000 {
                break
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readRecentLines(from fileURL: URL, maxBytes: Int) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }

        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return []
        }

        let byteCount = UInt64(max(1, maxBytes))
        let startOffset = fileSize > byteCount ? fileSize - byteCount : 0

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return []
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let trimmedText: Substring
        if startOffset > 0, let newlineIndex = text.firstIndex(of: "\n") {
            trimmedText = text[text.index(after: newlineIndex)...]
        } else {
            trimmedText = text[...]
        }

        return trimmedText.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func makeFocusTarget(
        threadID: String,
        sessionMeta: LocalCodexSessionMeta?,
        fallbackSource: String,
        fallbackCWD: String,
        terminalClient: TerminalClient?,
        preferDesktopOrigin: Bool
    ) -> FocusTarget? {
        let resolvedCWD = resolvedWorkingDirectory(sessionMeta: sessionMeta, fallbackCWD: fallbackCWD)
        let clientOrigin: FocusClientOrigin
        if preferDesktopOrigin || sessionMeta?.originator == "Codex Desktop" {
            clientOrigin = .codexDesktop
        } else if sessionMeta?.originator == "codex_cli_rs" || sessionMeta?.source == "cli" || fallbackSource == "cli" {
            clientOrigin = .codexCLI
        } else if sessionMeta?.originator == "codex_vscode" || sessionMeta?.source == "vscode" || fallbackSource == "vscode" {
            clientOrigin = .codexVSCode
        } else {
            clientOrigin = .unknown
        }

        guard clientOrigin != .unknown || !resolvedCWD.isEmpty else {
            return nil
        }

        return FocusTarget(
            clientOrigin: clientOrigin,
            sessionID: threadID,
            displayName: focusTargetLabel(for: clientOrigin, terminalClient: terminalClient),
            cwd: resolvedCWD.isEmpty ? nil : resolvedCWD,
            terminalClient: clientOrigin == .codexCLI ? terminalClient : nil
        )
    }

    private func runSQLiteRows(databaseURL: URL, sql: String) -> [String]? {
        let output = runSQLiteQuery(databaseURL: databaseURL, sql: sql)
        let rows = output?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        return rows.isEmpty ? nil : rows
    }

    private func runSQLiteQuery(databaseURL: URL, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, "-separator", "|", sql]

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

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchPendingApproval(in fileURL: URL, focusTarget: FocusTarget?) -> ApprovalRequest? {
        let recentLines = readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes)
        guard !recentLines.isEmpty else {
            return nil
        }

        var pendingCalls: [String: PendingApprovalPayload] = [:]

        for line in recentLines {
            guard let data = String(line).data(using: .utf8) else {
                continue
            }

            guard
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = record["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String
            else {
                continue
            }

            if payloadType == "function_call_output",
               let callID = payload["call_id"] as? String {
                pendingCalls.removeValue(forKey: callID)
                continue
            }

            guard payloadType == "function_call" else {
                continue
            }

            guard
                let callID = payload["call_id"] as? String,
                let argumentString = payload["arguments"] as? String,
                let argumentsData = argumentString.data(using: .utf8),
                let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any],
                let sandboxPermissions = arguments["sandbox_permissions"] as? String,
                sandboxPermissions == "require_escalated"
            else {
                continue
            }

            let timestampString = record["timestamp"] as? String
            let timestamp = timestampString.flatMap(iso8601Formatter.date(from:)) ?? .now
            let command = arguments["command"] as? String ?? ""
            let justification = arguments["justification"] as? String

            pendingCalls[callID] = PendingApprovalPayload(
                callID: callID,
                command: command,
                justification: justification,
                timestamp: timestamp
            )
        }

        guard let latestPending = pendingCalls.values.max(by: { $0.timestamp < $1.timestamp }) else {
            return nil
        }

        return ApprovalRequest(
            id: latestPending.callID,
            commandSummary: summarizeCommand(latestPending.command),
            rationale: latestPending.justification,
            focusTarget: focusTarget,
            createdAt: latestPending.timestamp,
            source: .codex,
            resolutionKind: .accessibilityAutomation
        )
    }

    private func summarizeCommand(_ command: String) -> String {
        let singleLine = command
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLine.count > 96 else {
            return singleLine
        }

        return String(singleLine.prefix(96)) + "..."
    }

    private func fetchSessionActivityHints(from fileURL: URL) -> LocalCodexSessionActivityHints? {
        let recentLines = readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes)
        guard !recentLines.isEmpty else {
            return nil
        }

        var taskStartedAt: Date?
        var taskCompletedAt: Date?
        var taskFailedAt: Date?

        for line in recentLines {
            guard let data = String(line).data(using: .utf8) else {
                continue
            }

            guard
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = record["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String
            else {
                continue
            }

            let timestampString = record["timestamp"] as? String
            let timestamp = timestampString.flatMap(iso8601Formatter.date(from:)) ?? .now

            switch payloadType {
            case "task_started":
                taskStartedAt = timestamp
            case "task_complete", "response.completed":
                taskCompletedAt = timestamp
            case "task_failed", "response.failed":
                taskFailedAt = timestamp
            default:
                continue
            }
        }

        guard taskStartedAt != nil || taskCompletedAt != nil || taskFailedAt != nil else {
            return nil
        }

        return LocalCodexSessionActivityHints(
            taskStartedAt: taskStartedAt?.timeIntervalSince1970 ?? 0,
            taskCompletedAt: taskCompletedAt?.timeIntervalSince1970 ?? 0,
            taskFailedAt: taskFailedAt?.timeIntervalSince1970 ?? 0
        )
    }

    private func fetchFallbackCLISessions(excluding threadIDs: Set<String>) -> [AgentSessionSnapshot] {
        guard isClientRunning(.codexCLI) else {
            return []
        }

        guard let content = try? String(contentsOf: tuiLogURL, encoding: .utf8) else {
            return []
        }

        let now = Date().timeIntervalSince1970
        var snapshots: [String: TUILogThreadSnapshot] = [:]

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let stringLine = String(line)
            guard let timestamp = parseLogTimestamp(from: stringLine) else {
                continue
            }

            guard let threadID = extractThreadID(from: stringLine) else {
                continue
            }

            guard !threadIDs.contains(threadID) else {
                continue
            }

            var snapshot = snapshots[threadID] ?? TUILogThreadSnapshot(threadID: threadID)
            snapshot.lastSeenAt = max(snapshot.lastSeenAt, timestamp)

            if stringLine.contains("session_task.turn") {
                snapshot.lastTurnAt = max(snapshot.lastTurnAt, timestamp)
            }

            if stringLine.contains("Shutting down Codex instance")
                || stringLine.contains("op.dispatch.shutdown")
                || (stringLine.contains("session_loop{thread_id=") && stringLine.contains("codex_core::codex: close")) {
                snapshot.shutdownAt = max(snapshot.shutdownAt, timestamp)
            }

            snapshots[threadID] = snapshot
        }

        return snapshots.values.compactMap { snapshot in
            guard now - snapshot.lastSeenAt <= fallbackTUILookback else {
                return nil
            }

            if snapshot.shutdownAt > 0, snapshot.shutdownAt >= snapshot.lastSeenAt {
                return nil
            }

            let activityState: IslandCodexActivityState
            if snapshot.lastTurnAt > 0, now - snapshot.lastTurnAt <= runningSignalMaxAge {
                activityState = .running
            } else {
                activityState = .idle
            }
            let updatedAt = Date(timeIntervalSince1970: snapshot.lastSeenAt)
            let freshness: SessionFreshness
            if activityState == .idle, now - snapshot.lastSeenAt >= staleSessionThreshold {
                freshness = .stale
            } else {
                freshness = .live
            }

            let terminalClient = detectTerminalClient(for: snapshot.threadID)
            let title = "\(terminalClient?.displayName ?? TerminalClient.unknown.displayName) Codex"
            let focusLabel = focusTargetLabel(for: .codexCLI, terminalClient: terminalClient)
            let detail = freshness == .stale
                ? "No recent session updates. The terminal may have been closed."
                : "Watching local Codex CLI session"

            return AgentSessionSnapshot(
                id: snapshot.threadID,
                origin: .codex,
                title: title,
                detail: detail,
                activityState: activityState,
                updatedAt: updatedAt,
                cwd: nil,
                focusTarget: FocusTarget(
                    clientOrigin: .codexCLI,
                    sessionID: snapshot.threadID,
                    displayName: focusLabel,
                    cwd: nil,
                    terminalClient: terminalClient
                ),
                freshness: freshness
            )
        }
    }

    private func sessionTitle(
        sessionMeta: LocalCodexSessionMeta?,
        fallbackSource: String,
        terminalClient: TerminalClient?,
        preferDesktopOrigin: Bool
    ) -> String {
        if sessionMeta?.originator == "codex_cli_rs" || sessionMeta?.source == "cli" || fallbackSource == "cli" {
            return "\(terminalClient?.displayName ?? TerminalClient.unknown.displayName) Codex"
        }

        if preferDesktopOrigin {
            return "Codex Desktop"
        }

        if let sessionMeta {
            return sessionMeta.originDescription
        }

        if fallbackSource == "vscode" {
            return "VS Code Codex"
        }

        return "Local Codex"
    }

    private func focusTargetLabel(for origin: FocusClientOrigin, terminalClient: TerminalClient?) -> String {
        if origin == .codexCLI {
            return "\(terminalClient?.displayName ?? TerminalClient.unknown.displayName) Codex"
        }

        return origin.displayName
    }

    private func shouldRetainIdleSession(
        updatedAt: Date,
        focusTarget: FocusTarget?,
        hasWorkingDirectory: Bool,
        hasActiveWorkspaceMatch: Bool
    ) -> Bool {
        let idleAge = Date().timeIntervalSince(updatedAt)

        if let focusTarget {
            switch focusTarget.clientOrigin {
            case .claudeVSCode, .codexDesktop, .codexVSCode:
                return isClientRunning(focusTarget.clientOrigin)
                    || hasActiveWorkspaceMatch
                    || idleAge <= unconfirmedDesktopSessionLookback
            case .claudeCLI, .codexCLI, .unknown:
                break
            }
        }

        guard idleAge <= idleSessionLookback else {
            return false
        }

        if hasWorkingDirectory {
            return true
        }

        guard let focusTarget else {
            return false
        }

        switch focusTarget.clientOrigin {
        case .claudeCLI, .codexCLI:
            return isClientRunning(.codexCLI)
        case .claudeVSCode, .codexDesktop, .codexVSCode:
            return isClientRunning(focusTarget.clientOrigin) || hasActiveWorkspaceMatch
        case .unknown:
            return true
        }
    }

    private func hasActiveWorkspaceMatch(cwd: String, globalState: LocalCodexGlobalState?) -> Bool {
        let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCWD.isEmpty else {
            return false
        }

        return globalState?.activeWorkspaceRoots.contains(where: { root in
            normalizedCWD == root || normalizedCWD.hasPrefix(root + "/")
        }) ?? false
    }

    private func resolvedWorkingDirectory(sessionMeta: LocalCodexSessionMeta?, threadSnapshot: LocalCodexThreadSnapshot) -> String {
        resolvedWorkingDirectory(sessionMeta: sessionMeta, fallbackCWD: threadSnapshot.cwd)
    }

    private func resolvedWorkingDirectory(sessionMeta: LocalCodexSessionMeta?, fallbackCWD: String) -> String {
        let primaryCWD = sessionMeta?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primaryCWD.isEmpty {
            return primaryCWD
        }

        return fallbackCWD.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionFreshness(
        activityState: IslandCodexActivityState,
        updatedAt: Date,
        focusTarget: FocusTarget?
    ) -> SessionFreshness {
        guard activityState == .idle else {
            return .live
        }

        guard Date().timeIntervalSince(updatedAt) >= staleSessionThreshold else {
            return .live
        }

        guard focusTarget?.clientOrigin == .codexCLI else {
            return .live
        }

        return .stale
    }

    private func detectTerminalClient(for threadID: String) -> TerminalClient? {
        guard let shellSnapshotURL = latestShellSnapshotURL(for: threadID),
              let shellSnapshot = try? String(contentsOf: shellSnapshotURL, encoding: .utf8) else {
            return nil
        }

        if shellSnapshot.contains("export TERM_PROGRAM=WarpTerminal")
            || shellSnapshot.contains("export WARP_IS_LOCAL_SHELL_SESSION=1") {
            return .warp
        }

        if shellSnapshot.contains("export TERM_PROGRAM=iTerm.app")
            || shellSnapshot.contains("export ITERM_SESSION_ID=") {
            return .iTerm
        }

        if shellSnapshot.contains("export TERM_PROGRAM=Apple_Terminal")
            || shellSnapshot.contains("export TERM_SESSION_ID=") {
            return .terminal
        }

        if shellSnapshot.contains("export TERM_PROGRAM=WezTerm")
            || shellSnapshot.contains("export WEZTERM_EXECUTABLE=") {
            return .wezTerm
        }

        if shellSnapshot.contains("export TERM_PROGRAM=ghostty")
            || shellSnapshot.contains("export GHOSTTY_RESOURCES_DIR=") {
            return .ghostty
        }

        if shellSnapshot.contains("export TERM_PROGRAM=Alacritty")
            || shellSnapshot.contains("export ALACRITTY_SOCKET=") {
            return .alacritty
        }

        return nil
    }

    private func latestShellSnapshotURL(for threadID: String) -> URL? {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: shellSnapshotsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return fileURLs
            .filter { $0.lastPathComponent.hasPrefix(threadID + ".") && $0.pathExtension == "sh" }
            .max { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate < rightDate
            }
    }

    private func parseLogTimestamp(from line: String) -> TimeInterval? {
        guard let timestampEnd = line.firstIndex(of: " ") else {
            return nil
        }

        let timestampString = String(line[..<timestampEnd])
        return iso8601Formatter.date(from: timestampString)?.timeIntervalSince1970
    }

    private func extractThreadID(from line: String) -> String? {
        guard let startRange = line.range(of: "thread_id=") else {
            return nil
        }

        let suffix = line[startRange.upperBound...]
        let threadID = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }

        return threadID.isEmpty ? nil : String(threadID)
    }

    private func isClientRunning(_ origin: FocusClientOrigin) -> Bool {
        let bundleIdentifiers: [String]
        switch origin {
        case .claudeCLI:
            bundleIdentifiers = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm", "com.mitchellh.ghostty", "org.alacritty"]
        case .claudeVSCode:
            bundleIdentifiers = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
        case .codexDesktop:
            bundleIdentifiers = ["com.openai.codex"]
        case .codexVSCode:
            bundleIdentifiers = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
        case .codexCLI:
            bundleIdentifiers = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm", "com.mitchellh.ghostty", "org.alacritty"]
        case .unknown:
            bundleIdentifiers = []
        }

        guard !bundleIdentifiers.isEmpty else {
            return false
        }

        return NSWorkspace.shared.runningApplications.contains { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }
            return bundleIdentifiers.contains(bundleIdentifier)
        }
    }
}

private final class SessionFileLocator: @unchecked Sendable {
    private let rootURL: URL
    private let searchLookbackDays = 45
    private let lock = NSLock()
    private var cache: [String: URL] = [:]

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func fileURL(for threadID: String) -> URL? {
        lock.lock()
        if let cachedURL = cache[threadID], FileManager.default.fileExists(atPath: cachedURL.path) {
            lock.unlock()
            return cachedURL
        }
        lock.unlock()

        let resolvedURL = searchRecentDays(for: threadID)

        lock.lock()
        cache[threadID] = resolvedURL
        lock.unlock()

        return resolvedURL
    }

    private func searchRecentDays(for threadID: String) -> URL? {
        let calendar = Calendar.current
        let candidateDates = (0 ..< searchLookbackDays).compactMap { dayOffset -> Date? in
            calendar.date(byAdding: .day, value: -dayOffset, to: .now)
        }

        for date in candidateDates {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard
                let year = components.year,
                let month = components.month,
                let day = components.day
            else {
                continue
            }

            let dayDirectory = rootURL
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))

            guard let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }

            if let matchingFileURL = fileURLs.first(where: {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(threadID)
            }) {
                return matchingFileURL
            }
        }

        return nil
    }
}

private struct LocalCodexThreadSnapshot {
    let threadID: String
    let threadUpdatedAt: TimeInterval
    let threadSource: String
    let cwd: String
    let inProgressAt: TimeInterval
    let completedAt: TimeInterval
    let failedAt: TimeInterval
    let turnActivityAt: TimeInterval
    let streamingActivityAt: TimeInterval
}

private struct RecentThreadReference {
    let threadID: String
    let threadUpdatedAt: TimeInterval
    let threadSource: String
    let cwd: String
}

private struct LocalCodexSessionMeta {
    let cwd: String
    let originator: String
    let source: String

    var originDescription: String {
        if originator == "Codex Desktop" {
            return "Codex Desktop"
        }
        if originator == "codex_cli_rs" || source == "cli" {
            return "Terminal Codex"
        }
        if originator == "codex_vscode" || source == "vscode" {
            return "VS Code Codex"
        }
        return "Local Codex"
    }
}

private struct LocalCodexSessionMetaRecord: Decodable {
    struct Payload: Decodable {
        let cwd: String
        let originator: String
        let source: String
    }

    let payload: Payload
}

private struct LocalCodexGlobalState: Decodable {
    let activeWorkspaceRoots: [String]

    private enum CodingKeys: String, CodingKey {
        case activeWorkspaceRoots = "active-workspace-roots"
    }
}

private struct PendingApprovalPayload {
    let callID: String
    let command: String
    let justification: String?
    let timestamp: Date
}

private struct LocalCodexSessionActivityHints {
    let taskStartedAt: TimeInterval
    let taskCompletedAt: TimeInterval
    let taskFailedAt: TimeInterval

    var latestKnownAt: TimeInterval {
        max(taskStartedAt, taskCompletedAt, taskFailedAt)
    }
}

private struct TUILogThreadSnapshot {
    let threadID: String
    var lastSeenAt: TimeInterval = 0
    var lastTurnAt: TimeInterval = 0
    var shutdownAt: TimeInterval = 0
}

final class LocalClaudeSource: @unchecked Sendable {
    private let bridge = ClaudeHookBridge.shared

    func bootstrap() {
        bridge.start()
        bridge.syncHooks()
    }

    func resyncHooks() {
        bridge.start()
        bridge.syncHooks()
    }

    func fetchActivity() -> ActivitySourceSnapshot {
        bridge.activitySnapshot()
    }

    func fetchLatestApprovalRequest() -> ApprovalRequest? {
        bridge.latestApprovalRequest()
    }

    func resolveApproval(id: String, decision: ApprovalDecision) -> Bool {
        bridge.resolveApproval(id: id, decision: decision)
    }
}

private final class ClaudeHookBridge: @unchecked Sendable {
    static let shared = ClaudeHookBridge()

    private let queue = DispatchQueue(label: "HermitFlow.claudeHookBridge")
    private let listenerQueue = DispatchQueue(label: "HermitFlow.claudeHookListener")
    private let listenerPort: UInt16 = 46821
    private let sessionStaleThreshold: TimeInterval = 10 * 60
    private let approvalTimeout: TimeInterval = 90
    private let successDisplayHold: TimeInterval = 1.25
    private let failureDisplayHold: TimeInterval = 2.0
    private let trailingRunningIgnoreWindow: TimeInterval = 2.0
    private let hookRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-hooks")
    private let defaultSettingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    private let customSettingsPathsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-settings-paths.json")
    private let customSettingsPathsEnvironmentKey = "HERMITFLOW_CLAUDE_SETTINGS_PATHS"
    private let hookScriptName = "hermit-claude-hook.js"
    private let hookMarker = "hermit-claude-hook.js"
    private let permissionHookPath = "/permission/hermitflow"

    private var listener: NWListener?
    private var sessions: [String: ClaudeTrackedSession] = [:]
    private var approvals: [String: ClaudePendingApproval] = [:]
    private var approvalOrder: [String] = []
    private var lastErrorMessage: String?

    func start() {
        queue.sync {
            guard listener == nil else {
                return
            }

            do {
                let port = NWEndpoint.Port(rawValue: listenerPort) ?? .any
                let listener = try NWListener(using: .tcp, on: port)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection: connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.start(queue: listenerQueue)
                self.listener = listener
            } catch {
                lastErrorMessage = "Claude hook listener unavailable"
            }
        }
    }

    func syncHooks() {
        do {
            try writeHookScriptIfNeeded()
            try syncClaudeSettings()
            queue.sync {
                lastErrorMessage = nil
            }
        } catch {
            queue.sync {
                lastErrorMessage = "Claude hook setup failed: \(describeClaudeHookConfigurationError(error))"
            }
        }
    }

    func activitySnapshot() -> ActivitySourceSnapshot {
        queue.sync {
            cleanupExpiredState(now: .now)
            let sessions = makeSnapshots()
            let lastUpdatedAt = sessions.map(\.updatedAt).max() ?? .now
            let statusMessage: String
            if sessions.isEmpty {
                statusMessage = "Waiting for Claude Code activity"
            } else if sessions.count == 1 {
                statusMessage = "Watching Claude Code activity"
            } else {
                statusMessage = "Watching \(sessions.count) Claude Code sessions"
            }

            return ActivitySourceSnapshot(
                sessions: sessions,
                statusMessage: statusMessage,
                lastUpdatedAt: lastUpdatedAt,
                errorMessage: lastErrorMessage,
                approvalRequest: latestApprovalRequestLocked()
            )
        }
    }

    func latestApprovalRequest() -> ApprovalRequest? {
        queue.sync {
            cleanupExpiredState(now: .now)
            return latestApprovalRequestLocked()
        }
    }

    func resolveApproval(id: String, decision: ApprovalDecision) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let approval = approvals.removeValue(forKey: id) else {
                approvalOrder.removeAll { $0 == id }
                return false
            }

            approvalOrder.removeAll { $0 == id }

            let response = makePermissionDecision(for: decision)
            sendHTTPResponse(
                status: 200,
                body: response,
                contentType: "application/json",
                on: approval.connection
            )
            return true
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        queue.sync {
            switch state {
            case .ready:
                lastErrorMessage = nil
            case let .failed(error):
                lastErrorMessage = "Claude hook listener failed: \(error.localizedDescription)"
                listener?.cancel()
                listener = nil
            default:
                break
            }
        }
    }

    private func accept(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }

            if case .ready = state {
                self.readRequest(on: connection, buffer: Data())
            } else if case .failed = state {
                self.cleanupConnection(connection)
            } else if case .cancelled = state {
                self.cleanupConnection(connection)
            }
        }
        connection.start(queue: listenerQueue)
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if error != nil {
                self.cleanupConnection(connection)
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let request = self.parseRequest(from: accumulated) {
                self.handle(request: request, on: connection)
                return
            }

            if isComplete {
                self.sendHTTPResponse(status: 400, body: "bad request", contentType: "text/plain", on: connection)
                return
            }

            self.readRequest(on: connection, buffer: accumulated)
        }
    }

    private func handle(request: ParsedHTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/state"):
            let body = "{\"ok\":true,\"app\":\"HermitFlow\",\"port\":\(listenerPort)}"
            sendHTTPResponse(status: 200, body: body, contentType: "application/json", on: connection)
        case ("POST", "/state"):
            handleState(body: request.body, on: connection)
        case ("POST", "/permission"), ("POST", permissionHookPath):
            handlePermission(body: request.body, on: connection)
        default:
            sendHTTPResponse(status: 404, body: "not found", contentType: "text/plain", on: connection)
        }
    }

    private func handleState(body: Data, on connection: NWConnection) {
        guard let payload = try? JSONDecoder().decode(ClaudeHookEventPayload.self, from: body) else {
            sendHTTPResponse(status: 400, body: "bad json", contentType: "text/plain", on: connection)
            return
        }

        queue.sync {
            cleanupExpiredState(now: .now)
            let sessionID = payload.sessionID.isEmpty ? "default" : payload.sessionID

            if payload.event == "SessionEnd" {
                sessions.removeValue(forKey: sessionID)
                approvalOrder = approvalOrder.filter { approvalID in
                    approvals[approvalID]?.sessionID != sessionID
                }
                approvals = approvals.filter { _, approval in
                    approval.sessionID != sessionID
                }
            } else {
                let now = Date()
                sessions[sessionID] = mergedClaudeSession(
                    existing: sessions[sessionID],
                    payload: payload,
                    now: now
                )
            }
            lastErrorMessage = nil
        }

        sendHTTPResponse(status: 200, body: "ok", contentType: "text/plain", on: connection)
    }

    private func handlePermission(body: Data, on connection: NWConnection) {
        guard let payload = try? JSONDecoder().decode(ClaudeHookPermissionPayload.self, from: body) else {
            sendHTTPResponse(status: 400, body: "bad json", contentType: "text/plain", on: connection)
            return
        }

        queue.sync {
            cleanupExpiredState(now: .now)

            let requestID = UUID().uuidString
            let sessionID = payload.sessionID.isEmpty ? "default" : payload.sessionID
            let summary = summarizePermissionRequest(payload)
            let rationale = payload.permissionSuggestions?.isEmpty == false
                ? "Claude Code is waiting for a permission decision."
                : "Claude Code requested tool access."

            approvals[requestID] = ClaudePendingApproval(
                id: requestID,
                sessionID: sessionID,
                createdAt: .now,
                commandSummary: summary,
                rationale: rationale,
                connection: connection
            )
            approvalOrder.removeAll { $0 == requestID }
            approvalOrder.append(requestID)

            let existing = sessions[sessionID]
            sessions[sessionID] = ClaudeTrackedSession(
                rawSessionID: sessionID,
                cwd: existing?.cwd ?? "",
                source: existing?.source ?? payload.toolName,
                status: .running,
                lastEvent: "PermissionRequest",
                lastActivityAt: .now
            )
        }
    }

    private func cleanupConnection(_ connection: NWConnection) {
        queue.sync {
            let matchingIDs = approvals.compactMap { key, approval in
                approval.connection === connection ? key : nil
            }
            for id in matchingIDs {
                approvals.removeValue(forKey: id)
                approvalOrder.removeAll { $0 == id }
            }
        }
    }

    private func cleanupExpiredState(now: Date) {
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivityAt) <= sessionStaleThreshold
        }

        let expiredApprovalIDs = approvals.compactMap { key, approval in
            now.timeIntervalSince(approval.createdAt) > approvalTimeout ? key : nil
        }
        for id in expiredApprovalIDs {
            if let approval = approvals.removeValue(forKey: id) {
                let response = makePermissionDecision(for: .reject, message: "Approval timed out in HermitFlow")
                sendHTTPResponse(status: 200, body: response, contentType: "application/json", on: approval.connection)
            }
        }
        if !expiredApprovalIDs.isEmpty {
            approvalOrder.removeAll { expiredApprovalIDs.contains($0) }
        }
    }

    private func latestApprovalRequestLocked() -> ApprovalRequest? {
        for approvalID in approvalOrder.reversed() {
            guard let approval = approvals[approvalID] else {
                continue
            }

            return ApprovalRequest(
                id: approval.id,
                commandSummary: approval.commandSummary,
                rationale: approval.rationale,
                focusTarget: nil,
                createdAt: approval.createdAt,
                source: .claude,
                resolutionKind: .localHTTPHook
            )
        }

        return nil
    }

    private func makeSnapshots() -> [AgentSessionSnapshot] {
        sessions.values.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }.map { session in
            let resolvedStatus = resolvedStatus(for: session, now: .now)
            return AgentSessionSnapshot(
                id: "claude:\(session.rawSessionID)",
                origin: .claude,
                title: session.title,
                detail: session.detail,
                activityState: resolvedStatus.activityState,
                updatedAt: session.lastActivityAt,
                cwd: session.cwd.isEmpty ? nil : session.cwd,
                focusTarget: nil,
                freshness: .live
            )
        }
    }

    private func mergedClaudeSession(
        existing: ClaudeTrackedSession?,
        payload: ClaudeHookEventPayload,
        now: Date
    ) -> ClaudeTrackedSession {
        let incomingStatus = ClaudeTrackedSession.status(for: payload.event, state: payload.state)

        if let existing,
           incomingStatus == .running,
           existing.status == .idle,
           !ClaudeTrackedSession.isExplicitRunningEvent(payload.event) {
            return ClaudeTrackedSession(
                rawSessionID: existing.rawSessionID,
                cwd: payload.cwd.isEmpty ? existing.cwd : payload.cwd,
                source: payload.source.isEmpty ? existing.source : payload.source,
                status: .idle,
                lastEvent: existing.lastEvent,
                lastActivityAt: existing.lastActivityAt
            )
        }

        if let existing,
           incomingStatus == .running,
           existing.status.isTerminal,
           now.timeIntervalSince(existing.lastActivityAt) <= trailingRunningIgnoreWindow,
           ClaudeTrackedSession.isTrailingRunningEvent(payload.event) {
            return ClaudeTrackedSession(
                rawSessionID: existing.rawSessionID,
                cwd: payload.cwd.isEmpty ? existing.cwd : payload.cwd,
                source: payload.source.isEmpty ? existing.source : payload.source,
                status: existing.status,
                lastEvent: existing.lastEvent,
                lastActivityAt: existing.lastActivityAt
            )
        }

        return ClaudeTrackedSession(
            rawSessionID: existing?.rawSessionID ?? payload.sessionID,
            cwd: payload.cwd.isEmpty ? existing?.cwd ?? "" : payload.cwd,
            source: payload.source.isEmpty ? existing?.source ?? "" : payload.source,
            status: incomingStatus,
            lastEvent: payload.event,
            lastActivityAt: now
        )
    }

    private func resolvedStatus(for session: ClaudeTrackedSession, now: Date) -> ClaudeTrackedSession.Status {
        switch session.status {
        case .success:
            return now.timeIntervalSince(session.lastActivityAt) >= successDisplayHold ? .idle : .success
        case .failure:
            return now.timeIntervalSince(session.lastActivityAt) >= failureDisplayHold ? .idle : .failure
        case .idle, .running:
            return session.status
        }
    }

    private func summarizePermissionRequest(_ payload: ClaudeHookPermissionPayload) -> String {
        if payload.toolName == "Bash",
           let command = payload.toolInput?.command,
           !command.isEmpty {
            return summarizeCommand(command)
        }

        if let path = payload.toolInput?.filePath, !path.isEmpty {
            return "\(payload.toolName) · \(path)"
        }

        if let command = payload.toolInput?.command, !command.isEmpty {
            return "\(payload.toolName) · \(summarizeCommand(command))"
        }

        return payload.toolName
    }

    private func summarizeCommand(_ command: String) -> String {
        let singleLine = command
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLine.count > 96 else {
            return singleLine
        }

        return String(singleLine.prefix(96)) + "..."
    }

    private func makePermissionDecision(for decision: ApprovalDecision, message: String? = nil) -> String {
        let behavior: String
        switch decision {
        case .reject:
            behavior = "deny"
        case .accept, .acceptAll:
            behavior = "allow"
        }

        var decisionObject: [String: Any] = ["behavior": behavior]
        if let message, !message.isEmpty {
            decisionObject["message"] = message
        }

        let body: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObject
            ]
        ]

        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\"}}}"
    }

    private func sendHTTPResponse(status: Int, body: String, contentType: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status) \(httpStatusMessage(for: status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(bodyData)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func httpStatusMessage(for status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        default:
            return "Error"
        }
    }

    private func parseRequest(from data: Data) -> ParsedHTTPRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0 ..< separatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<colonIndex].lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = separatorRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = data.subdata(in: bodyStart ..< bodyStart + contentLength)
        return ParsedHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            body: body
        )
    }

    private func writeHookScriptIfNeeded() throws {
        try FileManager.default.createDirectory(at: hookRootURL, withIntermediateDirectories: true, attributes: nil)
        let scriptURL = hookRootURL.appendingPathComponent(hookScriptName)
        let content = """
        #!/usr/bin/env node
        const http = require("http");

        const EVENT_TO_STATE = {
          SessionStart: "idle",
          SessionEnd: "sleeping",
          UserPromptSubmit: "thinking",
          PreToolUse: "working",
          PostToolUse: "working",
          PostToolUseFailure: "error",
          StopFailure: "error",
          Stop: "attention",
          SubagentStart: "juggling",
          SubagentStop: "working",
          PreCompact: "sweeping",
          PostCompact: "attention",
          Notification: "notification",
          Elicitation: "notification",
          WorktreeCreate: "carrying"
        };

        const event = process.argv[2];
        if (!EVENT_TO_STATE[event]) process.exit(0);

        const chunks = [];
        let sent = false;

        process.stdin.on("data", (chunk) => chunks.push(chunk));
        process.stdin.on("end", send);
        setTimeout(send, 350);

        function send() {
          if (sent) return;
          sent = true;

          let payload = {};
          try {
            payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          } catch {}

          const body = JSON.stringify({
            event,
            state: EVENT_TO_STATE[event],
            session_id: payload.session_id || "default",
            cwd: payload.cwd || "",
            source: payload.source || payload.reason || ""
          });

          const req = http.request({
            hostname: "127.0.0.1",
            port: \(listenerPort),
            path: "/state",
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(body)
            },
            timeout: 500
          }, (res) => {
            res.resume();
            res.on("end", () => process.exit(0));
          });

          req.on("error", () => process.exit(0));
          req.on("timeout", () => {
            req.destroy();
            process.exit(0);
          });
          req.write(body);
          req.end();
        }
        """
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private func syncClaudeSettings() throws {
        let nodePath = resolveNodeBinary()
        let scriptPath = hookRootURL.appendingPathComponent(hookScriptName).path
        let commandEvents = [
            "SessionStart",
            "SessionEnd",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PostToolUseFailure",
            "StopFailure",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "PreCompact",
            "PostCompact",
            "Notification",
            "Elicitation",
            "WorktreeCreate"
        ]

        let permissionURL = "http://127.0.0.1:\(listenerPort)\(permissionHookPath)"
        let settingsURLs = try resolvedClaudeSettingsURLs()
        var syncedAnyFile = false
        var failures: [String] = []

        for settingsURL in settingsURLs {
            do {
                try syncClaudeSettings(
                    at: settingsURL,
                    nodePath: nodePath,
                    scriptPath: scriptPath,
                    commandEvents: commandEvents,
                    permissionURL: permissionURL
                )
                syncedAnyFile = true
            } catch {
                failures.append("\(settingsURL.path): \(describeClaudeHookConfigurationError(error))")
            }
        }

        if !failures.isEmpty {
            if syncedAnyFile {
                throw ClaudeHookConfigurationError.partialSyncFailed(failures)
            }
            throw ClaudeHookConfigurationError.syncFailed(failures)
        }
    }

    private func syncClaudeSettings(
        at settingsURL: URL,
        nodePath: String,
        scriptPath: String,
        commandEvents: [String],
        permissionURL: String
    ) throws {
        let fileManager = FileManager.default
        let settingsDirectoryURL = settingsURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let settings = try loadJSONObjectIfPresent(at: settingsURL) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in commandEvents {
            let command = "\"\(nodePath)\" \"\(scriptPath)\" \(event)"
            hooks[event] = upsertCommandHook(into: hooks[event], command: command)
        }

        hooks["PermissionRequest"] = upsertHTTPHook(into: hooks["PermissionRequest"], url: permissionURL)

        var updatedSettings = settings
        updatedSettings["hooks"] = hooks
        try writeJSONObject(updatedSettings, to: settingsURL)
    }

    private func resolvedClaudeSettingsURLs() throws -> [URL] {
        var urls: [URL] = [defaultSettingsURL]
        urls.append(contentsOf: try loadCustomSettingsURLs())
        urls.append(contentsOf: loadEnvironmentSettingsURLs())

        var seenPaths = Set<String>()
        return urls.filter { url in
            let standardizedPath = url.standardizedFileURL.path
            guard !standardizedPath.isEmpty, !seenPaths.contains(standardizedPath) else {
                return false
            }
            seenPaths.insert(standardizedPath)
            return true
        }
    }

    private func loadCustomSettingsURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: customSettingsPathsURL.path) else {
            return []
        }

        let data = try Data(contentsOf: customSettingsPathsURL)
        let object = try parseRelaxedJSONObjectData(data, sourcePath: customSettingsPathsURL.path)

        let rawPaths: [String]
        if let array = object as? [String] {
            rawPaths = array
        } else if let dictionary = object as? [String: Any],
                  let paths = dictionary["paths"] as? [String] {
            rawPaths = paths
        } else {
            throw ClaudeHookConfigurationError.invalidCustomSettingsPathsFile(customSettingsPathsURL.path)
        }

        return rawPaths.compactMap(expandedFileURL(from:))
    }

    private func loadEnvironmentSettingsURLs() -> [URL] {
        guard let rawValue = ProcessInfo.processInfo.environment[customSettingsPathsEnvironmentKey],
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return rawValue
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(expandedFileURL(from:))
    }

    private func parseRelaxedJSONObjectData(_ data: Data, sourcePath: String) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ClaudeHookConfigurationError.invalidCustomSettingsPathsFile(sourcePath)
        }

        let relaxedText = text.replacingOccurrences(
            of: ",(\\s*[\\]\\}])",
            with: "$1",
            options: .regularExpression
        )

        guard let relaxedData = relaxedText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: relaxedData) else {
            throw ClaudeHookConfigurationError.invalidCustomSettingsPathsFile(sourcePath)
        }

        return object
    }

    private func expandedFileURL(from rawPath: String) -> URL? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    private func loadJSONObjectIfPresent(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return [:]
        }

        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ClaudeHookConfigurationError.invalidSettingsRoot
        }
        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func upsertCommandHook(into existingValue: Any?, command: String) -> [[String: Any]] {
        var entries = (existingValue as? [[String: Any]]) ?? []
        var found = false

        for index in entries.indices {
            guard var hooks = entries[index]["hooks"] as? [[String: Any]] else {
                continue
            }

            for hookIndex in hooks.indices {
                guard let existingCommand = hooks[hookIndex]["command"] as? String,
                      existingCommand.contains(hookMarker)
                else {
                    continue
                }

                hooks[hookIndex]["type"] = "command"
                hooks[hookIndex]["command"] = command
                entries[index]["hooks"] = hooks
                found = true
            }
        }

        if !found {
            entries.append([
                "matcher": "",
                "hooks": [
                    [
                        "type": "command",
                        "command": command
                    ]
                ]
            ])
        }

        return entries
    }

    private func upsertHTTPHook(into existingValue: Any?, url: String) -> [[String: Any]] {
        var entries = (existingValue as? [[String: Any]]) ?? []
        var found = false

        for index in entries.indices {
            guard var hooks = entries[index]["hooks"] as? [[String: Any]] else {
                continue
            }

            for hookIndex in hooks.indices {
                guard let hookURL = hooks[hookIndex]["url"] as? String,
                      ownedPermissionHookURLs.contains(hookURL)
                else {
                    continue
                }

                hooks[hookIndex]["type"] = "http"
                hooks[hookIndex]["url"] = url
                hooks[hookIndex]["timeout"] = 600
                entries[index]["hooks"] = hooks
                found = true
            }
        }

        if !found {
            entries.append([
                "matcher": "",
                "hooks": [
                    [
                        "type": "http",
                        "url": url,
                        "timeout": 600
                    ]
                ]
            ])
        }

        return entries
    }

    private var ownedPermissionHookURLs: Set<String> {
        [
            "http://127.0.0.1:\(listenerPort)\(permissionHookPath)",
            "http://localhost:\(listenerPort)\(permissionHookPath)",
            "http://127.0.0.1:\(listenerPort)/permission",
            "http://localhost:\(listenerPort)/permission"
        ]
    }

    private func resolveNodeBinary() -> String {
        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["node"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return "node"
    }

    private func describeClaudeHookConfigurationError(_ error: Error) -> String {
        guard let configurationError = error as? ClaudeHookConfigurationError else {
            return error.localizedDescription
        }

        switch configurationError {
        case .invalidSettingsRoot:
            return "settings root is not a JSON object"
        case let .invalidCustomSettingsPathsFile(path):
            return "custom settings path file is invalid: \(path)"
        case let .partialSyncFailed(reasons), let .syncFailed(reasons):
            return reasons.joined(separator: "; ")
        }
    }
}

private enum ClaudeHookConfigurationError: Error {
    case invalidSettingsRoot
    case invalidCustomSettingsPathsFile(String)
    case partialSyncFailed([String])
    case syncFailed([String])
}

private struct ClaudeTrackedSession {
    enum Status {
        case idle
        case running
        case success
        case failure

        var isTerminal: Bool {
            switch self {
            case .success, .failure:
                return true
            case .idle, .running:
                return false
            }
        }

        var activityState: IslandCodexActivityState {
            switch self {
            case .idle:
                return .idle
            case .running:
                return .running
            case .success:
                return .success
            case .failure:
                return .failure
            }
        }
    }

    let rawSessionID: String
    let cwd: String
    let source: String
    let status: Status
    let lastEvent: String
    let lastActivityAt: Date

    var title: String {
        "Claude Code"
    }

    var detail: String {
        if !cwd.isEmpty {
            return cwd
        }

        if !source.isEmpty {
            return source
        }

        return lastEvent
    }

    static func status(for event: String, state: String) -> Status {
        if state == "error" || event == "PostToolUseFailure" || event == "StopFailure" {
            return .failure
        }
        if state == "attention" || event == "Stop" || event == "PostCompact" {
            return .success
        }
        if state == "notification" || event == "Notification" || event == "Elicitation" {
            return .idle
        }
        if state == "idle" || state == "sleeping" {
            return .idle
        }
        return .running
    }

    static func isTrailingRunningEvent(_ event: String) -> Bool {
        switch event {
        case "PostToolUse", "SubagentStop", "Notification", "Elicitation":
            return true
        default:
            return false
        }
    }

    static func isExplicitRunningEvent(_ event: String) -> Bool {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "SubagentStart", "PreCompact", "WorktreeCreate", "PermissionRequest":
            return true
        default:
            return false
        }
    }
}

private final class ClaudePendingApproval {
    let id: String
    let sessionID: String
    let createdAt: Date
    let commandSummary: String
    let rationale: String?
    let connection: NWConnection

    init(
        id: String,
        sessionID: String,
        createdAt: Date,
        commandSummary: String,
        rationale: String?,
        connection: NWConnection
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.commandSummary = commandSummary
        self.rationale = rationale
        self.connection = connection
    }
}

private struct ParsedHTTPRequest {
    let method: String
    let path: String
    let body: Data
}

private struct ClaudeHookEventPayload: Decodable {
    let event: String
    let state: String
    let sessionID: String
    let cwd: String
    let source: String

    private enum CodingKeys: String, CodingKey {
        case event
        case state
        case sessionID = "session_id"
        case cwd
        case source
    }
}

private struct ClaudeHookPermissionPayload: Decodable {
    struct ToolInput: Decodable {
        let command: String?
        let filePath: String?

        private enum CodingKeys: String, CodingKey {
            case command
            case filePath = "file_path"
        }
    }

    struct PermissionSuggestion: Decodable {
        let type: String?
    }

    let sessionID: String
    let toolName: String
    let toolInput: ToolInput?
    let permissionSuggestions: [PermissionSuggestion]?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
    }
}
