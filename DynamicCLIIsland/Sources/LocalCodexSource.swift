import AppKit
import Foundation
import Network

struct LocalCodexSource: @unchecked Sendable {
    private let codexRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    private let sessionsDirectoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private let globalStateURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/.codex-global-state.json")
    private let codexHistoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/history.jsonl")
    private let tuiLogURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/log/codex-tui.log")
    private let recentThreadLimit = 8
    private let usageThreadLimit = 50
    private let idleSessionLookback: TimeInterval = 6 * 60 * 60
    private let unconfirmedDesktopSessionLookback: TimeInterval = 5 * 60
    private let fallbackTUILookback: TimeInterval = 6 * 60 * 60
    private let staleSessionThreshold: TimeInterval = 3 * 60
    private let recentSessionScanBytes = 768 * 1024
    private let maxSessionMetaLineBytes = 8 * 1024 * 1024
    private let runningSignalMaxAge: TimeInterval = 30
    private let terminalStatusHold: TimeInterval = 18
    private let successSettleDelay: TimeInterval = 1
    private let rateLimitResetTolerance: TimeInterval = 5
    private let shellSnapshotsDirectoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/shell_snapshots")
    private let sessionFileLocator = SessionFileLocator(
        rootURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    )
    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var stateDatabaseURL: URL {
        latestSQLiteURL(prefix: "state_", fallbackName: "state_5.sqlite")
    }

    private var logsDatabaseURL: URL {
        latestSQLiteURL(prefix: "logs_", fallbackName: "logs_1.sqlite")
    }

    func fetchActivity() -> ActivitySourceSnapshot {
        let fileManager = FileManager.default
        let hasStateDatabase = fileManager.fileExists(atPath: stateDatabaseURL.path)
        let hasHistoryLog = fileManager.fileExists(atPath: codexHistoryURL.path)
        let hasSessionsDirectory = fileManager.fileExists(atPath: sessionsDirectoryURL.path)

        guard hasStateDatabase || hasHistoryLog || hasSessionsDirectory else {
            return ActivitySourceSnapshot(
                sessions: [],
                statusMessage: "Local Codex state unavailable",
                lastUpdatedAt: .now,
                errorMessage: nil,
                approvalRequest: nil,
                usageSnapshots: []
            )
        }

        let threadReferences = fetchRecentThreadReferences(limit: recentThreadLimit)
        let usageThreadReferences = fetchRecentThreadReferences(limit: usageThreadLimit)
        let threadSnapshots = threadReferences.compactMap(makeThreadSnapshot(from:))
        guard !threadSnapshots.isEmpty else {
            return ActivitySourceSnapshot(
                sessions: [],
                statusMessage: "Waiting for Codex activity",
                lastUpdatedAt: .now,
                errorMessage: nil,
                approvalRequest: nil,
                usageSnapshots: fetchUsageSnapshots(threadReferences: usageThreadReferences)
            )
        }

        var sessions: [AgentSessionSnapshot] = []
        var newestApprovalRequest: ApprovalRequest?
        let globalState = fetchGlobalState()

        for threadSnapshot in threadSnapshots {
            let sessionFileURL = fetchSessionFileURL(for: threadSnapshot.threadID)
            let sessionMeta = sessionFileURL.flatMap(fetchSessionMeta(from:))
            let sessionHints = sessionFileURL.flatMap(fetchSessionActivityHints(from:))
            let conversationSummary = sessionFileURL.flatMap(fetchConversationSummary(from:))
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
                    title: conversationSummary ?? sessionTitle(
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
            approvalRequest: newestApprovalRequest,
            usageSnapshots: fetchUsageSnapshots(threadReferences: usageThreadReferences)
        )
    }

    func fetchLatestApprovalRequest() -> ApprovalRequest? {
        fetchApprovalProbeResult().pendingRequest
    }

    func fetchApprovalProbeResult() -> CodexApprovalProbeResult {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return CodexApprovalProbeResult(pendingRequest: nil, resolvedRequestIDs: [])
        }

        let threadReferences = fetchRecentThreadReferences(limit: 4)
        guard !threadReferences.isEmpty else {
            return CodexApprovalProbeResult(pendingRequest: nil, resolvedRequestIDs: [])
        }

        let globalState = fetchGlobalState()
        var newestApprovalRequest: ApprovalRequest?
        var resolvedRequestIDs: Set<String> = []

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

            guard let sessionFileURL else {
                continue
            }

            let approvalProbe = fetchApprovalProbe(in: sessionFileURL, focusTarget: focusTarget)
            resolvedRequestIDs.formUnion(approvalProbe.resolvedRequestIDs)

            guard let approvalRequest = approvalProbe.pendingRequest else {
                continue
            }

            if newestApprovalRequest == nil || approvalRequest.createdAt > newestApprovalRequest!.createdAt {
                newestApprovalRequest = approvalRequest
            }
        }

        return CodexApprovalProbeResult(
            pendingRequest: newestApprovalRequest,
            resolvedRequestIDs: resolvedRequestIDs
        )
    }

    private func deriveActivityState(
        from snapshot: LocalCodexThreadSnapshot,
        sessionHints: LocalCodexSessionActivityHints?
    ) -> IslandCodexActivityState {
        let now = Date().timeIntervalSince1970
        let latestCompletionAt = max(snapshot.completedAt, sessionHints?.taskCompletedAt ?? 0)
        let latestFailureAt = max(snapshot.failedAt, sessionHints?.taskFailedAt ?? 0)
        let latestAbortedAt = sessionHints?.taskAbortedAt ?? 0
        let latestTerminalAt = max(latestCompletionAt, latestFailureAt)
        let latestExplicitRunningAt = max(
            snapshot.inProgressAt,
            snapshot.turnActivityAt,
            snapshot.streamingActivityAt,
            sessionHints?.taskStartedAt ?? 0
        )

        if latestAbortedAt > 0,
           latestAbortedAt >= latestExplicitRunningAt,
           latestAbortedAt >= latestCompletionAt,
           latestAbortedAt >= latestFailureAt {
            return .idle
        }

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

    private func fetchUsageSnapshots(threadReferences: [RecentThreadReference]) -> [ProviderUsageSnapshot] {
        guard let snapshot = fetchLatestCodexUsageSnapshot(threadReferences: threadReferences) else {
            return []
        }

        return [snapshot]
    }

    private func fetchLatestCodexUsageSnapshot(threadReferences: [RecentThreadReference]) -> ProviderUsageSnapshot? {
        var primaryWindow: LocalCodexUsageWindow?
        var secondaryWindow: LocalCodexUsageWindow?
        var latestTimestamp: Date?

        for reference in threadReferences {
            guard let fileURL = fetchSessionFileURL(for: reference.threadID),
                  let snapshot = fetchUsageSnapshot(from: fileURL) else {
                continue
            }

            primaryWindow = mergedUsageWindow(current: primaryWindow, incoming: snapshot.primaryWindow)
            secondaryWindow = mergedUsageWindow(current: secondaryWindow, incoming: snapshot.secondaryWindow)
            latestTimestamp = max(latestTimestamp ?? .distantPast, snapshot.updatedAt)
        }

        guard primaryWindow != nil || secondaryWindow != nil else {
            return nil
        }

        return ProviderUsageSnapshot(
            origin: .codex,
            shortWindowRemaining: normalizedRemainingShare(forUsedPercent: primaryWindow?.usedPercent),
            longWindowRemaining: normalizedRemainingShare(forUsedPercent: secondaryWindow?.usedPercent),
            updatedAt: latestTimestamp ?? .now
        )
    }

    private func fetchUsageSnapshot(from fileURL: URL) -> LocalCodexUsageSnapshot? {
        var latestSnapshot: LocalCodexUsageSnapshot?

        for line in readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String,
                  type == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any]
            else {
                continue
            }

            let timestampString = record["timestamp"] as? String
            let timestamp = timestampString.flatMap(iso8601Formatter.date(from:)) ?? .now
            let snapshot = LocalCodexUsageSnapshot(
                primaryWindow: makeUsageWindow(from: rateLimits["primary"] as? [String: Any]),
                secondaryWindow: makeUsageWindow(from: rateLimits["secondary"] as? [String: Any]),
                updatedAt: timestamp
            )

            latestSnapshot = latestSnapshot.map { mergedUsageSnapshot(current: $0, incoming: snapshot) } ?? snapshot
        }

        return latestSnapshot
    }

    private func makeUsageWindow(from payload: [String: Any]?) -> LocalCodexUsageWindow? {
        guard let payload else {
            return nil
        }

        let resetsAt = timeInterval(from: payload["resets_at"])
        let windowMinutes = intValue(from: payload["window_minutes"])
        let usedPercent = doubleValue(from: payload["used_percent"])
        guard resetsAt != nil || usedPercent != nil || windowMinutes != nil else {
            return nil
        }

        return LocalCodexUsageWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes
        )
    }

    private func mergedUsageSnapshot(current: LocalCodexUsageSnapshot, incoming: LocalCodexUsageSnapshot) -> LocalCodexUsageSnapshot {
        LocalCodexUsageSnapshot(
            primaryWindow: mergedUsageWindow(current: current.primaryWindow, incoming: incoming.primaryWindow),
            secondaryWindow: mergedUsageWindow(current: current.secondaryWindow, incoming: incoming.secondaryWindow),
            updatedAt: max(current.updatedAt, incoming.updatedAt)
        )
    }

    private func mergedUsageWindow(current: LocalCodexUsageWindow?, incoming: LocalCodexUsageWindow?) -> LocalCodexUsageWindow? {
        guard let incoming else {
            return current
        }
        guard let current else {
            return incoming
        }

        let currentReset = current.resetsAt ?? 0
        let incomingReset = incoming.resetsAt ?? 0
        if abs(incomingReset - currentReset) <= rateLimitResetTolerance {
            let currentUsed = current.usedPercent ?? 0
            let incomingUsed = incoming.usedPercent ?? 0
            if incomingUsed != currentUsed {
                return incomingUsed > currentUsed ? incoming : current
            }

            if current.usedPercent == nil {
                return incoming
            }

            return currentReset >= incomingReset ? current : incoming
        }

        if incomingReset != currentReset {
            return incomingReset > currentReset ? incoming : current
        }

        let currentUsed = current.usedPercent ?? 0
        let incomingUsed = incoming.usedPercent ?? 0
        if incomingUsed != currentUsed {
            return incomingUsed > currentUsed ? incoming : current
        }

        if current.usedPercent == nil {
            return incoming
        }

        return current
    }

    private func normalizedRemainingShare(forUsedPercent value: Any?) -> Double {
        let usedPercent = doubleValue(from: value)
        guard let usedPercent else {
            return 1
        }

        return max(0, min(1, (100 - usedPercent) / 100))
    }

    private func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func timeInterval(from value: Any?) -> TimeInterval? {
        doubleValue(from: value)
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

        let databaseReferences = (runSQLiteRows(databaseURL: stateDatabaseURL, sql: latestThreadSQL) ?? [])
            .compactMap(makeThreadReference(from:))
        let historyReferences = fetchRecentHistoryThreadReferences(limit: limit)

        var mergedReferences: [RecentThreadReference] = []
        var seenThreadIDs = Set<String>()

        for reference in (databaseReferences + historyReferences).sorted(by: { lhs, rhs in
            lhs.threadUpdatedAt > rhs.threadUpdatedAt
        }) {
            guard !seenThreadIDs.contains(reference.threadID) else {
                continue
            }

            seenThreadIDs.insert(reference.threadID)
            mergedReferences.append(reference)

            if mergedReferences.count >= limit {
                break
            }
        }

        return mergedReferences
    }

    private func fetchRecentHistoryThreadReferences(limit: Int) -> [RecentThreadReference] {
        guard let content = try? String(contentsOf: codexHistoryURL, encoding: .utf8) else {
            return []
        }

        var references: [RecentThreadReference] = []
        var seenThreadIDs = Set<String>()

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(LocalCodexHistoryEntry.self, from: data),
                  !entry.sessionID.isEmpty,
                  !seenThreadIDs.contains(entry.sessionID)
            else {
                continue
            }

            let cwd = fetchSessionFileURL(for: entry.sessionID)
                .flatMap(fetchSessionMeta(from:))?
                .cwd ?? ""

            references.append(
                RecentThreadReference(
                    threadID: entry.sessionID,
                    threadUpdatedAt: entry.timestamp,
                    threadSource: "cli",
                    cwd: cwd
                )
            )
            seenThreadIDs.insert(entry.sessionID)

            if references.count >= limit {
                break
            }
        }

        return references
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

            if data.count >= maxSessionMetaLineBytes {
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

    private func fetchConversationSummary(from fileURL: URL) -> String? {
        for line in readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = jsonObject["type"] as? String,
                  type == "response_item",
                  let payload = jsonObject["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "message",
                  let role = payload["role"] as? String,
                  role == "user",
                  let content = payload["content"] as? [[String: Any]]
            else {
                continue
            }

            for item in content {
                guard let itemType = item["type"] as? String,
                      itemType == "input_text",
                      let text = item["text"] as? String,
                      let summary = summarizeConversationText(text) else {
                    continue
                }

                return summary
            }
        }

        return nil
    }

    private func summarizeConversationText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<environment_context>") else {
            return nil
        }

        let singleLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.isEmpty else {
            return nil
        }

        if singleLine.count <= 72 {
            return singleLine
        }

        return String(singleLine.prefix(72)) + "..."
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
        } else if isCLIOrigin(originator: sessionMeta?.originator, source: sessionMeta?.source, fallbackSource: fallbackSource) {
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
            terminalClient: clientOrigin == .codexCLI ? terminalClient : nil,
            terminalSessionHint: nil,
            workspaceHint: resolvedCWD.isEmpty ? nil : resolvedCWD
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
        fetchApprovalProbe(in: fileURL, focusTarget: focusTarget).pendingRequest
    }

    private func fetchApprovalProbe(in fileURL: URL, focusTarget: FocusTarget?) -> CodexApprovalProbeResult {
        let recentLines = readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes)
        guard !recentLines.isEmpty else {
            return CodexApprovalProbeResult(pendingRequest: nil, resolvedRequestIDs: [])
        }

        var pendingCalls: [String: PendingApprovalPayload] = [:]
        var resolvedRequestIDs: Set<String> = []

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
                resolvedRequestIDs.insert(callID)
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
            let command = (arguments["cmd"] as? String) ?? (arguments["command"] as? String) ?? ""
            let justification = arguments["justification"] as? String

            pendingCalls[callID] = PendingApprovalPayload(
                callID: callID,
                command: command,
                justification: justification,
                timestamp: timestamp
            )
        }

        guard let latestPending = pendingCalls.values.max(by: { $0.timestamp < $1.timestamp }) else {
            return CodexApprovalProbeResult(
                pendingRequest: nil,
                resolvedRequestIDs: resolvedRequestIDs
            )
        }

        return CodexApprovalProbeResult(
            pendingRequest: ApprovalRequest(
                id: latestPending.callID,
                commandSummary: summarizeCommand(latestPending.command),
                commandText: normalizedCommandText(latestPending.command),
                rationale: latestPending.justification,
                focusTarget: focusTarget,
                createdAt: latestPending.timestamp,
                source: .codex,
                resolutionKind: .accessibilityAutomation
            ),
            resolvedRequestIDs: resolvedRequestIDs
        )
    }

    private func summarizeCommand(_ command: String) -> String {
        let singleLine = normalizedCommandText(command)

        guard singleLine.count > 96 else {
            return singleLine
        }

        return String(singleLine.prefix(96)) + "..."
    }

    private func normalizedCommandText(_ command: String) -> String {
        let singleLine = command
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine
    }

    private func fetchSessionActivityHints(from fileURL: URL) -> LocalCodexSessionActivityHints? {
        let recentLines = readRecentLines(from: fileURL, maxBytes: recentSessionScanBytes)
        guard !recentLines.isEmpty else {
            return nil
        }

        var taskStartedAt: Date?
        var taskCompletedAt: Date?
        var taskFailedAt: Date?
        var taskAbortedAt: Date?

        for line in recentLines {
            guard let data = String(line).data(using: .utf8) else {
                continue
            }

            guard
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let timestampString = record["timestamp"] as? String
            let timestamp = timestampString.flatMap(iso8601Formatter.date(from:)) ?? .now

            if let recordType = record["type"] as? String,
               recordType == "event_msg",
               let payload = record["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String,
               payloadType == "turn_aborted" {
                taskAbortedAt = timestamp
                continue
            }

            guard
                let payload = record["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String
            else {
                continue
            }

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

        guard taskStartedAt != nil || taskCompletedAt != nil || taskFailedAt != nil || taskAbortedAt != nil else {
            return nil
        }

        return LocalCodexSessionActivityHints(
            taskStartedAt: taskStartedAt?.timeIntervalSince1970 ?? 0,
            taskCompletedAt: taskCompletedAt?.timeIntervalSince1970 ?? 0,
            taskFailedAt: taskFailedAt?.timeIntervalSince1970 ?? 0,
            taskAbortedAt: taskAbortedAt?.timeIntervalSince1970 ?? 0
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
                    terminalClient: terminalClient,
                    terminalSessionHint: nil,
                    workspaceHint: nil
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
        if isCLIOrigin(originator: sessionMeta?.originator, source: sessionMeta?.source, fallbackSource: fallbackSource) {
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

    private func latestSQLiteURL(prefix: String, fallbackName: String) -> URL {
        let fallbackURL = codexRootURL.appendingPathComponent(fallbackName)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: codexRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fallbackURL
        }

        let matchingURLs = fileURLs.filter { fileURL in
            let name = fileURL.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".sqlite")
        }

        guard !matchingURLs.isEmpty else {
            return fallbackURL
        }

        return matchingURLs.max { lhs, rhs in
            let leftVersion = sqliteVersion(in: lhs.lastPathComponent, prefix: prefix)
            let rightVersion = sqliteVersion(in: rhs.lastPathComponent, prefix: prefix)
            if leftVersion != rightVersion {
                return leftVersion < rightVersion
            }

            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        } ?? fallbackURL
    }

    private func sqliteVersion(in fileName: String, prefix: String) -> Int {
        guard
            fileName.hasPrefix(prefix),
            fileName.hasSuffix(".sqlite")
        else {
            return -1
        }

        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -".sqlite".count)
        return Int(fileName[start..<end]) ?? -1
    }

    private func isCLIOrigin(originator: String?, source: String?, fallbackSource: String) -> Bool {
        let normalizedOriginator = originator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedFallbackSource = fallbackSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if ["cli", "exec"].contains(normalizedSource) || ["cli", "exec"].contains(normalizedFallbackSource) {
            return true
        }

        return ["codex_cli_rs", "codex_sdk_ts", "codex-tui"].contains(normalizedOriginator)
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

private struct LocalCodexUsageSnapshot {
    let primaryWindow: LocalCodexUsageWindow?
    let secondaryWindow: LocalCodexUsageWindow?
    let updatedAt: Date
}

private struct LocalCodexUsageWindow {
    let usedPercent: Double?
    let resetsAt: TimeInterval?
    let windowMinutes: Int?
}

private struct LocalCodexSessionMeta {
    let cwd: String
    let originator: String
    let source: String

    var originDescription: String {
        if originator == "Codex Desktop" {
            return "Codex Desktop"
        }
        let normalizedOriginator = originator.lowercased()
        let normalizedSource = source.lowercased()
        if normalizedOriginator == "codex_cli_rs"
            || normalizedOriginator == "codex_sdk_ts"
            || normalizedOriginator == "codex-tui"
            || normalizedSource == "cli"
            || normalizedSource == "exec" {
            return "Terminal Codex"
        }
        if normalizedOriginator == "codex_vscode" || normalizedSource == "vscode" {
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

private struct LocalCodexHistoryEntry: Decodable {
    let sessionID: String
    let timestamp: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case timestamp = "ts"
    }
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

struct CodexApprovalProbeResult {
    let pendingRequest: ApprovalRequest?
    let resolvedRequestIDs: Set<String>
}

private struct LocalCodexSessionActivityHints {
    let taskStartedAt: TimeInterval
    let taskCompletedAt: TimeInterval
    let taskFailedAt: TimeInterval
    let taskAbortedAt: TimeInterval

    var latestKnownAt: TimeInterval {
        max(taskStartedAt, taskCompletedAt, taskFailedAt, taskAbortedAt)
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

    func fetchLatestQuestionPrompt() -> ClaudeQuestionPrompt? {
        bridge.latestQuestionPrompt()
    }

    func resolveApproval(id: String, decision: ApprovalDecision) -> Bool {
        bridge.resolveApproval(id: id, decision: decision)
    }

    func resolveQuestion(id: String, response: ClaudeQuestionResponse) -> Bool {
        bridge.resolveQuestion(id: id, response: response)
    }

    func dismissQuestion(id: String) -> Bool {
        bridge.dismissQuestion(id: id)
    }

    func isQuestionSubmittable(id: String) -> Bool {
        bridge.isQuestionSubmittable(id: id)
    }

    func startCallbackServer() {
        bridge.start()
    }

    func installHooks() throws {
        bridge.start()
        try bridge.installHooks()
    }

    func uninstallHooks() throws {
        try bridge.uninstallHooks()
    }

    func hookHealthReport() -> SourceHealthReport {
        bridge.hookHealthReport()
    }

    func callbackServerHealthReport() -> SourceHealthReport {
        bridge.callbackServerHealthReport()
    }
}

private final class ClaudeHookBridge: @unchecked Sendable {
    static let shared = ClaudeHookBridge()

    private let queue = DispatchQueue(label: "HermitFlow.claudeHookBridge")
    private let listenerQueue = DispatchQueue(label: "HermitFlow.claudeHookListener")
    private let listenerPort: UInt16 = 46821
    private let sessionStaleThreshold: TimeInterval = 10 * 60
    private let successDisplayHold: TimeInterval = 1.25
    private let failureDisplayHold: TimeInterval = 2.0
    private let trailingRunningIgnoreWindow: TimeInterval = 2.0
    private let hookRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-hooks")
    private let defaultSettingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    private let customSettingsPathsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-settings-paths.json")
    private let customSettingsPathsEnvironmentKey = "HERMITFLOW_CLAUDE_SETTINGS_PATHS"
    private let askUserQuestionModeDefaultsKey = "HermitFlow.askUserQuestionHandlingMode"
    private let hookScriptName = "hermit-claude-hook.js"
    private let hookMarker = "hermit-claude-hook.js"
    private let permissionHookPath = "/permission/hermitflow"
    private let questionHookPath = "/question/hermitflow"
    private let askUserQuestionHookPath = "/ask-user/hermitflow"
    private let claudeUsageCacheURL = URL(fileURLWithPath: "/tmp/hermitflow-rl.json")
    private let claudeStatusLineDebugURL = URL(fileURLWithPath: "/tmp/hermitflow-claude-statusline-debug.json")
    private let questionStateRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-questions")
    private let latestQuestionStateURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermitflow/claude-questions/latest-question.json")
    private let claudeHistoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/history.jsonl")
    private let claudeSessionsRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    private let claudeProjectsRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private let claudeDebugLogURL = URL(fileURLWithPath: "/tmp/hermitflow-claude-debug.log")
    private let recentHistoryScanBytes = 512 * 1024
    private let recentClaudeProjectFileLimit = 20
    private let interruptionOverrideWindow: TimeInterval = 10
    private let stalledPromptFallbackWindow: TimeInterval = 3
    private let claudePromptRunningWindow: TimeInterval = 15
    private let historyTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var listener: NWListener?
    private var listenerReady = false
    private var sessions: [String: ClaudeTrackedSession] = [:]
    private var approvals: [String: ClaudePendingApproval] = [:]
    private var approvalOrder: [String] = []
    private var questions: [String: ClaudePendingQuestion] = [:]
    private var questionOrder: [String] = []
    private var lastErrorMessage: String?

    func start() {
        queue.sync {
            guard listener == nil else {
                return
            }

            do {
                listenerReady = false
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
                listenerReady = false
            }
        }
    }

    func installHooks() throws {
        try writeHookScriptIfNeeded()
        try syncClaudeSettings()
        queue.sync {
            lastErrorMessage = nil
        }
    }

    func uninstallHooks() throws {
        let settingsURLs = try resolvedClaudeSettingsURLs()
        for settingsURL in settingsURLs {
            try removeManagedHooks(from: settingsURL)
        }

        let scriptURL = hookRootURL.appendingPathComponent(hookScriptName)
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            try FileManager.default.removeItem(at: scriptURL)
        }

        if FileManager.default.fileExists(atPath: claudeUsageCacheURL.path) {
            try? FileManager.default.removeItem(at: claudeUsageCacheURL)
        }

        if FileManager.default.fileExists(atPath: claudeStatusLineDebugURL.path) {
            try? FileManager.default.removeItem(at: claudeStatusLineDebugURL)
        }

        queue.sync {
            lastErrorMessage = nil
        }
    }

    func syncHooks() {
        do {
            try installHooks()
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
                approvalRequest: latestApprovalRequestLocked(),
                usageSnapshots: []
            )
        }
    }

    func latestApprovalRequest() -> ApprovalRequest? {
        queue.sync {
            cleanupExpiredState(now: .now)
            return latestApprovalRequestLocked()
        }
    }

    func latestQuestionPrompt() -> ClaudeQuestionPrompt? {
        queue.sync {
            cleanupExpiredState(now: .now)
            return latestQuestionPromptLocked()
        }
    }

    func hookHealthReport() -> SourceHealthReport {
        queue.sync {
            SourceHealthReport(sourceName: "Claude", issues: hookIssuesLocked())
        }
    }

    func callbackServerHealthReport() -> SourceHealthReport {
        queue.sync {
            SourceHealthReport(sourceName: "Claude", issues: callbackServerIssuesLocked())
        }
    }

    func resolveApproval(id: String, decision: ApprovalDecision) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let approval = approvals[id] else {
                approvalOrder.removeAll { $0 == id }
                return false
            }

            guard let connection = approval.connection else {
                return false
            }

            approvals.removeValue(forKey: id)
            approvalOrder.removeAll { $0 == id }

            let response = makePermissionDecision(for: decision)
            sendHTTPResponse(
                status: 200,
                body: response,
                contentType: "application/json",
                on: connection
            )
            return true
        }
    }

    func resolveQuestion(id: String, response: ClaudeQuestionResponse) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let question = questions[id] else {
                questionOrder.removeAll { $0 == id }
                clearPersistedQuestionPrompt()
                return false
            }

            guard let connection = question.connection else {
                return false
            }

            let body: String
            switch question.source {
            case .elicitation:
                body = makeElicitationDecision(for: response, pendingQuestion: question)
            case .askUserQuestion:
                body = makeAskUserQuestionDecision(for: response, pendingQuestion: question)
            }
            questions.removeValue(forKey: id)
            questionOrder.removeAll { $0 == id }
            persistLatestQuestionPromptLocked()
            sendHTTPResponse(status: 200, body: body, contentType: "application/json", on: connection)
            return true
        }
    }

    func dismissQuestion(id: String) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let question = questions[id] else {
                questionOrder.removeAll { $0 == id }
                clearPersistedQuestionPrompt()
                return false
            }

            guard let connection = question.connection else {
                questions.removeValue(forKey: id)
                questionOrder.removeAll { $0 == id }
                persistLatestQuestionPromptLocked()
                return true
            }

            let body: String
            switch question.source {
            case .elicitation:
                body = makeDeclineElicitationDecision()
            case .askUserQuestion:
                body = makeDenyPreToolUseDecision()
            }

            questions.removeValue(forKey: id)
            questionOrder.removeAll { $0 == id }
            persistLatestQuestionPromptLocked()
            sendHTTPResponse(status: 200, body: body, contentType: "application/json", on: connection)
            return true
        }
    }

    func isQuestionSubmittable(id: String) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let question = questions[id] else {
                return false
            }

            switch question.source {
            case .elicitation:
                return question.connection != nil
            case .askUserQuestion:
                return question.connection != nil
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        queue.sync {
            switch state {
            case .ready:
                lastErrorMessage = nil
                listenerReady = true
            case let .failed(error):
                lastErrorMessage = "Claude hook listener failed: \(error.localizedDescription)"
                listenerReady = false
                listener?.cancel()
                listener = nil
            case .cancelled:
                listenerReady = false
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
        case ("POST", questionHookPath):
            handleQuestion(body: request.body, on: connection)
        case ("POST", askUserQuestionHookPath):
            handleAskUserQuestion(body: request.body, on: connection)
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
            } else {
                let now = Date()
                sessions[sessionID] = mergedClaudeSession(
                    existing: sessions[sessionID],
                    payload: payload,
                    now: now
                )
            }
            if shouldClearApprovals(for: payload) {
                clearApprovals(forSessionID: sessionID)
            }
            if shouldClearQuestions(for: payload) {
                clearQuestions(forSessionID: sessionID)
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

        // AskUserQuestion should proceed into its native/tool-specific flow instead of
        // being surfaced as a generic approval request first.
        if payload.toolName == "AskUserQuestion" {
            sendHTTPResponse(
                status: 200,
                body: "",
                contentType: "text/plain",
                on: connection
            )
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
                commandText: permissionCommandText(payload),
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
                conversationSummary: existing?.conversationSummary ?? fetchClaudeConversationSummary(
                    for: sessionID,
                    cwd: existing?.cwd ?? ""
                ),
                clientOrigin: existing?.clientOrigin,
                terminalClient: existing?.terminalClient,
                terminalSessionHint: existing?.terminalSessionHint,
                status: .running,
                lastEvent: "PermissionRequest",
                lastActivityAt: .now
            )
        }
    }

    private func handleQuestion(body: Data, on connection: NWConnection) {
        guard let payload = try? JSONDecoder().decode(ClaudeHookElicitationPayload.self, from: body) else {
            sendHTTPResponse(status: 400, body: "bad json", contentType: "text/plain", on: connection)
            return
        }

        queue.sync {
            cleanupExpiredState(now: .now)

            let sessionID = payload.sessionID.isEmpty ? "default" : payload.sessionID
            let prompt = makeQuestionPrompt(from: payload, sessionID: sessionID)
            questions[prompt.id] = ClaudePendingQuestion(
                prompt: prompt,
                source: .elicitation(payload),
                connection: connection
            )
            questionOrder.removeAll { $0 == prompt.id }
            questionOrder.append(prompt.id)
            persistLatestQuestionPromptLocked()

            let existing = sessions[sessionID]
            sessions[sessionID] = ClaudeTrackedSession(
                rawSessionID: sessionID,
                cwd: existing?.cwd ?? "",
                source: existing?.source ?? payload.mcpServerName,
                conversationSummary: existing?.conversationSummary ?? prompt.title,
                clientOrigin: existing?.clientOrigin,
                terminalClient: existing?.terminalClient,
                terminalSessionHint: existing?.terminalSessionHint,
                status: .running,
                lastEvent: "Elicitation",
                lastActivityAt: .now
            )
        }
    }

    private func handleAskUserQuestion(body: Data, on connection: NWConnection) {
        guard let payload = try? JSONDecoder().decode(ClaudeHookAskUserQuestionPayload.self, from: body) else {
            sendHTTPResponse(
                status: 200,
                body: makePassThroughPreToolUseDecision(updatedInput: nil),
                contentType: "application/json",
                on: connection
            )
            return
        }

        guard payload.toolName == "AskUserQuestion",
              let toolInput = payload.toolInput,
              toolInput.questions.count == 1,
              let askQuestion = toolInput.questions.first,
              askQuestion.multiSelect == false else {
            sendHTTPResponse(
                status: 200,
                body: makePassThroughPreToolUseDecision(updatedInput: payload.toolInput?.jsonObject),
                contentType: "application/json",
                on: connection
            )
            return
        }

        queue.sync {
            cleanupExpiredState(now: .now)

            let sessionID = payload.sessionID.isEmpty ? "default" : payload.sessionID
            let handlingMode = askUserQuestionHandlingMode()
            let prompt = makeQuestionPrompt(from: payload, sessionID: sessionID, handlingMode: handlingMode)
            questions[prompt.id] = ClaudePendingQuestion(
                prompt: prompt,
                source: .askUserQuestion(payload),
                connection: handlingMode == .takeOver ? connection : nil
            )
            questionOrder.removeAll { $0 == prompt.id }
            questionOrder.append(prompt.id)
            persistLatestQuestionPromptLocked()

            let existing = sessions[sessionID]
            sessions[sessionID] = ClaudeTrackedSession(
                rawSessionID: sessionID,
                cwd: payload.cwd.isEmpty ? existing?.cwd ?? "" : payload.cwd,
                source: existing?.source ?? payload.toolName,
                conversationSummary: existing?.conversationSummary ?? prompt.title,
                clientOrigin: existing?.clientOrigin,
                terminalClient: existing?.terminalClient,
                terminalSessionHint: existing?.terminalSessionHint,
                status: .running,
                lastEvent: "AskUserQuestion",
                lastActivityAt: .now
            )
        }

        if askUserQuestionHandlingMode() == .mirror {
            sendHTTPResponse(
                status: 200,
                body: makePassThroughPreToolUseDecision(updatedInput: payload.toolInput?.jsonObject),
                contentType: "application/json",
                on: connection
            )
        }
    }

    private func cleanupConnection(_ connection: NWConnection) {
        queue.sync {
            let resolvedApprovalIDs = approvals.compactMap { approvalID, approval in
                approval.connection === connection ? approvalID : nil
            }
            let resolvedQuestionIDs = questions.compactMap { questionID, question in
                question.connection === connection ? questionID : nil
            }

            guard !resolvedApprovalIDs.isEmpty || !resolvedQuestionIDs.isEmpty else {
                return
            }

            for approvalID in resolvedApprovalIDs {
                approvals.removeValue(forKey: approvalID)
            }
            approvalOrder.removeAll { resolvedApprovalIDs.contains($0) }

            for questionID in resolvedQuestionIDs {
                questions.removeValue(forKey: questionID)
            }
            questionOrder.removeAll { resolvedQuestionIDs.contains($0) }
            persistLatestQuestionPromptLocked()
        }
    }

    private func clearApprovals(forSessionID sessionID: String) {
        approvalOrder = approvalOrder.filter { approvalID in
            approvals[approvalID]?.sessionID != sessionID
        }
        approvals = approvals.filter { _, approval in
            approval.sessionID != sessionID
        }
    }

    private func clearQuestions(forSessionID sessionID: String) {
        questionOrder = questionOrder.filter { questionID in
            questions[questionID]?.prompt.sessionID != sessionID
        }
        questions = questions.filter { _, question in
            question.prompt.sessionID != sessionID
        }
        persistLatestQuestionPromptLocked()
    }

    private func shouldClearApprovals(for payload: ClaudeHookEventPayload) -> Bool {
        if payload.event == "SessionEnd" {
            return true
        }

        if ClaudeTrackedSession.isExplicitRunningEvent(payload.event) {
            return true
        }

        switch payload.event {
        case "PostToolUse", "PostToolUseFailure", "StopFailure", "Stop", "PostCompact":
            return true
        default:
            break
        }

        return false
    }

    private func shouldClearQuestions(for payload: ClaudeHookEventPayload) -> Bool {
        if payload.event == "SessionEnd" {
            return true
        }

        switch payload.event {
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "PostCompact":
            return true
        default:
            return false
        }
    }

    private func hookIssuesLocked() -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []

        if resolvedNodeBinaryPathIfAvailable() == nil {
            issues.append(
                SourceErrorMapper.issue(
                    source: "Claude",
                    severity: .warning,
                    message: "Node.js is unavailable for the managed Claude hook script.",
                    recoverySuggestion: "Install Node.js or add it to PATH, then run “Resync Claude Hooks”.",
                    isRepairable: true
                )
            )
        }

        let scriptURL = hookRootURL.appendingPathComponent(hookScriptName)
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            issues.append(
                SourceErrorMapper.issue(
                    source: "Claude",
                    severity: .warning,
                    message: "The managed Claude hook script is missing.",
                    recoverySuggestion: "Run “Resync Claude Hooks” to recreate the local hook script.",
                    isRepairable: true
                )
            )
        }

        do {
            let settingsURLs = try resolvedClaudeSettingsURLs()
            if settingsURLs.isEmpty {
                issues.append(
                    SourceErrorMapper.issue(
                        source: "Claude",
                        severity: .warning,
                        message: "No Claude settings file was found for managed hook installation.",
                        recoverySuggestion: "Create ~/.claude/settings.json or provide a custom settings path.",
                        isRepairable: true
                    )
                )
            } else {
                for settingsURL in settingsURLs {
                    do {
                        let settings = try loadJSONObjectIfPresent(at: settingsURL) ?? [:]
                        if !settingsContainsManagedHooks(settings) {
                            issues.append(
                                SourceErrorMapper.issue(
                                    source: "Claude",
                                    severity: .warning,
                                    message: "Managed Claude hook entries are missing or have drifted in \(settingsURL.path).",
                                    recoverySuggestion: "Run “Resync Claude Hooks” to restore the managed entries.",
                                    isRepairable: true
                                )
                            )
                        }
                    } catch {
                        issues.append(
                            SourceErrorMapper.issue(
                                source: "Claude",
                                error: error,
                                severity: .error,
                                recoverySuggestion: "Repair the settings file JSON and resync the managed hooks.",
                                isRepairable: true
                            )
                        )
                    }
                }
            }
        } catch {
            issues.append(
                SourceErrorMapper.issue(
                    source: "Claude",
                    error: error,
                    severity: .error,
                    recoverySuggestion: "Inspect the configured Claude settings paths and repair them locally.",
                    isRepairable: true
                )
            )
        }

        return issues
    }

    private func callbackServerIssuesLocked() -> [DiagnosticIssue] {
        if listenerReady {
            return []
        }

        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return [
                SourceErrorMapper.issue(
                    source: "Claude",
                    severity: .warning,
                    message: lastErrorMessage,
                    recoverySuggestion: "Restart or resync the Claude hook integration to recover the local callback listener.",
                    isRepairable: true
                )
            ]
        }

        if listener != nil {
            return [
                SourceErrorMapper.issue(
                    source: "Claude",
                    severity: .info,
                    message: "The local Claude callback listener is still starting.",
                    recoverySuggestion: nil,
                    isRepairable: false
                )
            ]
        }

        return [
            SourceErrorMapper.issue(
                source: "Claude",
                severity: .warning,
                message: "The local Claude callback listener is not running.",
                recoverySuggestion: "Run “Resync Claude Hooks” to restart the local callback listener.",
                isRepairable: true
            )
        ]
    }

    private func cleanupExpiredState(now: Date) {
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivityAt) <= sessionStaleThreshold
        }
        questions = questions.filter { _, question in
            question.prompt.expiresAt.map { now < $0 } ?? true
        }
        questions = questions.filter { _, question in
            isQuestionStillActiveLocked(question, now: now)
        }
        questionOrder = questionOrder.filter { questions[$0] != nil }
        persistLatestQuestionPromptLocked()
    }

    private func isQuestionStillActiveLocked(_ question: ClaudePendingQuestion, now: Date) -> Bool {
        guard let session = sessions[question.prompt.sessionID] else {
            return false
        }

        let projectState = fetchClaudeProjectDerivedState(for: session.rawSessionID, cwd: session.cwd)
        let interruptionState = fetchLatestClaudeInterruption(for: session.rawSessionID, cwd: session.cwd)
        let refreshedSession = refreshedClaudeSession(
            session,
            projectState: projectState,
            interruptionState: interruptionState
        )

        if refreshedSession.status.isTerminal {
            return false
        }

        if refreshedSession.lastEvent == "interrupted" {
            return false
        }

        return now.timeIntervalSince(refreshedSession.lastActivityAt) <= sessionStaleThreshold
    }

    private func latestApprovalRequestLocked() -> ApprovalRequest? {
        for approvalID in approvalOrder.reversed() {
            guard let approval = approvals[approvalID] else {
                continue
            }

            let focusTarget = sessions[approval.sessionID].flatMap(makeClaudeFocusTarget(from:))

            return ApprovalRequest(
                id: approval.id,
                commandSummary: approval.commandSummary,
                commandText: approval.commandText,
                rationale: approval.rationale,
                focusTarget: focusTarget,
                createdAt: approval.createdAt,
                source: .claude,
                resolutionKind: .localHTTPHook
            )
        }

        return nil
    }

    private func latestQuestionPromptLocked() -> ClaudeQuestionPrompt? {
        for questionID in questionOrder.reversed() {
            guard let question = questions[questionID] else {
                continue
            }

            guard !question.prompt.isExpired else {
                continue
            }

            return question.prompt
        }

        return nil
    }

    private func makeSnapshots() -> [AgentSessionSnapshot] {
        var discoveredSessions = sessions
        mergeDiscoveredClaudeSessions(into: &discoveredSessions)

        return discoveredSessions.values.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }.map { session in
            let projectState = fetchClaudeProjectDerivedState(
                for: session.rawSessionID,
                cwd: session.cwd
            )
            let interruptionState = fetchLatestClaudeInterruption(
                for: session.rawSessionID,
                cwd: session.cwd
            )
            let refreshedSession = refreshedClaudeSession(
                session,
                projectState: projectState,
                interruptionState: interruptionState
            )
            writeClaudeDebugLog(
                "snapshot session=\(session.rawSessionID) cwd=\(session.cwd) hook=\(session.lastEvent):\(session.status.debugLabel)@\(session.lastActivityAt.timeIntervalSince1970) project=\(projectState?.lastEvent ?? "nil"):\(projectState?.status.debugLabel ?? "nil")@\(projectState?.at.timeIntervalSince1970 ?? 0) interrupt=\(interruptionState?.at.timeIntervalSince1970 ?? 0) refreshed=\(refreshedSession.lastEvent):\(refreshedSession.status.debugLabel)@\(refreshedSession.lastActivityAt.timeIntervalSince1970)"
            )
            let resolvedStatus = resolvedStatus(for: refreshedSession, now: .now)
            if resolvedStatus.activityState != .running {
                clearApprovals(forSessionID: session.rawSessionID)
            }
            let summarizedSession = ClaudeTrackedSession(
                rawSessionID: session.rawSessionID,
                cwd: refreshedSession.cwd,
                source: refreshedSession.source,
                conversationSummary: refreshedSession.conversationSummary ?? fetchClaudeConversationSummary(
                    for: refreshedSession.rawSessionID,
                    cwd: refreshedSession.cwd
                ),
                clientOrigin: refreshedSession.clientOrigin,
                terminalClient: refreshedSession.terminalClient,
                terminalSessionHint: refreshedSession.terminalSessionHint,
                status: refreshedSession.status,
                lastEvent: refreshedSession.lastEvent,
                lastActivityAt: refreshedSession.lastActivityAt
            )
            let focusTarget = makeClaudeFocusTarget(from: summarizedSession)
            return AgentSessionSnapshot(
                id: "claude:\(summarizedSession.rawSessionID)",
                origin: .claude,
                title: summarizedSession.title,
                detail: summarizedSession.detail,
                activityState: resolvedStatus.activityState,
                updatedAt: summarizedSession.lastActivityAt,
                cwd: summarizedSession.cwd.isEmpty ? nil : summarizedSession.cwd,
                focusTarget: focusTarget,
                freshness: .live
            )
        }
    }

    private func makeClaudeFocusTarget(from session: ClaudeTrackedSession) -> FocusTarget? {
        let workspaceHint = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientOrigin = session.clientOrigin ?? (session.terminalClient != nil ? .claudeCLI : .claudeVSCode)

        if clientOrigin == .claudeCLI, session.terminalClient == nil {
            return nil
        }

        return FocusTarget(
            clientOrigin: clientOrigin,
            sessionID: session.rawSessionID,
            displayName: focusDisplayName(for: clientOrigin, terminalClient: session.terminalClient),
            cwd: workspaceHint.isEmpty ? nil : workspaceHint,
            terminalClient: session.terminalClient,
            terminalSessionHint: session.terminalSessionHint,
            workspaceHint: workspaceHint.isEmpty ? nil : workspaceHint
        )
    }

    private func mergedClaudeSession(
        existing: ClaudeTrackedSession?,
        payload: ClaudeHookEventPayload,
        now: Date
    ) -> ClaudeTrackedSession {
        let incomingStatus = ClaudeTrackedSession.status(for: payload.event, state: payload.state)

        if let existing,
           ClaudeTrackedSession.shouldPreserveExistingStatus(
               existing.status,
               forIncomingEvent: payload.event,
               incomingStatus: incomingStatus
           ) {
            return ClaudeTrackedSession(
                rawSessionID: existing.rawSessionID,
                cwd: payload.cwd.isEmpty ? existing.cwd : payload.cwd,
                source: payload.source.isEmpty ? existing.source : payload.source,
                conversationSummary: existing.conversationSummary,
                clientOrigin: payload.clientOrigin ?? existing.clientOrigin,
                terminalClient: payload.terminalClient ?? existing.terminalClient,
                terminalSessionHint: payload.terminalSessionHint ?? existing.terminalSessionHint,
                status: existing.status,
                lastEvent: payload.event,
                lastActivityAt: now
            )
        }

        if let existing,
           incomingStatus == .running,
           existing.status == .idle,
           !ClaudeTrackedSession.isExplicitRunningEvent(payload.event) {
            return ClaudeTrackedSession(
                rawSessionID: existing.rawSessionID,
                cwd: payload.cwd.isEmpty ? existing.cwd : payload.cwd,
                source: payload.source.isEmpty ? existing.source : payload.source,
                conversationSummary: existing.conversationSummary,
                clientOrigin: payload.clientOrigin ?? existing.clientOrigin,
                terminalClient: payload.terminalClient ?? existing.terminalClient,
                terminalSessionHint: payload.terminalSessionHint ?? existing.terminalSessionHint,
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
                conversationSummary: existing.conversationSummary,
                clientOrigin: payload.clientOrigin ?? existing.clientOrigin,
                terminalClient: payload.terminalClient ?? existing.terminalClient,
                terminalSessionHint: payload.terminalSessionHint ?? existing.terminalSessionHint,
                status: existing.status,
                lastEvent: existing.lastEvent,
                lastActivityAt: existing.lastActivityAt
            )
        }

        return ClaudeTrackedSession(
            rawSessionID: existing?.rawSessionID ?? payload.sessionID,
            cwd: payload.cwd.isEmpty ? existing?.cwd ?? "" : payload.cwd,
            source: payload.source.isEmpty ? existing?.source ?? "" : payload.source,
            conversationSummary: existing?.conversationSummary ?? fetchClaudeConversationSummary(
                for: payload.sessionID,
                cwd: payload.cwd.isEmpty ? existing?.cwd ?? "" : payload.cwd
            ),
            clientOrigin: payload.clientOrigin ?? existing?.clientOrigin,
            terminalClient: payload.terminalClient ?? existing?.terminalClient,
            terminalSessionHint: payload.terminalSessionHint ?? existing?.terminalSessionHint,
            status: incomingStatus,
            lastEvent: payload.event,
            lastActivityAt: now
        )
    }

    private func fetchClaudeConversationSummary(for sessionID: String, cwd: String) -> String? {
        guard !sessionID.isEmpty || !cwd.isEmpty else {
            return nil
        }

        if let sessionFileURL = locateClaudeProjectSessionFile(for: sessionID, cwd: cwd) {
            for line in readRecentLines(from: sessionFileURL, maxBytes: recentHistoryScanBytes).reversed() {
                guard let data = String(line).data(using: .utf8),
                      let entry = try? JSONDecoder().decode(ClaudeProjectHistoryEntry.self, from: data),
                      (sessionID.isEmpty || entry.sessionID == sessionID),
                      let summary = summarizeConversationText(entry.displayText) else {
                    continue
                }

                return summary
            }
        }

        guard !sessionID.isEmpty else {
            return nil
        }

        for line in readRecentLines(from: claudeHistoryURL, maxBytes: recentHistoryScanBytes).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(ClaudeHistoryEntry.self, from: data),
                  entry.sessionID == sessionID,
                  let summary = summarizeConversationText(entry.display) else {
                continue
            }

            return summary
        }

        return nil
    }

    private func fetchClaudeProjectDerivedState(for sessionID: String, cwd: String) -> ClaudeProjectDerivedState? {
        guard !sessionID.isEmpty || !cwd.isEmpty else {
            return nil
        }

        let candidateFiles = candidateClaudeProjectSessionFiles(for: sessionID, cwd: cwd)
        guard !candidateFiles.isEmpty else {
            return nil
        }

        var bestState: ClaudeProjectDerivedState?

        for sessionFileURL in candidateFiles {
            guard let candidateState = fetchClaudeProjectDerivedState(
                from: sessionFileURL,
                expectedSessionID: sessionID
            ) else {
                continue
            }

            if let currentBestState = bestState {
                if shouldPrefer(candidateState, over: currentBestState) {
                    bestState = candidateState
                }
            } else {
                bestState = candidateState
            }
        }

        return bestState
    }

    private func fetchClaudeProjectDerivedState(from sessionFileURL: URL, expectedSessionID: String) -> ClaudeProjectDerivedState? {
        for line in readRecentLines(from: sessionFileURL, maxBytes: recentHistoryScanBytes).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String
            else {
                continue
            }

            if !expectedSessionID.isEmpty,
               expectedSessionID != "default",
               let recordSessionID = record["sessionId"] as? String,
               recordSessionID != expectedSessionID {
                continue
            }

            let timestampString = record["timestamp"] as? String
            let timestamp = timestampString.flatMap(historyTimestampFormatter.date(from:)) ?? .now

            if type == "queue-operation",
               let operation = record["operation"] as? String {
                switch operation {
                case "enqueue", "dequeue":
                    return ClaudeProjectDerivedState(status: .running, lastEvent: operation, at: timestamp)
                default:
                    break
                }
            }

            if type == "assistant",
               let message = record["message"] as? [String: Any] {
                if assistantMessageContainsThinkingBlock(message) {
                    return ClaudeProjectDerivedState(status: .running, lastEvent: "assistant_thinking", at: timestamp)
                }

                let stopReason = message["stop_reason"] as? String
                if stopReason == "tool_use" {
                    return ClaudeProjectDerivedState(status: .running, lastEvent: "tool_use", at: timestamp)
                }

                if stopReason == "end_turn" {
                    return ClaudeProjectDerivedState(status: .success, lastEvent: "end_turn", at: timestamp)
                }

                if stopReason == nil {
                    return ClaudeProjectDerivedState(status: .running, lastEvent: "assistant_thinking", at: timestamp)
                }
            }

            if type == "system",
               let subtype = record["subtype"] as? String,
               subtype == "api_error" {
                return ClaudeProjectDerivedState(status: .failure, lastEvent: "api_error", at: timestamp)
            }

            if type == "user",
               let message = record["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]] {
                    let interrupted = content.contains { item in
                        if let text = item["text"] as? String,
                           text.localizedCaseInsensitiveContains("[Request interrupted by user") {
                            return true
                        }

                        if let itemType = item["type"] as? String,
                           itemType == "tool_result",
                           let isError = item["is_error"] as? Bool,
                           isError,
                           let text = item["content"] as? String,
                           text.localizedCaseInsensitiveContains("doesn't want to proceed with this tool use") {
                            return true
                        }

                        return false
                    }

                    if interrupted {
                        return ClaudeProjectDerivedState(status: .idle, lastEvent: "interrupted", at: timestamp)
                    }
                }

                return ClaudeProjectDerivedState(status: .idle, lastEvent: "user_prompt", at: timestamp)
            }
        }

        return nil
    }

    private func assistantMessageContainsThinkingBlock(_ message: [String: Any]) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else {
            return false
        }

        return content.contains { item in
            (item["type"] as? String) == "thinking"
        }
    }

    private func fetchLatestClaudeInterruption(for sessionID: String, cwd: String) -> ClaudeProjectDerivedState? {
        let candidateFiles = candidateClaudeProjectSessionFiles(for: sessionID, cwd: cwd)
        let candidatePaths = candidateFiles.map(\.path).joined(separator: " | ")
        writeClaudeDebugLog(
            "interrupt-scan session=\(sessionID) cwd=\(cwd) candidates=\(candidatePaths)"
        )
        guard !candidateFiles.isEmpty else {
            return nil
        }

        var latestInterruption: ClaudeProjectDerivedState?

        for sessionFileURL in candidateFiles {
            for line in readRecentLines(from: sessionFileURL, maxBytes: recentHistoryScanBytes).reversed() {
                guard let data = String(line).data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = record["type"] as? String,
                      type == "user"
                else {
                    continue
                }

                if !sessionID.isEmpty,
                   sessionID != "default",
                   let recordSessionID = record["sessionId"] as? String,
                   recordSessionID != sessionID {
                    continue
                }

                guard let message = record["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else {
                    continue
                }

                let interrupted = content.contains { item in
                    if let text = item["text"] as? String,
                       text.localizedCaseInsensitiveContains("[Request interrupted by user") {
                        return true
                    }

                    if let itemType = item["type"] as? String,
                       itemType == "tool_result",
                       let isError = item["is_error"] as? Bool,
                       isError,
                       let text = item["content"] as? String,
                       text.localizedCaseInsensitiveContains("doesn't want to proceed with this tool use") {
                        return true
                    }

                    return false
                }

                guard interrupted else {
                    continue
                }

                let timestampString = record["timestamp"] as? String
                let timestamp = timestampString.flatMap(historyTimestampFormatter.date(from:)) ?? .now
                let candidate = ClaudeProjectDerivedState(status: .idle, lastEvent: "interrupted", at: timestamp)
                writeClaudeDebugLog(
                    "interrupt-hit session=\(sessionID) file=\(sessionFileURL.path) at=\(timestamp.timeIntervalSince1970)"
                )

                if let currentLatestInterruption = latestInterruption {
                    if candidate.at > currentLatestInterruption.at {
                        latestInterruption = candidate
                    }
                } else {
                    latestInterruption = candidate
                }
                break
            }
        }

        return latestInterruption
    }

    private func shouldPrefer(_ lhs: ClaudeProjectDerivedState, over rhs: ClaudeProjectDerivedState) -> Bool {
        let lhsPriority = claudeProjectStatePriority(lhs)
        let rhsPriority = claudeProjectStatePriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }

        return lhs.at > rhs.at
    }

    private func claudeProjectStatePriority(_ state: ClaudeProjectDerivedState) -> Int {
        switch state.lastEvent {
        case "interrupted":
            return 4
        case "tool_use", "assistant_thinking", "api_error", "end_turn":
            return 3
        case "user_prompt":
            return 1
        default:
            return 2
        }
    }

    private func candidateClaudeProjectSessionFiles(for sessionID: String, cwd: String) -> [URL] {
        var candidates: [URL] = []

        if !sessionID.isEmpty,
           sessionID != "default",
           let directMatch = locateClaudeProjectSessionFileBySessionID(sessionID) {
            candidates.append(directMatch)
        }

        if !cwd.isEmpty,
           let cwdMatch = locateLatestClaudeProjectSessionFile(forCWD: cwd) {
            candidates.append(cwdMatch)
        }

        candidates.append(contentsOf: locateLatestClaudeProjectSessionFilesGlobally(limit: recentClaudeProjectFileLimit))

        var seenPaths = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, !seenPaths.contains(path) else {
                return false
            }
            seenPaths.insert(path)
            return true
        }
    }

    private func locateClaudeProjectSessionFile(for sessionID: String, cwd: String) -> URL? {
        if !sessionID.isEmpty,
           sessionID != "default",
           let directMatch = locateClaudeProjectSessionFileBySessionID(sessionID) {
            return directMatch
        }

        if !cwd.isEmpty,
           let cwdMatch = locateLatestClaudeProjectSessionFile(forCWD: cwd) {
            return cwdMatch
        }

        if !sessionID.isEmpty {
            if let directMatch = locateClaudeProjectSessionFileBySessionID(sessionID) {
                return directMatch
            }
        }

        if sessionID == "default" || cwd.isEmpty {
            return locateLatestClaudeProjectSessionFileGlobally()
        }

        return nil
    }

    private func locateClaudeProjectSessionFileBySessionID(_ sessionID: String) -> URL? {
        guard let directoryURLs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for directoryURL in directoryURLs {
            let candidate = directoryURL.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func locateLatestClaudeProjectSessionFile(forCWD cwd: String) -> URL? {
        let normalizedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCWD.isEmpty else {
            return nil
        }

        let directoryURL = claudeProjectsRootURL.appendingPathComponent(
            sanitizedClaudeProjectsDirectoryName(for: normalizedCWD)
        )
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return fileURLs
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    private func locateLatestClaudeProjectSessionFileGlobally() -> URL? {
        locateLatestClaudeProjectSessionFilesGlobally(limit: 1).first
    }

    private func locateLatestClaudeProjectSessionFilesGlobally(limit: Int) -> [URL] {
        guard let directoryURLs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var allFiles: [(url: URL, modifiedAt: Date)] = []

        for directoryURL in directoryURLs {
            guard let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in fileURLs where fileURL.pathExtension == "jsonl" {
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                allFiles.append((fileURL, modifiedAt))
            }
        }

        return allFiles
            .sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
            .prefix(max(1, limit))
            .map(\.url)
    }

    private func sanitizedClaudeProjectsDirectoryName(for cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else {
            return "-"
        }

        return trimmed.replacingOccurrences(of: "/", with: "-")
    }

    private func refreshedClaudeSession(
        _ session: ClaudeTrackedSession,
        projectState: ClaudeProjectDerivedState?,
        interruptionState: ClaudeProjectDerivedState?
    ) -> ClaudeTrackedSession {
        if let projectState,
           projectState.lastEvent == "user_prompt" {
            if Date().timeIntervalSince(projectState.at) < claudePromptRunningWindow {
                return ClaudeTrackedSession(
                    rawSessionID: session.rawSessionID,
                    cwd: session.cwd,
                    source: session.source,
                    conversationSummary: session.conversationSummary,
                    clientOrigin: session.clientOrigin,
                    terminalClient: session.terminalClient,
                    terminalSessionHint: session.terminalSessionHint,
                    status: .running,
                    lastEvent: projectState.lastEvent,
                    lastActivityAt: projectState.at
                )
            }
        }

        if session.status == .running,
           session.lastEvent == "UserPromptSubmit",
           projectState?.lastEvent == "user_prompt" {
            let promptReferenceAt = max(session.lastActivityAt, projectState?.at ?? .distantPast)
            if Date().timeIntervalSince(promptReferenceAt) >= stalledPromptFallbackWindow {
                writeClaudeDebugLog(
                    "stalled-prompt-fallback session=\(session.rawSessionID) promptAt=\(promptReferenceAt.timeIntervalSince1970)"
                )
                return ClaudeTrackedSession(
                    rawSessionID: session.rawSessionID,
                    cwd: session.cwd,
                    source: session.source,
                    conversationSummary: session.conversationSummary,
                    clientOrigin: session.clientOrigin,
                    terminalClient: session.terminalClient,
                    terminalSessionHint: session.terminalSessionHint,
                    status: .idle,
                    lastEvent: "stalled_prompt",
                    lastActivityAt: promptReferenceAt
                )
            }
        }

        if session.status == .running,
           let interruptionState {
            let projectRunningAfterInterrupt =
                projectState?.status == .running &&
                (projectState?.at ?? .distantPast).timeIntervalSince(interruptionState.at) > 1
            let explicitHookRunningAfterInterrupt =
                ClaudeTrackedSession.isExplicitRunningEvent(session.lastEvent) &&
                session.lastActivityAt.timeIntervalSince(interruptionState.at) > interruptionOverrideWindow

            writeClaudeDebugLog(
                "refresh session=\(session.rawSessionID) hook=\(session.lastEvent):\(session.status)@\(session.lastActivityAt.timeIntervalSince1970) project=\(projectState?.lastEvent ?? "nil"):\(projectState?.status.debugLabel ?? "nil")@\(projectState?.at.timeIntervalSince1970 ?? 0) interrupt=\(interruptionState.at.timeIntervalSince1970) projectRunningAfterInterrupt=\(projectRunningAfterInterrupt) explicitHookRunningAfterInterrupt=\(explicitHookRunningAfterInterrupt)"
            )

            if !projectRunningAfterInterrupt && !explicitHookRunningAfterInterrupt {
                return ClaudeTrackedSession(
                    rawSessionID: session.rawSessionID,
                    cwd: session.cwd,
                    source: session.source,
                    conversationSummary: session.conversationSummary,
                    clientOrigin: session.clientOrigin,
                    terminalClient: session.terminalClient,
                    terminalSessionHint: session.terminalSessionHint,
                    status: .idle,
                    lastEvent: interruptionState.lastEvent,
                    lastActivityAt: interruptionState.at
                )
            }
        }

        if session.status == .running,
           let interruptionState,
           interruptionState.at.timeIntervalSince(session.lastActivityAt) >= -interruptionOverrideWindow {
            return ClaudeTrackedSession(
                rawSessionID: session.rawSessionID,
                cwd: session.cwd,
                source: session.source,
                conversationSummary: session.conversationSummary,
                clientOrigin: session.clientOrigin,
                terminalClient: session.terminalClient,
                terminalSessionHint: session.terminalSessionHint,
                status: .idle,
                lastEvent: interruptionState.lastEvent,
                lastActivityAt: interruptionState.at
            )
        }

        guard let projectState else {
            return session
        }

        if session.status == .running,
           projectState.status == .idle,
           projectState.lastEvent != "interrupted" {
            return session
        }

        if session.status == .running,
           projectState.status == .idle,
           projectState.at.timeIntervalSince(session.lastActivityAt) >= -interruptionOverrideWindow {
            return ClaudeTrackedSession(
                rawSessionID: session.rawSessionID,
                cwd: session.cwd,
                source: session.source,
                conversationSummary: session.conversationSummary,
                clientOrigin: session.clientOrigin,
                terminalClient: session.terminalClient,
                terminalSessionHint: session.terminalSessionHint,
                status: .idle,
                lastEvent: projectState.lastEvent,
                lastActivityAt: projectState.at
            )
        }

        if projectState.at >= session.lastActivityAt {
            return ClaudeTrackedSession(
                rawSessionID: session.rawSessionID,
                cwd: session.cwd,
                source: session.source,
                conversationSummary: session.conversationSummary,
                clientOrigin: session.clientOrigin,
                terminalClient: session.terminalClient,
                terminalSessionHint: session.terminalSessionHint,
                status: projectState.status,
                lastEvent: projectState.lastEvent,
                lastActivityAt: projectState.at
            )
        }

        if session.status != .running {
            return ClaudeTrackedSession(
                rawSessionID: session.rawSessionID,
                cwd: session.cwd,
                source: session.source,
                conversationSummary: session.conversationSummary,
                clientOrigin: session.clientOrigin,
                terminalClient: session.terminalClient,
                terminalSessionHint: session.terminalSessionHint,
                status: projectState.status,
                lastEvent: projectState.lastEvent,
                lastActivityAt: session.lastActivityAt
            )
        }

        return ClaudeTrackedSession(
            rawSessionID: session.rawSessionID,
            cwd: session.cwd,
            source: session.source,
            conversationSummary: session.conversationSummary,
            clientOrigin: session.clientOrigin,
            terminalClient: session.terminalClient,
            terminalSessionHint: session.terminalSessionHint,
            status: session.status,
            lastEvent: session.lastEvent,
            lastActivityAt: session.lastActivityAt
        )
    }

    private func mergeDiscoveredClaudeSessions(into target: inout [String: ClaudeTrackedSession]) {
        let discovered = discoverClaudeSessions()
        guard !discovered.isEmpty else {
            return
        }

        for record in discovered {
            if let existing = target[record.sessionID] {
                target[record.sessionID] = ClaudeTrackedSession(
                    rawSessionID: existing.rawSessionID,
                    cwd: existing.cwd.isEmpty ? record.cwd : existing.cwd,
                    source: existing.source.isEmpty ? record.source : existing.source,
                    conversationSummary: existing.conversationSummary,
                    clientOrigin: existing.clientOrigin ?? record.clientOrigin,
                    terminalClient: existing.terminalClient,
                    terminalSessionHint: existing.terminalSessionHint,
                    status: existing.status,
                    lastEvent: existing.lastEvent,
                    lastActivityAt: max(existing.lastActivityAt, record.lastActivityAt)
                )
            } else {
                target[record.sessionID] = ClaudeTrackedSession(
                    rawSessionID: record.sessionID,
                    cwd: record.cwd,
                    source: record.source,
                    conversationSummary: fetchClaudeConversationSummary(for: record.sessionID, cwd: record.cwd),
                    clientOrigin: record.clientOrigin,
                    terminalClient: nil,
                    terminalSessionHint: nil,
                    status: .idle,
                    lastEvent: "SessionDiscovered",
                    lastActivityAt: record.lastActivityAt
                )
            }
        }
    }

    private func discoverClaudeSessions() -> [ClaudeDiscoveredSession] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: claudeSessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "json",
                  let data = try? Data(contentsOf: fileURL),
                  let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data) else {
                return nil
            }

            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let startedAt = record.startedAt.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? modifiedAt
            let lastActivityAt = max(startedAt, modifiedAt)

            return ClaudeDiscoveredSession(
                sessionID: record.sessionID,
                cwd: record.cwd,
                source: record.entrypoint ?? record.kind ?? "",
                clientOrigin: clientOrigin(for: record.entrypoint),
                lastActivityAt: lastActivityAt
            )
        }
    }

    private func clientOrigin(for entrypoint: String?) -> FocusClientOrigin {
        switch entrypoint?.lowercased() {
        case "claude-vscode":
            return .claudeVSCode
        default:
            return .claudeCLI
        }
    }

    private func focusDisplayName(for origin: FocusClientOrigin, terminalClient: TerminalClient?) -> String {
        switch origin {
        case .claudeVSCode:
            return "VS Code Claude"
        case .claudeCLI:
            return "\(terminalClient?.displayName ?? TerminalClient.unknown.displayName) Claude"
        default:
            return origin.displayName
        }
    }

    private func writeClaudeDebugLog(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if !FileManager.default.fileExists(atPath: claudeDebugLogURL.path) {
            _ = FileManager.default.createFile(atPath: claudeDebugLogURL.path, contents: data)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: claudeDebugLogURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func readRecentLines(from fileURL: URL, maxBytes: Int) -> [Substring] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }

        defer {
            try? handle.close()
        }

        let byteCount = UInt64(max(1, maxBytes))
        let startOffset = fileSize.uint64Value > byteCount ? fileSize.uint64Value - byteCount : 0

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

    private func summarizeConversationText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<environment_context>") else {
            return nil
        }

        let singleLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.isEmpty else {
            return nil
        }

        if singleLine.count <= 72 {
            return singleLine
        }

        return String(singleLine.prefix(72)) + "..."
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

    private func permissionCommandText(_ payload: ClaudeHookPermissionPayload) -> String {
        if let command = payload.toolInput?.command, !command.isEmpty {
            return normalizedCommandText(command)
        }

        if let path = payload.toolInput?.filePath, !path.isEmpty {
            return path
        }

        return payload.toolName
    }

    private func makeQuestionPrompt(from payload: ClaudeHookElicitationPayload, sessionID: String) -> ClaudeQuestionPrompt {
        let createdAt = Date()
        let normalizedField = payload.requestedSchema?.primaryField
        let options = normalizedField?.options ?? []
        let allowsFreeText = normalizedField?.allowsFreeText ?? true
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? payload.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Claude is asking a question"
        let detailParts = [
            payload.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            payload.mcpServerName.isEmpty ? nil : "Server: \(payload.mcpServerName)"
        ].compactMap { $0 }

        return ClaudeQuestionPrompt(
            id: payload.elicitationID?.nilIfEmpty ?? UUID().uuidString,
            sessionID: sessionID,
            title: title,
            message: payload.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "\n"),
            options: options,
            allowsFreeText: allowsFreeText,
            placeholder: normalizedField?.placeholder,
            defaultText: normalizedField?.defaultValue,
            createdAt: createdAt,
            expiresAt: payload.timeoutSeconds.map { createdAt.addingTimeInterval(TimeInterval($0)) },
            source: .claude
        )
    }

    private func makeQuestionPrompt(
        from payload: ClaudeHookAskUserQuestionPayload,
        sessionID: String,
        handlingMode: AskUserQuestionHandlingMode
    ) -> ClaudeQuestionPrompt {
        let createdAt = Date()
        let askQuestion = payload.toolInput?.questions.first
        let options = askQuestion?.options.enumerated().map { index, option in
            QuestionOption(
                id: "\(payload.toolUseID ?? sessionID)-\(index)",
                title: option.label,
                detail: option.description,
                value: option.label,
                isDefault: false
            )
        } ?? []

        return ClaudeQuestionPrompt(
            id: payload.toolUseID?.nilIfEmpty ?? UUID().uuidString,
            sessionID: sessionID,
            title: askQuestion?.header?.nilIfEmpty ?? "Claude Needs Input",
            message: askQuestion?.question.nilIfEmpty,
            detail: handlingMode.promptHint,
            options: options,
            allowsFreeText: true,
            placeholder: "Type another answer",
            defaultText: nil,
            createdAt: createdAt,
            expiresAt: nil,
            source: .claude
        )
    }

    private func makeElicitationDecision(
        for response: ClaudeQuestionResponse,
        pendingQuestion: ClaudePendingQuestion
    ) -> String {
        let content = elicitationContent(from: response, pendingQuestion: pendingQuestion)
        let body: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "Elicitation",
                "action": "accept",
                "content": content
            ]
        ]

        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? "{\"hookSpecificOutput\":{\"hookEventName\":\"Elicitation\",\"action\":\"decline\",\"content\":{}}}"
    }

    private func makeDeclineElicitationDecision() -> String {
        let body: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "Elicitation",
                "action": "decline",
                "content": [:]
            ]
        ]

        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? "{\"hookSpecificOutput\":{\"hookEventName\":\"Elicitation\",\"action\":\"decline\",\"content\":{}}}"
    }

    private func makeAskUserQuestionDecision(
        for response: ClaudeQuestionResponse,
        pendingQuestion: ClaudePendingQuestion
    ) -> String {
        guard case let .askUserQuestion(payload) = pendingQuestion.source else {
            return makeDenyPreToolUseDecision()
        }

        let answerValue = response.textAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? response.selectedOptionValue?.nilIfEmpty
            ?? response.displaySummary.nilIfEmpty

        guard let toolInput = payload.toolInput,
              let askQuestion = toolInput.questions.first,
              let answerValue else {
            return makeDenyPreToolUseDecision()
        }

        var updatedInput = toolInput.jsonObject
        updatedInput["answers"] = [
            "0": answerValue,
            askQuestion.question: answerValue
        ]
        return makeAllowPreToolUseDecision(updatedInput: updatedInput)
    }

    private func makeAllowPreToolUseDecision(updatedInput: [String: Any]?) -> String {
        var hookOutput: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow"
        ]
        if let updatedInput {
            hookOutput["updatedInput"] = updatedInput
        }

        let body: [String: Any] = ["hookSpecificOutput": hookOutput]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"}}"
    }

    private func makePassThroughPreToolUseDecision(updatedInput: [String: Any]?) -> String {
        // Let Claude continue with its native AskUserQuestion flow without creating an extra approval step.
        makeAllowPreToolUseDecision(updatedInput: updatedInput)
    }

    private func askUserQuestionHandlingMode() -> AskUserQuestionHandlingMode {
        AskUserQuestionHandlingMode(
            rawValue: UserDefaults.standard.string(forKey: askUserQuestionModeDefaultsKey) ?? ""
        ) ?? .takeOver
    }

    private func makeDenyPreToolUseDecision() -> String {
        let body: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny"
            ]
        ]

        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}"
    }

    private func elicitationContent(
        from response: ClaudeQuestionResponse,
        pendingQuestion: ClaudePendingQuestion
    ) -> [String: Any] {
        let trimmedText = response.textAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answerValue = response.selectedOptionValue?.nilIfEmpty ?? trimmedText?.nilIfEmpty ?? response.displaySummary
        guard !answerValue.isEmpty else {
            return [:]
        }

        guard case let .elicitation(payload) = pendingQuestion.source else {
            return [:]
        }
        let requestedSchema = payload.requestedSchema
        let primaryFieldName = requestedSchema?.primaryField?.name ?? "answer"
        return [primaryFieldName: answerValue]
    }

    private func persistLatestQuestionPromptLocked() {
        guard let prompt = latestQuestionPromptLocked() else {
            clearPersistedQuestionPrompt()
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(prompt) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: questionStateRootURL, withIntermediateDirectories: true)
            try data.write(to: latestQuestionStateURL, options: .atomic)
        } catch {
            return
        }
    }

    private func clearPersistedQuestionPrompt() {
        try? FileManager.default.removeItem(at: latestQuestionStateURL)
    }

    private func summarizeCommand(_ command: String) -> String {
        let singleLine = normalizedCommandText(command)

        guard singleLine.count > 96 else {
            return singleLine
        }

        return String(singleLine.prefix(96)) + "..."
    }

    private func normalizedCommandText(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        const fs = require("fs");
        const path = require("path");

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
        const USAGE_CACHE_PATH = \(String(reflecting: claudeUsageCacheURL.path));
        const STATUSLINE_DEBUG_PATH = \(String(reflecting: claudeStatusLineDebugURL.path));
        const ASK_USER_QUESTION_MIRROR_PATH = \(String(reflecting: askUserQuestionHookPath));
        const ASK_USER_QUESTION_MIRROR_ENABLED = \(askUserQuestionHandlingMode() == .mirror ? "true" : "false");

        const event = process.argv[2];
        if (event === "StatusLine") {
          handleStatusLine();
          return;
        }
        if (!EVENT_TO_STATE[event]) process.exit(0);

        const chunks = [];
        let sent = false;

        process.stdin.on("data", (chunk) => chunks.push(chunk));
        process.stdin.on("end", send);
        setTimeout(send, 350);

        function send() {
          if (sent) return;
          sent = true;

          const rawInput = Buffer.concat(chunks).toString("utf8");
          let payload = {};
          try {
            payload = JSON.parse(rawInput);
          } catch {}

          writeUsageSnapshot(payload);
          const shouldMirrorAskUserQuestion =
            ASK_USER_QUESTION_MIRROR_ENABLED &&
            event === "PreToolUse" &&
            payload?.tool_name === "AskUserQuestion" &&
            rawInput.trim().length > 0;

          const body = JSON.stringify({
            event,
            state: EVENT_TO_STATE[event],
            session_id: payload.session_id || "default",
            cwd: payload.cwd || "",
            source: payload.source || payload.reason || "",
            client_origin: detectClientOrigin(),
            terminal_client: detectTerminalClient(),
            terminal_session_hint: detectTerminalSessionHint()
          });

          let pendingRequests = 1 + (shouldMirrorAskUserQuestion ? 1 : 0);
          let finished = false;
          const finish = () => {
            if (finished) return;
            pendingRequests -= 1;
            if (pendingRequests <= 0) {
              finished = true;
              process.exit(0);
            }
          };
          const forceExit = () => {
            if (finished) return;
            finished = true;
            process.exit(0);
          };
          setTimeout(forceExit, 900);

          if (shouldMirrorAskUserQuestion) {
            postAskUserQuestionMirror(rawInput, finish);
          }
          postStateUpdate(body, finish);
        }

        function postStateUpdate(body, onDone) {
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
            res.on("end", onDone);
          });

          req.on("error", onDone);
          req.on("timeout", () => {
            req.destroy();
            onDone();
          });
          req.write(body);
          req.end();
        }

        function postAskUserQuestionMirror(input, onDone) {
          const req = http.request({
            hostname: "127.0.0.1",
            port: \(listenerPort),
            path: ASK_USER_QUESTION_MIRROR_PATH,
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(input)
            },
            timeout: 500
          }, (res) => {
            res.resume();
            res.on("end", onDone);
          });

          req.on("error", onDone);
          req.on("timeout", () => {
            req.destroy();
            onDone();
          });
          req.write(input);
          req.end();
        }

        function handleStatusLine() {
          const input = readAllStdin();
          let payload = {};
          try {
            payload = JSON.parse(input);
          } catch {}

          writeStatusLineDebug(payload);
          writeUsageSnapshot(payload);

          const model = payload?.model?.display_name;
          const contextRemaining = normalizePercentage(payload?.context_window?.remaining_percentage);
          const parts = [];
          if (typeof model === "string" && model.trim().length > 0) {
            parts.push(model.trim());
          }
          if (contextRemaining != null) {
            parts.push(`${Math.round(contextRemaining * 100)}% ctx`);
          }
          process.stdout.write(parts.join(" | "));
          process.exit(0);
        }

        function readAllStdin() {
          try {
            return fs.readFileSync(0, "utf8");
          } catch {
            return "";
          }
        }

        function writeUsageSnapshot(payload) {
          const fiveHour = findWindow("five_hour", payload);
          const sevenDay = findWindow("seven_day", payload);
          if (!fiveHour && !sevenDay) return;

          const usage = {};
          if (fiveHour) usage.five_hour = fiveHour;
          if (sevenDay) usage.seven_day = sevenDay;

          try {
            const directory = path.dirname(USAGE_CACHE_PATH);
            fs.mkdirSync(directory, { recursive: true });
            const tempPath = `${USAGE_CACHE_PATH}.tmp`;
            fs.writeFileSync(tempPath, JSON.stringify(usage, null, 2), "utf8");
            fs.renameSync(tempPath, USAGE_CACHE_PATH);
          } catch {}
        }

        function writeStatusLineDebug(payload) {
          try {
            const directory = path.dirname(STATUSLINE_DEBUG_PATH);
            fs.mkdirSync(directory, { recursive: true });
            const tempPath = `${STATUSLINE_DEBUG_PATH}.tmp`;
            fs.writeFileSync(tempPath, JSON.stringify(payload, null, 2), "utf8");
            fs.renameSync(tempPath, STATUSLINE_DEBUG_PATH);
          } catch {}
        }

        function findWindow(targetKey, value) {
          if (!value) return null;

          if (Array.isArray(value)) {
            for (const item of value) {
              const nested = findWindow(targetKey, item);
              if (nested) return nested;
            }
            return null;
          }

          if (typeof value !== "object") return null;

          if (Object.prototype.hasOwnProperty.call(value, targetKey)) {
            return normalizeWindow(value[targetKey]);
          }

          for (const nestedValue of Object.values(value)) {
            const nested = findWindow(targetKey, nestedValue);
            if (nested) return nested;
          }

          return null;
        }

        function normalizeWindow(candidate) {
          if (!candidate || typeof candidate !== "object") return null;

          const rawPercentage = normalizePercentage(candidate.used_percentage ?? candidate.utilization);
          if (rawPercentage == null) return null;

          const normalized = { used_percentage: rawPercentage };
          const resetsAt = normalizeDate(candidate.resets_at);
          if (resetsAt) normalized.resets_at = resetsAt;
          return normalized;
        }

        function normalizePercentage(value) {
          if (value == null) return null;
          const numeric = typeof value === "number" ? value : Number(value);
          if (!Number.isFinite(numeric)) return null;
          if (numeric > 1) return clamp(numeric / 100, 0, 1);
          return clamp(numeric, 0, 1);
        }

        function normalizeDate(value) {
          if (value == null) return null;
          if (typeof value === "number" && Number.isFinite(value)) {
            return new Date(value * 1000).toISOString();
          }
          if (typeof value === "string" && value.trim().length > 0) {
            const timestamp = Number(value);
            if (Number.isFinite(timestamp)) {
              return new Date(timestamp * 1000).toISOString();
            }

            const parsed = new Date(value);
            if (!Number.isNaN(parsed.getTime())) {
              return parsed.toISOString();
            }
          }
          return null;
        }

        function clamp(value, min, max) {
          return Math.min(Math.max(value, min), max);
        }

        function detectTerminalClient() {
          const env = process.env;
          const termProgram = typeof env.TERM_PROGRAM === "string" ? env.TERM_PROGRAM.trim() : "";

          if (termProgram === "WarpTerminal" || env.WARP_IS_LOCAL_SHELL_SESSION === "1") return "warp";
          if (termProgram === "iTerm.app" || typeof env.ITERM_SESSION_ID === "string") return "iTerm";
          if (termProgram === "Apple_Terminal" || typeof env.TERM_SESSION_ID === "string") return "terminal";
          if (termProgram === "WezTerm" || typeof env.WEZTERM_EXECUTABLE === "string") return "wezTerm";
          if (termProgram === "ghostty" || typeof env.GHOSTTY_RESOURCES_DIR === "string") return "ghostty";
          if (termProgram === "Alacritty" || typeof env.ALACRITTY_SOCKET === "string") return "alacritty";

          return "";
        }

        function detectClientOrigin() {
          const env = process.env;

          if (typeof env.CURSOR_TRACE_ID === "string" || typeof env.CURSOR_AGENT === "string") {
            return "claudeVSCode";
          }

          if (typeof env.VSCODE_PID === "string" || typeof env.VSCODE_IPC_HOOK === "string") {
            return "claudeVSCode";
          }

          return detectTerminalClient() ? "claudeCLI" : "";
        }

        function detectTerminalSessionHint() {
          const env = process.env;
          const candidates = [
            env.ITERM_SESSION_ID,
            env.TERM_SESSION_ID,
            env.WEZTERM_PANE,
            env.WARP_SESSION_ID,
            env.GHOSTTY_SESSION_ID
          ];

          for (const candidate of candidates) {
            if (typeof candidate === "string" && candidate.trim().length > 0) {
              return candidate.trim();
            }
          }

          return "";
        }
        """
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
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
            "WorktreeCreate"
        ]

        let permissionURL = "http://127.0.0.1:\(listenerPort)\(permissionHookPath)"
        let questionURL = "http://127.0.0.1:\(listenerPort)\(questionHookPath)"
        let askUserQuestionURL = "http://127.0.0.1:\(listenerPort)\(askUserQuestionHookPath)"
        let askUserQuestionMode = askUserQuestionHandlingMode()
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
                    permissionURL: permissionURL,
                    questionURL: questionURL,
                    askUserQuestionURL: askUserQuestionURL,
                    askUserQuestionMode: askUserQuestionMode
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
        permissionURL: String,
        questionURL: String,
        askUserQuestionURL: String,
        askUserQuestionMode: AskUserQuestionHandlingMode
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
        hooks["Elicitation"] = upsertHTTPHook(into: hooks["Elicitation"], url: questionURL)
        switch askUserQuestionMode {
        case .takeOver:
            hooks["PreToolUse"] = upsertMatchedHTTPHook(
                into: hooks["PreToolUse"],
                matcher: "AskUserQuestion",
                url: askUserQuestionURL
            )
        case .mirror:
            hooks["PreToolUse"] = removingManagedMatchedHook(
                from: hooks["PreToolUse"],
                matcher: "AskUserQuestion"
            )
        }

        var updatedSettings = settings
        updatedSettings["hooks"] = hooks
        updatedSettings["statusLine"] = [
            "type": "command",
            "command": "\"\(nodePath)\" \"\(scriptPath)\" StatusLine"
        ]
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

    private func removeManagedHooks(from settingsURL: URL) throws {
        let settings = try loadJSONObjectIfPresent(at: settingsURL) ?? [:]
        let existingHooks = settings["hooks"] as? [String: Any]

        var updatedHooks: [String: Any] = [:]
        if let existingHooks {
            for (event, value) in existingHooks {
                let cleanedEntries = removingManagedHooks(from: value)
                if !cleanedEntries.isEmpty {
                    updatedHooks[event] = cleanedEntries
                }
            }
        }

        var updatedSettings = settings
        if updatedHooks.isEmpty {
            updatedSettings.removeValue(forKey: "hooks")
        } else {
            updatedSettings["hooks"] = updatedHooks
        }

        if let statusLine = settings["statusLine"] as? [String: Any],
           isManagedStatusLine(statusLine) {
            updatedSettings.removeValue(forKey: "statusLine")
        }

        try writeJSONObject(updatedSettings, to: settingsURL)
    }

    private func removingManagedHooks(from existingValue: Any?) -> [[String: Any]] {
        let entries = (existingValue as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            guard var hooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            hooks.removeAll(where: isManagedHook)
            guard !hooks.isEmpty else {
                return nil
            }

            var updated = entry
            updated["hooks"] = hooks
            return updated
        }
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
        var keptManagedHook = false

        for index in entries.indices {
            guard let hooks = entries[index]["hooks"] as? [[String: Any]] else {
                continue
            }

            var updatedHooks: [[String: Any]] = []
            updatedHooks.reserveCapacity(hooks.count)

            for var hook in hooks {
                guard let hookURL = hook["url"] as? String,
                      ownedManagedHookURLs.contains(hookURL)
                else {
                    updatedHooks.append(hook)
                    continue
                }

                if keptManagedHook {
                    found = true
                    continue
                }

                hook["type"] = "http"
                hook["url"] = url
                hook["timeout"] = 600
                updatedHooks.append(hook)
                keptManagedHook = true
                found = true
            }

            entries[index]["hooks"] = updatedHooks
        }

        entries.removeAll { entry in
            let hooks = (entry["hooks"] as? [[String: Any]]) ?? []
            return hooks.isEmpty
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

    private func upsertMatchedHTTPHook(into existingValue: Any?, matcher: String, url: String) -> [[String: Any]] {
        upsertMatchedManagedHook(
            into: existingValue,
            matcher: matcher,
            hook: [
                "type": "http",
                "url": url,
                "timeout": 600
            ]
        )
    }

    private func upsertMatchedManagedHook(
        into existingValue: Any?,
        matcher: String,
        hook: [String: Any]
    ) -> [[String: Any]] {
        var entries = (existingValue as? [[String: Any]]) ?? []
        var found = false

        for index in entries.indices {
            let existingMatcher = entries[index]["matcher"] as? String ?? ""
            guard existingMatcher == matcher else {
                continue
            }

            var hooks = (entries[index]["hooks"] as? [[String: Any]]) ?? []
            hooks.removeAll(where: isManagedHook)
            hooks.append(hook)
            entries[index]["hooks"] = hooks
            found = true
        }

        if !found {
            entries.append([
                "matcher": matcher,
                "hooks": [hook]
            ])
        }

        return entries
    }

    private func removingManagedMatchedHook(from existingValue: Any?, matcher: String) -> [[String: Any]] {
        let entries = (existingValue as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            let existingMatcher = entry["matcher"] as? String ?? ""
            guard existingMatcher == matcher else {
                return entry
            }

            guard var hooks = entry["hooks"] as? [[String: Any]] else {
                return nil
            }

            hooks.removeAll(where: isManagedHook)
            guard !hooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = hooks
            return updatedEntry
        }
    }

    private var ownedPermissionHookURLs: Set<String> {
        [
            "http://127.0.0.1:\(listenerPort)\(permissionHookPath)",
            "http://localhost:\(listenerPort)\(permissionHookPath)",
            "http://127.0.0.1:\(listenerPort)/permission",
            "http://localhost:\(listenerPort)/permission"
        ]
    }

    private var ownedQuestionHookURLs: Set<String> {
        [
            "http://127.0.0.1:\(listenerPort)\(questionHookPath)",
            "http://localhost:\(listenerPort)\(questionHookPath)",
            "http://127.0.0.1:\(listenerPort)/elicitation/hermitflow",
            "http://localhost:\(listenerPort)/elicitation/hermitflow"
        ]
    }

    private var ownedAskUserQuestionHookURLs: Set<String> {
        [
            "http://127.0.0.1:\(listenerPort)\(askUserQuestionHookPath)",
            "http://localhost:\(listenerPort)\(askUserQuestionHookPath)"
        ]
    }

    private var ownedManagedHookURLs: Set<String> {
        ownedPermissionHookURLs
            .union(ownedQuestionHookURLs)
            .union(ownedAskUserQuestionHookURLs)
    }

    private func settingsContainsManagedHooks(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        let askUserQuestionMode = askUserQuestionHandlingMode()

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
            "WorktreeCreate"
        ]

        let hasManagedCommands = commandEvents.allSatisfy { event in
            containsManagedCommandHook(hooks[event])
        }
        let hasManagedPermissionHook = containsManagedPermissionHook(hooks["PermissionRequest"])
        let hasManagedQuestionHook = containsManagedQuestionHook(hooks["Elicitation"])
        let hasManagedAskUserQuestionHook = askUserQuestionMode == .takeOver
            ? containsManagedAskUserQuestionHook(hooks["PreToolUse"])
            : true
        let hasManagedStatusLine = containsManagedStatusLine(settings["statusLine"])
        return hasManagedCommands
            && hasManagedPermissionHook
            && hasManagedQuestionHook
            && hasManagedAskUserQuestionHook
            && hasManagedStatusLine
    }

    private func containsManagedCommandHook(_ existingValue: Any?) -> Bool {
        let entries = (existingValue as? [[String: Any]]) ?? []
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else {
                continue
            }

            if hooks.contains(where: { hook in
                if let command = hook["command"] as? String {
                    return command.contains(hookMarker)
                }
                return false
            }) {
                return true
            }
        }
        return false
    }

    private func containsManagedPermissionHook(_ existingValue: Any?) -> Bool {
        let entries = (existingValue as? [[String: Any]]) ?? []
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else {
                continue
            }

            if hooks.contains(where: { hook in
                if let url = hook["url"] as? String {
                    return ownedPermissionHookURLs.contains(url)
                }
                return false
            }) {
                return true
            }
        }
        return false
    }

    private func containsManagedQuestionHook(_ existingValue: Any?) -> Bool {
        let entries = (existingValue as? [[String: Any]]) ?? []
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else {
                continue
            }

            if hooks.contains(where: { hook in
                if let url = hook["url"] as? String {
                    return ownedQuestionHookURLs.contains(url)
                }
                return false
            }) {
                return true
            }
        }
        return false
    }

    private func containsManagedAskUserQuestionHook(_ existingValue: Any?) -> Bool {
        let entries = (existingValue as? [[String: Any]]) ?? []
        for entry in entries {
            let matcher = entry["matcher"] as? String ?? ""
            guard matcher == "AskUserQuestion",
                  let hooks = entry["hooks"] as? [[String: Any]] else {
                continue
            }

            if hooks.contains(where: isManagedHook) {
                return true
            }
        }
        return false
    }

    private func containsManagedStatusLine(_ value: Any?) -> Bool {
        guard let statusLine = value as? [String: Any] else {
            return false
        }

        return isManagedStatusLine(statusLine)
    }

    private func isManagedStatusLine(_ value: [String: Any]) -> Bool {
        guard let command = value["command"] as? String else {
            return false
        }

        return command.contains(hookMarker)
    }

    private func isManagedHook(_ hook: [String: Any]) -> Bool {
        if let command = hook["command"] as? String, command.contains(hookMarker) {
            return true
        }

        if let url = hook["url"] as? String, ownedManagedHookURLs.contains(url) {
            return true
        }

        return false
    }

    private func resolveNodeBinary() -> String {
        resolvedNodeBinaryPathIfAvailable() ?? "node"
    }

    private func resolvedNodeBinaryPathIfAvailable() -> String? {
        let fileManager = FileManager.default
        let homeDirectory = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]

        candidates.append(contentsOf: [
            "\(homeDirectory)/.volta/bin/node",
            "\(homeDirectory)/.asdf/shims/node",
            "\(homeDirectory)/.local/bin/node",
            "\(homeDirectory)/.local/share/mise/shims/node",
            "\(homeDirectory)/.mise/shims/node"
        ])
        candidates.append(contentsOf: nodeVersionManagerCandidates(homeDirectory: homeDirectory))

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let path = runCommandAndCaptureOutput(
            executablePath: "/usr/bin/which",
            arguments: ["node"]
        ), fileManager.isExecutableFile(atPath: path) {
            return path
        }

        for shellPath in ["/bin/zsh", "/bin/bash"] {
            if let path = runCommandAndCaptureOutput(
                executablePath: shellPath,
                arguments: ["-lic", "command -v node"]
            ), fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func nodeVersionManagerCandidates(homeDirectory: String) -> [String] {
        var candidates: [String] = []
        candidates.append(contentsOf: nodeInstallCandidates(
            inDirectory: "\(homeDirectory)/.nvm/versions/node",
            suffix: "bin/node"
        ))
        candidates.append(contentsOf: nodeInstallCandidates(
            inDirectory: "\(homeDirectory)/.fnm/node-versions",
            suffix: "installation/bin/node"
        ))
        candidates.append(contentsOf: nodeInstallCandidates(
            inDirectory: "\(homeDirectory)/.asdf/installs/nodejs",
            suffix: "bin/node"
        ))
        return candidates.sorted(by: >)
    }

    private func nodeInstallCandidates(inDirectory directoryPath: String, suffix: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: directoryPath
        ) else {
            return []
        }

        return entries.map { entry in
            URL(fileURLWithPath: directoryPath)
                .appendingPathComponent(entry)
                .appendingPathComponent(suffix)
                .path
        }
    }

    private func runCommandAndCaptureOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return nil
        }

        return path
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

private enum ClaudeHookConfigurationError: LocalizedError {
    case invalidSettingsRoot
    case invalidCustomSettingsPathsFile(String)
    case partialSyncFailed([String])
    case syncFailed([String])

    var errorDescription: String? {
        switch self {
        case .invalidSettingsRoot:
            return "settings root is not a JSON object"
        case let .invalidCustomSettingsPathsFile(path):
            return "custom settings path file is invalid: \(path)"
        case let .partialSyncFailed(reasons), let .syncFailed(reasons):
            return reasons.joined(separator: "; ")
        }
    }
}

private struct ClaudeProjectDerivedState {
    let status: ClaudeTrackedSession.Status
    let lastEvent: String
    let at: Date
}

private struct ClaudeTrackedSession {
    enum Status {
        case idle
        case running
        case success
        case failure

        var debugLabel: String {
            switch self {
            case .idle:
                return "idle"
            case .running:
                return "running"
            case .success:
                return "success"
            case .failure:
                return "failure"
            }
        }

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
    let conversationSummary: String?
    let clientOrigin: FocusClientOrigin?
    let terminalClient: TerminalClient?
    let terminalSessionHint: String?
    let status: Status
    let lastEvent: String
    let lastActivityAt: Date

    var title: String {
        if let conversationSummary, !conversationSummary.isEmpty {
            return conversationSummary
        }

        return "Claude Code"
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

    static func shouldPreserveExistingStatus(
        _ existingStatus: Status,
        forIncomingEvent event: String,
        incomingStatus: Status
    ) -> Bool {
        guard incomingStatus == .idle else {
            return false
        }

        switch event {
        case "Notification", "Elicitation":
            return existingStatus == .running
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
    let commandText: String
    let rationale: String?
    var connection: NWConnection?

    init(
        id: String,
        sessionID: String,
        createdAt: Date,
        commandSummary: String,
        commandText: String,
        rationale: String?,
        connection: NWConnection
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.commandSummary = commandSummary
        self.commandText = commandText
        self.rationale = rationale
        self.connection = connection
    }
}

private final class ClaudePendingQuestion {
    enum Source {
        case elicitation(ClaudeHookElicitationPayload)
        case askUserQuestion(ClaudeHookAskUserQuestionPayload)
    }

    let prompt: ClaudeQuestionPrompt
    let source: Source
    var connection: NWConnection?

    init(
        prompt: ClaudeQuestionPrompt,
        source: Source,
        connection: NWConnection?
    ) {
        self.prompt = prompt
        self.source = source
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
    let clientOrigin: FocusClientOrigin?
    let terminalClient: TerminalClient?
    let terminalSessionHint: String?

    private enum CodingKeys: String, CodingKey {
        case event
        case state
        case sessionID = "session_id"
        case cwd
        case source
        case clientOrigin = "client_origin"
        case terminalClient = "terminal_client"
        case terminalSessionHint = "terminal_session_hint"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        event = try container.decode(String.self, forKey: .event)
        state = try container.decode(String.self, forKey: .state)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        clientOrigin = container.decodeLossyRawRepresentable(FocusClientOrigin.self, forKey: .clientOrigin)
        terminalClient = container.decodeLossyRawRepresentable(TerminalClient.self, forKey: .terminalClient)
        terminalSessionHint = container.decodeNormalizedOptionalString(forKey: .terminalSessionHint)
    }
}

private extension KeyedDecodingContainer {
    func decodeNormalizedOptionalString(forKey key: Key) -> String? {
        let rawValue: String?
        do {
            rawValue = try decodeIfPresent(String.self, forKey: key)
        } catch {
            return nil
        }

        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func decodeLossyRawRepresentable<T: RawRepresentable>(_ type: T.Type, forKey key: Key) -> T?
    where T.RawValue == String {
        guard let rawValue = decodeNormalizedOptionalString(forKey: key) else {
            return nil
        }

        return T(rawValue: rawValue)
    }
}

private struct ClaudeSessionRecord: Decodable {
    let sessionID: String
    let cwd: String
    let startedAt: Int64?
    let kind: String?
    let entrypoint: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
        case startedAt
        case kind
        case entrypoint
    }
}

private struct ClaudeDiscoveredSession {
    let sessionID: String
    let cwd: String
    let source: String
    let clientOrigin: FocusClientOrigin
    let lastActivityAt: Date
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

private struct ClaudeHookElicitationPayload: Decodable {
    let sessionID: String
    let mcpServerName: String
    let elicitationID: String?
    let title: String?
    let message: String?
    let detail: String?
    let timeoutSeconds: Int?
    let requestedSchema: ClaudeQuestionSchema?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case mcpServerName = "mcp_server_name"
        case elicitationID = "elicitation_id"
        case title
        case message
        case detail
        case timeoutSeconds = "timeout_seconds"
        case requestedSchema = "requested_schema"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        mcpServerName = try container.decodeIfPresent(String.self, forKey: .mcpServerName) ?? ""
        elicitationID = container.decodeNormalizedOptionalString(forKey: .elicitationID)
        title = container.decodeNormalizedOptionalString(forKey: .title)
        message = container.decodeNormalizedOptionalString(forKey: .message)
        detail = container.decodeNormalizedOptionalString(forKey: .detail)
        timeoutSeconds = try? container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        requestedSchema = try? container.decodeIfPresent(ClaudeQuestionSchema.self, forKey: .requestedSchema)
    }
}

private struct ClaudeHookAskUserQuestionPayload: Decodable {
    struct ToolInput: Decodable {
        struct Question: Decodable {
            struct Option: Decodable {
                let label: String
                let description: String?
            }

            let question: String
            let header: String?
            let multiSelect: Bool
            let options: [Option]
        }

        let questions: [Question]

        var jsonObject: [String: Any] {
            [
                "questions": questions.map { question in
                    var object: [String: Any] = [
                        "question": question.question,
                        "multiSelect": question.multiSelect,
                        "options": question.options.map { option in
                            var optionObject: [String: Any] = [
                                "label": option.label
                            ]
                            if let description = option.description {
                                optionObject["description"] = description
                            }
                            return optionObject
                        }
                    ]
                    if let header = question.header {
                        object["header"] = header
                    }
                    return object
                }
            ]
        }
    }

    let sessionID: String
    let cwd: String
    let toolName: String
    let toolUseID: String?
    let toolInput: ToolInput?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        toolUseID = container.decodeNormalizedOptionalString(forKey: .toolUseID)
        toolInput = try? container.decodeIfPresent(ToolInput.self, forKey: .toolInput)
    }
}

private struct ClaudeQuestionSchema: Decodable {
    struct Field: Decodable {
        let name: String
        let title: String?
        let description: String?
        let enumValues: [String]
        let defaultValue: String?
        let placeholder: String?
        let type: String?

        var allowsFreeText: Bool {
            enumValues.isEmpty
        }

        var options: [QuestionOption] {
            enumValues.enumerated().map { index, value in
                QuestionOption(
                    id: "\(name)-\(index)",
                    title: value,
                    detail: description,
                    value: value,
                    isDefault: value == defaultValue
                )
            }
        }
    }

    let primaryField: Field?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: AnyDecodable].self)
        let properties = object["properties"]?.dictionaryValue ?? [:]
        let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])

        let fields: [Field] = properties.compactMap { (entry: Dictionary<String, AnyDecodable>.Element) -> Field? in
            let key = entry.key
            let value = entry.value
            guard let dictionary = value.dictionaryValue else {
                return nil
            }

            let enumValues = dictionary["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let title = dictionary["title"]?.stringValue
            let description = dictionary["description"]?.stringValue
            let defaultValue = dictionary["default"]?.stringValue
            let placeholder = dictionary["placeholder"]?.stringValue
            let type = dictionary["type"]?.stringValue

            return Field(
                name: key,
                title: title,
                description: description,
                enumValues: enumValues,
                defaultValue: defaultValue,
                placeholder: placeholder,
                type: type
            )
        }
        primaryField = fields.sorted { (lhs: Field, rhs: Field) in
            let lhsRequired = required.contains(lhs.name) ? 0 : 1
            let rhsRequired = required.contains(rhs.name) ? 0 : 1
            if lhsRequired != rhsRequired {
                return lhsRequired < rhsRequired
            }
            return lhs.name < rhs.name
        }
        .first
    }
}

private struct AnyDecodable: Decodable {
    let value: Any

    var dictionaryValue: [String: AnyDecodable]? { value as? [String: AnyDecodable] }
    var arrayValue: [AnyDecodable]? { value as? [AnyDecodable] }
    var stringValue: String? { value as? String }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let dictionary = try? container.decode([String: AnyDecodable].self) {
                value = dictionary
                return
            }
            if let array = try? container.decode([AnyDecodable].self) {
                value = array
                return
            }
            if let string = try? container.decode(String.self) {
                value = string
                return
            }
            if let int = try? container.decode(Int.self) {
                value = int
                return
            }
            if let double = try? container.decode(Double.self) {
                value = double
                return
            }
            if let bool = try? container.decode(Bool.self) {
                value = bool
                return
            }
        }

        value = NSNull()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ClaudeHistoryEntry: Decodable {
    let display: String
    let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case display
        case sessionID = "sessionId"
    }
}

private struct ClaudeProjectHistoryEntry: Decodable {
    struct Message: Decodable {
        let content: ClaudeProjectHistoryContent
    }

    enum ClaudeProjectHistoryContent: Decodable {
        case text(String)
        case items([Item])

        struct Item: Decodable {
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let singleValueContainer = try decoder.singleValueContainer()
            if let text = try? singleValueContainer.decode(String.self) {
                self = .text(text)
                return
            }

            if let items = try? singleValueContainer.decode([Item].self) {
                self = .items(items)
                return
            }

            self = .text("")
        }
    }

    let sessionID: String
    let message: Message?

    var displayText: String {
        guard let message else {
            return ""
        }

        switch message.content {
        case let .text(text):
            return text
        case let .items(items):
            return items.compactMap(\.text).joined(separator: " ")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case message
    }
}
