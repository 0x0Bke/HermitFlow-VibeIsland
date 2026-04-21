//
//  OpenCodeHookBridge.swift
//  HermitFlow
//
//  Local OpenCode plugin callback bridge.
//

import Foundation
import Network

struct LocalOpenCodeSource: ActivitySource, @unchecked Sendable {
    private let bridge: OpenCodeHookBridge
    private let sqliteReader: OpenCodeSQLiteReader
    private let staleLiveRunningLimit: TimeInterval = 4.0

    init(
        bridge: OpenCodeHookBridge = .shared,
        sqliteReader: OpenCodeSQLiteReader = OpenCodeSQLiteReader()
    ) {
        self.bridge = bridge
        self.sqliteReader = sqliteReader
    }

    func startCallbackServer() {
        bridge.start()
    }

    func fetchActivity() -> ActivitySourceSnapshot {
        let liveSnapshot = bridge.activitySnapshot()
        let fallbackSnapshot = sqliteReader.fetchActivity()
        return merge(liveSnapshot: liveSnapshot, fallbackSnapshot: fallbackSnapshot)
    }

    func fetchLatestApprovalRequest() -> ApprovalRequest? {
        bridge.latestApprovalRequest()
    }

    func healthReport() -> SourceHealthReport {
        SourceHealthReport(
            sourceName: "OpenCode",
            issues: bridge.healthIssues() + sqliteReader.healthIssues()
        )
    }

    private func merge(
        liveSnapshot: ActivitySourceSnapshot,
        fallbackSnapshot: ActivitySourceSnapshot
    ) -> ActivitySourceSnapshot {
        let sourceSessions = liveSnapshot.sessions.isEmpty
            ? fallbackSnapshot.sessions
            : reconcileLiveSessions(liveSnapshot.sessions, with: fallbackSnapshot.sessions)
        let sessions = sourceSessions.sorted { lhs, rhs in
            if lhs.activityState != rhs.activityState {
                return priority(for: lhs.activityState) > priority(for: rhs.activityState)
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let hasLiveContent = !liveSnapshot.sessions.isEmpty || liveSnapshot.approvalRequest != nil
        let statusMessage: String
        if sessions.isEmpty {
            statusMessage = "Waiting for OpenCode activity"
        } else if hasLiveContent {
            statusMessage = "Watching OpenCode activity"
        } else {
            statusMessage = fallbackSnapshot.statusMessage
        }

        let errorMessage = [liveSnapshot.errorMessage, fallbackSnapshot.errorMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return ActivitySourceSnapshot(
            sessions: sessions,
            statusMessage: statusMessage,
            lastUpdatedAt: [liveSnapshot.lastUpdatedAt, fallbackSnapshot.lastUpdatedAt].max() ?? .now,
            errorMessage: errorMessage.isEmpty ? nil : errorMessage,
            approvalRequest: liveSnapshot.approvalRequest,
            usageSnapshots: []
        )
    }

    private func priority(for state: IslandCodexActivityState) -> Int {
        switch state {
        case .failure:
            return 3
        case .running:
            return 2
        case .success:
            return 1
        case .idle:
            return 0
        }
    }

    private func reconcileLiveSessions(
        _ liveSessions: [AgentSessionSnapshot],
        with fallbackSessions: [AgentSessionSnapshot]
    ) -> [AgentSessionSnapshot] {
        guard !fallbackSessions.isEmpty else {
            return liveSessions
        }

        return liveSessions.map { liveSession in
            guard liveSession.activityState == .running,
                  let fallbackSession = matchingFallback(for: liveSession, in: fallbackSessions) else {
                return liveSession
            }

            let liveIsStale = Date().timeIntervalSince(liveSession.updatedAt) > staleLiveRunningLimit
            guard liveIsStale else {
                return liveSession
            }

            if fallbackSession.activityState == .idle,
               fallbackSession.updatedAt >= liveSession.updatedAt.addingTimeInterval(-staleLiveRunningLimit) {
                return AgentSessionSnapshot(
                    id: liveSession.id,
                    origin: liveSession.origin,
                    title: liveSession.title == "OpenCode Session" ? fallbackSession.title : liveSession.title,
                    detail: liveSession.detail,
                    activityState: .idle,
                    runningDetail: nil,
                    updatedAt: fallbackSession.updatedAt,
                    cwd: liveSession.cwd ?? fallbackSession.cwd,
                    focusTarget: liveSession.focusTarget ?? fallbackSession.focusTarget,
                    freshness: .live
                )
            }

            guard fallbackSession.activityState == .success,
                  fallbackSession.updatedAt >= liveSession.updatedAt.addingTimeInterval(-staleLiveRunningLimit) else {
                return liveSession
            }

            return AgentSessionSnapshot(
                id: liveSession.id,
                origin: liveSession.origin,
                title: liveSession.title == "OpenCode Session" ? fallbackSession.title : liveSession.title,
                detail: liveSession.detail,
                activityState: .success,
                runningDetail: nil,
                updatedAt: max(liveSession.updatedAt, fallbackSession.updatedAt),
                cwd: liveSession.cwd ?? fallbackSession.cwd,
                focusTarget: liveSession.focusTarget ?? fallbackSession.focusTarget,
                freshness: .live
            )
        }
    }

    private func matchingFallback(
        for liveSession: AgentSessionSnapshot,
        in fallbackSessions: [AgentSessionSnapshot]
    ) -> AgentSessionSnapshot? {
        if let exact = fallbackSessions.first(where: { $0.id == liveSession.id }) {
            return exact
        }

        if let cwd = liveSession.cwd,
           let cwdMatch = fallbackSessions.first(where: { $0.cwd == cwd }) {
            return cwdMatch
        }

        if liveSession.id == "opencode-live" || liveSession.title == "OpenCode Session" {
            return fallbackSessions.first
        }

        return nil
    }
}

final class OpenCodeHookBridge: @unchecked Sendable {
    enum ApprovalResolution {
        case succeeded
        case notFound
    }

    static let shared = OpenCodeHookBridge()

    let listenerPort: UInt16 = 46822

    private let queue = DispatchQueue(label: "HermitFlow.openCodeHookBridge")
    private let listenerQueue = DispatchQueue(label: "HermitFlow.openCodeHookListener")
    private let successHold: TimeInterval = 1.25
    private let failureHold: TimeInterval = 2.0
    private let staleSessionLimit: TimeInterval = 10 * 60

    private var listener: NWListener?
    private var listenerReady = false
    private var lastErrorMessage: String?
    private var sessions: [String: OpenCodeTrackedSession] = [:]
    private var approvals: [String: OpenCodePendingApproval] = [:]
    private var approvalDecisions: [String: OpenCodeQueuedApprovalDecision] = [:]
    private var questions: [String: OpenCodePendingQuestion] = [:]
    private var questionDecisions: [String: OpenCodeQueuedQuestionDecision] = [:]
    private var debugEvents: [OpenCodePluginDebugEvent] = []
    private var recentEvents: [OpenCodeEventDiagnostic] = []
    private var serverBaseURL: URL?

    private init() {}

    func start() {
        queue.sync {
            if listener != nil {
                return
            }

            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: listenerPort)!)
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection: connection)
                }
                self.listener = listener
                listener.start(queue: listenerQueue)
            } catch {
                lastErrorMessage = "OpenCode hook listener failed: \(error.localizedDescription)"
                listenerReady = false
                listener = nil
            }
        }
    }

    func activitySnapshot() -> ActivitySourceSnapshot {
        queue.sync {
            cleanupExpiredState(now: .now)
            let snapshots = sessions.values
                .map { makeSnapshot(from: $0, now: .now) }
                .sorted { lhs, rhs in
                    if lhs.activityState != rhs.activityState {
                        return priority(for: lhs.activityState) > priority(for: rhs.activityState)
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
            let latestApproval = approvals.values
                .sorted { $0.request.createdAt > $1.request.createdAt }
                .first?
                .request
            let statusMessage = snapshots.isEmpty && latestApproval == nil
                ? "Waiting for OpenCode activity"
                : "Watching OpenCode activity"

            return ActivitySourceSnapshot(
                sessions: snapshots,
                statusMessage: statusMessage,
                lastUpdatedAt: snapshots.map(\.updatedAt).max() ?? .now,
                errorMessage: lastErrorMessage,
                approvalRequest: latestApproval,
                usageSnapshots: []
            )
        }
    }

    func latestApprovalRequest() -> ApprovalRequest? {
        queue.sync {
            cleanupExpiredState(now: .now)
            return approvals.values
                .sorted { $0.request.createdAt > $1.request.createdAt }
                .first?
                .request
        }
    }

    func latestQuestionPrompt() -> ClaudeQuestionPrompt? {
        queue.sync {
            cleanupExpiredState(now: .now)
            return questions.values
                .sorted { $0.prompt.createdAt > $1.prompt.createdAt }
                .first?
                .prompt
        }
    }

    func resolveQuestion(id: String, response: ClaudeQuestionResponse) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let pending = questions.removeValue(forKey: id) else {
                return false
            }

            let answer = questionAnswer(from: response)
            guard !answer.isEmpty else {
                questions[id] = pending
                return false
            }

            let decision = OpenCodeQueuedQuestionDecision(
                questionID: id,
                status: "answered",
                answers: [[answer]],
                output: questionOutput(prompt: pending.prompt, answer: answer),
                createdAt: .now
            )
            questionDecisions[id] = decision
            if let rawID = pending.rawQuestionID {
                questionDecisions[rawID] = decision
            }

            return true
        }
    }

    func dismissQuestion(id: String) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            guard let pending = questions.removeValue(forKey: id) else {
                return false
            }

            let decision = OpenCodeQueuedQuestionDecision(
                questionID: id,
                status: "dismissed",
                answers: [],
                output: "The user dismissed this question.",
                createdAt: .now
            )
            questionDecisions[id] = decision
            if let rawID = pending.rawQuestionID {
                questionDecisions[rawID] = decision
            }

            return true
        }
    }

    func isQuestionSubmittable(id: String) -> Bool {
        queue.sync {
            cleanupExpiredState(now: .now)
            return questions[id] != nil
        }
    }

    func healthIssues() -> [DiagnosticIssue] {
        queue.sync {
            var issues: [DiagnosticIssue] = []
            if !listenerReady {
                issues.append(
                    SourceErrorMapper.issue(
                        source: "OpenCode",
                        severity: .warning,
                        message: lastErrorMessage ?? "OpenCode hook listener is not ready.",
                        recoverySuggestion: "Restart HermitFlow to restart the local OpenCode hook callback listener.",
                        isRepairable: true
                    )
                )
            }

            return issues
        }
    }

    func resolveApproval(id: String, decision: ApprovalDecision) -> ApprovalResolution {
        let pending = queue.sync {
            approvals[id]
        }
        guard let pending else {
            return .notFound
        }

        let queuedDecision = OpenCodeQueuedApprovalDecision(
            approvalID: pending.request.id,
            requestID: pending.requestID,
            reply: replyString(for: decision),
            message: messageString(for: decision),
            createdAt: .now
        )
        queue.sync {
            approvals[id] = nil
            approvalDecisions[pending.request.id] = queuedDecision
            approvalDecisions[pending.requestID] = queuedDecision
            if let existing = sessions[pending.sessionID] {
                sessions[pending.sessionID] = OpenCodeTrackedSession(
                    id: existing.id,
                    title: existing.title,
                    detail: existing.detail,
                    state: .running,
                    runningDetail: .working,
                    updatedAt: .now,
                    cwd: existing.cwd,
                    focusTarget: existing.focusTarget,
                    currentTurnStartedAt: existing.currentTurnStartedAt ?? .now,
                    currentTurnMessageID: existing.currentTurnMessageID,
                    terminalAt: nil,
                    lastEventType: "approval.decision"
                )
            }
        }

        return .succeeded
    }

    private func handleListenerState(_ state: NWListener.State) {
        queue.sync {
            switch state {
            case .ready:
                listenerReady = true
                lastErrorMessage = nil
            case let .failed(error):
                listenerReady = false
                lastErrorMessage = "OpenCode hook listener failed: \(error.localizedDescription)"
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
                self.cleanup(connection)
            } else if case .cancelled = state {
                self.cleanup(connection)
            }
        }
        connection.start(queue: listenerQueue)
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if error != nil {
                self.cleanup(connection)
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
                self.sendHTTPResponse(status: 400, body: "bad request", on: connection)
                return
            }

            self.readRequest(on: connection, buffer: accumulated)
        }
    }

    private func handle(request: OpenCodeHTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            sendJSON(["ok": true, "app": "HermitFlow", "source": "OpenCode", "port": listenerPort], on: connection)
        case ("GET", "/opencode/state"):
            let body = queue.sync {
                let now = Date()
                return [
                    "ok": true,
                    "sessions": sessions.count,
                    "sessionStates": sessions.values.map { sessionStateDictionary(from: $0, now: now) },
                    "approvals": approvals.count,
                    "questions": questions.count,
                    "queuedApprovalDecisions": approvalDecisions.count,
                    "queuedQuestionDecisions": questionDecisions.count,
                    "debugEvents": debugEvents.map(\.dictionary),
                    "recentEvents": recentEvents.map(\.dictionary),
                    "serverURL": serverBaseURL?.absoluteString as Any
                ]
            }
            sendJSON(body, on: connection)
        case ("GET", "/opencode/approval-decision"):
            handleApprovalDecisionPoll(queryItems: request.queryItems, on: connection)
        case ("GET", "/opencode/question-decision"):
            handleQuestionDecisionPoll(queryItems: request.queryItems, on: connection)
        case ("POST", "/opencode/event"):
            handleEvent(body: request.body, on: connection)
        default:
            sendHTTPResponse(status: 404, body: "not found", on: connection)
        }
    }

    private func handleApprovalDecisionPoll(queryItems: [String: String], on connection: NWConnection) {
        let keys = approvalDecisionKeys(from: queryItems)
        let decision = queue.sync {
            cleanupExpiredState(now: .now)
            return keys.compactMap { approvalDecisions[$0] }.first
        }

        guard let decision else {
            sendJSON(["ok": true, "pending": true], on: connection)
            return
        }

        var response: [String: Any] = [
            "ok": true,
            "pending": false,
            "approvalID": decision.approvalID,
            "requestID": decision.requestID,
            "decision": decision.reply
        ]
        if let message = decision.message {
            response["message"] = message
        }
        sendJSON(response, on: connection)
    }

    private func handleQuestionDecisionPoll(queryItems: [String: String], on connection: NWConnection) {
        let keys = questionDecisionKeys(from: queryItems)
        let decision = queue.sync {
            cleanupExpiredState(now: .now)
            return keys.compactMap { questionDecisions[$0] }.first
        }

        guard let decision else {
            sendJSON(["ok": true, "pending": true], on: connection)
            return
        }

        sendJSON([
            "ok": true,
            "pending": false,
            "questionID": decision.questionID,
            "status": decision.status,
            "answers": decision.answers,
            "output": decision.output
        ], on: connection)
    }

    private func handleEvent(body: Data, on connection: NWConnection) {
        guard let rawObject = try? JSONSerialization.jsonObject(with: body),
              let payload = rawObject as? [String: Any] else {
            sendHTTPResponse(status: 400, body: "bad json", on: connection)
            return
        }

        queue.sync {
            apply(payload: payload, now: .now)
        }

        sendJSON(["ok": true], on: connection)
    }

    private func apply(payload: [String: Any], now: Date) {
        cleanupExpiredState(now: now)
        if let serverURL = extractServerURL(from: payload) {
            serverBaseURL = serverURL
        }

        let type = string(at: ["type"], in: payload)
            ?? string(at: ["event", "type"], in: payload)
            ?? string(at: ["input", "type"], in: payload)
            ?? "unknown"

        let context = eventContext(type: type, payload: payload)
        switch type {
        case "server.connected":
            appendRecentEvent(context: context, transition: "metadata", ignoredReason: "server-only", now: now)
            return
        case "hermitflow.debug":
            applyDebugEvent(payload: payload, now: now)
            appendRecentEvent(context: context, transition: "debug", ignoredReason: nil, now: now)
        case "permission.asked":
            applyPermissionAsked(payload: payload, context: context, now: now)
        case "permission.replied":
            applyPermissionReplied(payload: payload, context: context, now: now)
        case "question.asked":
            applyQuestionAsked(payload: payload, context: context, now: now)
        case "question.replied":
            appendRecentEvent(context: context, transition: "question.replied", ignoredReason: nil, now: now)
        case "question.dismissed":
            applyQuestionDismissed(payload: payload, context: context, now: now)
        case "tool.execute.before",
             "tool.execute.after",
             "session.status",
             "session.idle",
             "session.error",
             "message.updated",
             "message.part.updated",
             "session.created",
             "session.updated":
            applyStateEvent(context: context, now: now)
        default:
            appendRecentEvent(context: context, transition: "ignored", ignoredReason: "unknown-event", now: now)
        }
    }

    private func applyDebugEvent(payload: [String: Any], now: Date) {
        let stage = stringFromAny(paths: [
            ["stage"],
            ["event", "stage"],
            ["event", "properties", "stage"],
            ["input", "stage"],
            ["input", "event", "stage"],
            ["input", "event", "properties", "stage"]
        ], in: payload) ?? "unknown"
        let requestID = permissionID(from: payload)
        let sessionID = sessionID(from: payload)
        let message = stringFromAny(paths: [
            ["message"],
            ["event", "message"],
            ["event", "properties", "message"],
            ["input", "message"],
            ["input", "event", "message"],
            ["input", "event", "properties", "message"]
        ], in: payload)

        debugEvents.append(
            OpenCodePluginDebugEvent(
                stage: stage,
                requestID: requestID,
                sessionID: sessionID == "opencode-live" ? nil : sessionID,
                message: message,
                createdAt: now
            )
        )
        if debugEvents.count > 30 {
            debugEvents.removeFirst(debugEvents.count - 30)
        }
    }

    private func applyPermissionAsked(payload: [String: Any], context: OpenCodeEventContext, now: Date) {
        let permissionID = permissionID(from: payload) ?? UUID().uuidString
        let requestID = "opencode:\(context.sessionID):\(permissionID)"
        let serverURL = extractServerURL(from: payload) ?? serverBaseURL
        let title = context.title ?? "OpenCode Permission"
        let commandText = commandText(from: payload)
        let request = ApprovalRequest(
            id: requestID,
            contextTitle: title,
            commandSummary: commandSummary(from: payload),
            commandText: commandText,
            rationale: "OpenCode requested permission.",
            focusTarget: context.focusTarget,
            createdAt: now,
            source: .openCode,
            resolutionKind: .openCodeServerAPI
        )

        approvals[requestID] = OpenCodePendingApproval(
            request: request,
            sessionID: context.sessionID,
            requestID: permissionID,
            serverBaseURL: serverURL
        )

        applyStateEvent(context: context, now: now)
    }

    private func applyPermissionReplied(payload: [String: Any], context: OpenCodeEventContext, now: Date = .now) {
        if let permissionID = permissionID(from: payload) {
            approvals.removeValue(forKey: "opencode:\(context.sessionID):\(permissionID)")
        } else {
            approvals = approvals.filter { $0.value.sessionID != context.sessionID }
        }
        applyStateEvent(context: context, now: now)
    }

    private func applyQuestionAsked(payload: [String: Any], context: OpenCodeEventContext, now: Date) {
        let rawQuestionID = questionID(from: payload)
        let questionID = normalizedQuestionID(rawQuestionID, sessionID: context.sessionID)
        let prompt = makeQuestionPrompt(
            from: payload,
            questionID: questionID,
            sessionID: context.sessionID,
            fallbackTitle: context.title,
            now: now
        )

        questions[questionID] = OpenCodePendingQuestion(
            prompt: prompt,
            rawQuestionID: rawQuestionID == questionID ? nil : rawQuestionID,
            createdAt: now
        )

        let session = OpenCodeTrackedSession(
            id: context.sessionID,
            title: context.title ?? sessions[context.sessionID]?.title ?? "OpenCode Session",
            detail: context.cwd ?? sessions[context.sessionID]?.detail ?? "Waiting for OpenCode answer",
            state: .running,
            runningDetail: .working,
            updatedAt: now,
            cwd: context.cwd ?? sessions[context.sessionID]?.cwd,
            focusTarget: context.cwd == nil ? (sessions[context.sessionID]?.focusTarget ?? context.focusTarget) : context.focusTarget,
            currentTurnStartedAt: sessions[context.sessionID]?.currentTurnStartedAt ?? context.messageCreatedAt ?? now,
            currentTurnMessageID: sessions[context.sessionID]?.currentTurnMessageID ?? context.messageID,
            terminalAt: nil,
            lastEventType: "question.asked"
        )
        sessions[context.sessionID] = session
        appendRecentEvent(context: context, transition: "running.working.question-asked", ignoredReason: nil, now: now)
    }

    private func applyQuestionDismissed(payload: [String: Any], context: OpenCodeEventContext, now: Date) {
        let rawQuestionID = questionID(from: payload)
        let normalizedID = normalizedQuestionID(rawQuestionID, sessionID: context.sessionID)
        questions.removeValue(forKey: normalizedID)
        applyStateEvent(context: OpenCodeEventContext(
            type: "session.error",
            sessionID: context.sessionID,
            title: context.title,
            detail: context.detail,
            cwd: context.cwd,
            focusTarget: context.focusTarget,
            status: "dismissed",
            role: context.role,
            messageID: context.messageID,
            messageCreatedAt: context.messageCreatedAt,
            assistantFinal: false,
            partType: context.partType,
            partReason: context.partReason,
            toolStatus: "dismissed",
            toolFailed: true,
            permissionReply: nil
        ), now: now)
    }

    private func applyStateEvent(context: OpenCodeEventContext, now: Date) {
        let result = OpenCodeSessionStateMachine.reduce(
            existing: sessions[context.sessionID],
            event: context,
            now: now
        )
        if let session = result.session {
            sessions[session.id] = session
        }
        appendRecentEvent(
            context: context,
            transition: result.transition,
            ignoredReason: result.ignoredReason,
            now: now
        )
    }

    private func eventContext(type: String, payload: [String: Any]) -> OpenCodeEventContext {
        let sessionID = sessionID(from: payload)
        let cwd = cwdString(from: payload)
        let focusTarget = makeFocusTarget(sessionID: sessionID, cwd: cwd)
        return OpenCodeEventContext(
            type: type,
            sessionID: sessionID,
            title: titleString(from: payload),
            detail: cwd ?? "Watching OpenCode activity",
            cwd: cwd,
            focusTarget: focusTarget,
            status: statusString(from: payload),
            role: messageRole(from: payload),
            messageID: messageID(from: payload),
            messageCreatedAt: messageCreatedAt(from: payload),
            assistantFinal: isCompletedAssistantMessage(payload) || isTerminalStepFinish(payload),
            partType: partType(from: payload),
            partReason: partReason(from: payload),
            toolStatus: toolStatus(from: payload),
            toolFailed: isFailedToolEvent(payload),
            permissionReply: permissionReply(from: payload)
        )
    }

    private func appendRecentEvent(
        context: OpenCodeEventContext,
        transition: String,
        ignoredReason: String?,
        now: Date
    ) {
        recentEvents.append(
            OpenCodeEventDiagnostic(
                type: context.type,
                sessionID: context.sessionID == "opencode-live" ? nil : context.sessionID,
                role: context.role,
                messageID: context.messageID,
                partType: context.partType,
                status: context.status ?? context.toolStatus,
                computedTransition: transition,
                ignoredReason: ignoredReason,
                createdAt: now
            )
        )
        if recentEvents.count > 50 {
            recentEvents.removeFirst(recentEvents.count - 50)
        }
    }

    private func makeSnapshot(from session: OpenCodeTrackedSession, now: Date) -> AgentSessionSnapshot {
        let effectiveState: IslandCodexActivityState
        switch session.state {
        case .success where now.timeIntervalSince(session.updatedAt) > successHold:
            effectiveState = .idle
        case .failure where now.timeIntervalSince(session.updatedAt) > failureHold:
            effectiveState = .idle
        default:
            effectiveState = session.state
        }

        return AgentSessionSnapshot(
            id: session.id,
            origin: .openCode,
            title: session.title,
            detail: session.detail,
            activityState: effectiveState,
            runningDetail: effectiveState == .running ? session.runningDetail : nil,
            updatedAt: session.updatedAt,
            cwd: session.cwd,
            focusTarget: session.focusTarget,
            freshness: .live
        )
    }

    private func sessionStateDictionary(from session: OpenCodeTrackedSession, now: Date) -> [String: Any] {
        let snapshot = makeSnapshot(from: session, now: now)
        return [
            "id": session.id,
            "state": session.state.rawValue,
            "effectiveState": snapshot.activityState.rawValue,
            "runningDetail": snapshot.runningDetail?.rawValue as Any,
            "updatedAt": session.updatedAt.timeIntervalSince1970,
            "currentTurnStartedAt": session.currentTurnStartedAt?.timeIntervalSince1970 as Any,
            "currentTurnMessageID": session.currentTurnMessageID as Any,
            "terminalAt": session.terminalAt?.timeIntervalSince1970 as Any,
            "lastEventType": session.lastEventType as Any,
            "title": session.title
        ]
    }

    private func cleanupExpiredState(now: Date) {
        sessions = sessions.filter { _, session in
            session.state == .running || now.timeIntervalSince(session.updatedAt) <= staleSessionLimit
        }
        approvals = approvals.filter { _, pending in
            now.timeIntervalSince(pending.request.createdAt) <= staleSessionLimit
        }
        approvalDecisions = approvalDecisions.filter { _, decision in
            now.timeIntervalSince(decision.createdAt) <= staleSessionLimit
        }
        questions = questions.filter { _, pending in
            now.timeIntervalSince(pending.createdAt) <= staleSessionLimit
        }
        questionDecisions = questionDecisions.filter { _, decision in
            now.timeIntervalSince(decision.createdAt) <= staleSessionLimit
        }
        debugEvents = debugEvents.filter { event in
            now.timeIntervalSince(event.createdAt) <= staleSessionLimit
        }
        recentEvents = recentEvents.filter { event in
            now.timeIntervalSince(event.createdAt) <= staleSessionLimit
        }
    }

    private func replyString(for decision: ApprovalDecision) -> String {
        switch decision {
        case .reject:
            return "reject"
        case .accept:
            return "once"
        case .acceptAll:
            return "always"
        }
    }

    private func messageString(for decision: ApprovalDecision) -> String? {
        switch decision {
        case .reject:
            return "Rejected in HermitFlow"
        case .accept, .acceptAll:
            return nil
        }
    }

    private func approvalDecisionKeys(from queryItems: [String: String]) -> [String] {
        var keys: [String] = []
        for key in ["approvalID", "approvalId", "requestID", "requestId", "permissionID", "permissionId"] {
            if let value = queryItems[key], !value.isEmpty {
                keys.append(value)
            }
        }

        let sessionID = queryItems["sessionID"] ?? queryItems["sessionId"] ?? queryItems["session_id"]
        let permissionID = queryItems["permissionID"]
            ?? queryItems["permissionId"]
            ?? queryItems["requestID"]
            ?? queryItems["requestId"]
        if let sessionID, let permissionID {
            keys.append("opencode:\(sessionID):\(permissionID)")
        }

        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func questionDecisionKeys(from queryItems: [String: String]) -> [String] {
        var keys: [String] = []
        for key in ["questionID", "questionId", "requestID", "requestId", "callID", "callId"] {
            if let value = queryItems[key], !value.isEmpty {
                keys.append(value)
            }
        }

        let sessionID = queryItems["sessionID"] ?? queryItems["sessionId"] ?? queryItems["session_id"]
        let questionID = queryItems["questionID"]
            ?? queryItems["questionId"]
            ?? queryItems["requestID"]
            ?? queryItems["requestId"]
            ?? queryItems["callID"]
            ?? queryItems["callId"]
        if let sessionID, let questionID {
            keys.append(normalizedQuestionID(questionID, sessionID: sessionID))
        }

        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func questionID(from payload: [String: Any]) -> String {
        stringFromAny(paths: [
            ["input", "questionID"],
            ["input", "questionId"],
            ["input", "requestID"],
            ["input", "requestId"],
            ["input", "callID"],
            ["input", "callId"],
            ["input", "event", "questionID"],
            ["input", "event", "questionId"],
            ["input", "event", "requestID"],
            ["input", "event", "requestId"],
            ["input", "event", "callID"],
            ["input", "event", "callId"],
            ["input", "event", "properties", "questionID"],
            ["input", "event", "properties", "questionId"],
            ["input", "event", "properties", "requestID"],
            ["input", "event", "properties", "requestId"],
            ["input", "event", "properties", "callID"],
            ["input", "event", "properties", "callId"],
            ["event", "questionID"],
            ["event", "questionId"],
            ["event", "requestID"],
            ["event", "requestId"],
            ["event", "callID"],
            ["event", "callId"],
            ["event", "properties", "questionID"],
            ["event", "properties", "questionId"],
            ["event", "properties", "requestID"],
            ["event", "properties", "requestId"],
            ["event", "properties", "callID"],
            ["event", "properties", "callId"],
            ["questionID"],
            ["questionId"],
            ["requestID"],
            ["requestId"],
            ["callID"],
            ["callId"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["questionID", "questionId", "requestID", "requestId", "callID", "callId"])
            ?? UUID().uuidString
    }

    private func normalizedQuestionID(_ rawID: String, sessionID: String) -> String {
        rawID.hasPrefix("opencode-question:") ? rawID : "opencode-question:\(sessionID):\(rawID)"
    }

    private func sessionID(from payload: [String: Any]) -> String {
        stringFromAny(paths: [
            ["input", "sessionID"],
            ["input", "sessionId"],
            ["input", "session", "id"],
            ["input", "event", "sessionID"],
            ["input", "event", "sessionId"],
            ["input", "event", "session_id"],
            ["input", "event", "properties", "sessionID"],
            ["input", "event", "properties", "sessionId"],
            ["input", "event", "properties", "session_id"],
            ["input", "event", "session", "id"],
            ["event", "sessionID"],
            ["event", "sessionId"],
            ["event", "session_id"],
            ["event", "properties", "sessionID"],
            ["event", "properties", "sessionId"],
            ["event", "properties", "session_id"],
            ["event", "session", "id"],
            ["sessionID"],
            ["sessionId"],
            ["session_id"],
            ["session", "id"],
            ["output", "sessionID"],
            ["output", "sessionId"],
            ["output", "session_id"],
            ["output", "session", "id"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["sessionID", "sessionId", "session_id"])
            ?? deepStringValue(in: payload, keys: ["id"], preferredPrefix: "ses_")
            ?? "opencode-live"
    }

    private func permissionID(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "permissionID"],
            ["input", "permissionId"],
            ["input", "permission", "id"],
            ["input", "id"],
            ["input", "event", "permissionID"],
            ["input", "event", "permissionId"],
            ["input", "event", "permission_id"],
            ["input", "event", "id"],
            ["input", "event", "properties", "permissionID"],
            ["input", "event", "properties", "permissionId"],
            ["input", "event", "properties", "permission_id"],
            ["input", "event", "properties", "id"],
            ["input", "event", "permission", "id"],
            ["event", "permissionID"],
            ["event", "permissionId"],
            ["event", "permission_id"],
            ["event", "id"],
            ["event", "properties", "permissionID"],
            ["event", "properties", "permissionId"],
            ["event", "properties", "permission_id"],
            ["event", "properties", "id"],
            ["event", "permission", "id"],
            ["permissionID"],
            ["permissionId"],
            ["permission_id"],
            ["id"],
            ["permission", "id"],
            ["output", "permissionID"],
            ["output", "permissionId"],
            ["output", "permission_id"],
            ["output", "permission", "id"]
        ], in: payload)
            ?? deepStringValue(
                in: payload,
                keys: ["permissionID", "permissionId", "permission_id", "requestID", "requestId", "id"]
            )
    }

    private func cwdString(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["context", "directory"],
            ["context", "worktree"],
            ["input", "directory"],
            ["input", "cwd"],
            ["input", "session", "directory"],
            ["input", "event", "session", "directory"],
            ["input", "event", "properties", "directory"],
            ["input", "event", "properties", "cwd"],
            ["event", "session", "directory"],
            ["event", "properties", "directory"],
            ["event", "properties", "cwd"],
            ["session", "directory"],
            ["directory"],
            ["worktree"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["directory", "cwd", "worktree"])
    }

    private func titleString(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "title"],
            ["input", "session", "title"],
            ["input", "event", "session", "title"],
            ["input", "event", "properties", "title"],
            ["event", "session", "title"],
            ["event", "properties", "title"],
            ["session", "title"],
            ["title"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["title"])
    }

    private func statusString(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "status"],
            ["input", "event", "status"],
            ["input", "event", "session", "status"],
            ["input", "event", "properties", "status"],
            ["event", "status"],
            ["event", "session", "status"],
            ["event", "properties", "status"],
            ["status"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["status", "state"])
    }

    private func commandSummary(from payload: [String: Any]) -> String {
        if let permission = permissionName(from: payload) {
            return "OpenCode requests \(permission)"
        }

        if let tool = stringFromAny(paths: [
            ["input", "tool"],
            ["input", "event", "tool"],
            ["input", "event", "properties", "permission"],
            ["event", "tool"],
            ["event", "properties", "permission"],
            ["tool"]
        ], in: payload) {
            return "OpenCode requested \(tool)"
        }

        return "OpenCode permission request"
    }

    private func commandText(from payload: [String: Any]) -> String {
        if let command = stringFromAny(paths: [
            ["input", "metadata", "command"],
            ["input", "event", "properties", "metadata", "command"],
            ["event", "properties", "metadata", "command"],
            ["output", "args", "command"],
            ["input", "args", "command"],
            ["input", "event", "args", "command"],
            ["input", "event", "properties", "args", "command"],
            ["input", "command"],
            ["input", "event", "command"],
            ["input", "event", "properties", "command"],
            ["event", "command"],
            ["event", "properties", "command"],
            ["command"]
        ], in: payload) {
            return "$ \(command)"
        }

        if let path = stringFromAny(paths: [
            ["input", "metadata", "filePath"],
            ["input", "metadata", "filepath"],
            ["input", "metadata", "path"],
            ["input", "event", "properties", "metadata", "filePath"],
            ["input", "event", "properties", "metadata", "filepath"],
            ["input", "event", "properties", "metadata", "path"],
            ["event", "properties", "metadata", "filePath"],
            ["event", "properties", "metadata", "filepath"],
            ["event", "properties", "metadata", "path"],
            ["output", "args", "filePath"],
            ["output", "args", "path"],
            ["input", "args", "filePath"],
            ["input", "args", "path"]
        ], in: payload) {
            return "\(permissionName(from: payload) ?? "Permission"): \(path)"
        }

        if let patterns = stringArrayValue(paths: [
            ["input", "patterns"],
            ["input", "event", "properties", "patterns"],
            ["event", "properties", "patterns"],
            ["patterns"]
        ], in: payload), !patterns.isEmpty {
            return "\(permissionName(from: payload) ?? "Permission"): \(patterns.prefix(3).joined(separator: ", "))"
        }

        return permissionName(from: payload).map { "Permission: \($0)" } ?? "OpenCode permission request"
    }

    private func makeQuestionPrompt(
        from payload: [String: Any],
        questionID: String,
        sessionID: String,
        fallbackTitle: String?,
        now: Date
    ) -> ClaudeQuestionPrompt {
        let question = firstQuestionObject(from: payload)
        let title = normalizedString(question?["header"])
            ?? nonEmptyString(fallbackTitle)
            ?? "OpenCode Needs Input"
        let message = normalizedString(question?["question"])
            ?? stringFromAny(paths: [
                ["input", "question"],
                ["input", "event", "question"],
                ["input", "event", "properties", "question"],
                ["event", "question"],
                ["event", "properties", "question"],
                ["question"]
            ], in: payload)
        let options = questionOptions(from: question, questionID: questionID)
        let multiple = boolValue(question?["multiple"]) ?? boolValue(question?["multiSelect"]) ?? false

        return ClaudeQuestionPrompt(
            id: questionID,
            sessionID: sessionID,
            title: title,
            message: message,
            detail: multiple ? "OpenCode asked a multi-select question. Choose one answer here or type a custom answer." : nil,
            options: options,
            allowsFreeText: true,
            placeholder: "Type another answer",
            defaultText: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(2 * 60),
            source: .openCode
        )
    }

    private func firstQuestionObject(from payload: [String: Any]) -> [String: Any]? {
        let paths: [[String]] = [
            ["input", "questions"],
            ["input", "args", "questions"],
            ["input", "event", "questions"],
            ["input", "event", "properties", "questions"],
            ["event", "questions"],
            ["event", "properties", "questions"],
            ["questions"],
            ["args", "questions"],
            ["output", "args", "questions"]
        ]

        for path in paths {
            guard let value = value(at: path, in: payload) else {
                continue
            }
            if let questions = value as? [[String: Any]], let first = questions.first {
                return first
            }
            if let questions = value as? [Any], let first = questions.first as? [String: Any] {
                return first
            }
        }

        return nil
    }

    private func questionOptions(from question: [String: Any]?, questionID: String) -> [QuestionOption] {
        guard let rawOptions = question?["options"] as? [Any] else {
            return []
        }

        return rawOptions.enumerated().compactMap { index, rawOption in
            if let dictionary = rawOption as? [String: Any] {
                let label = normalizedString(dictionary["label"])
                    ?? normalizedString(dictionary["title"])
                    ?? normalizedString(dictionary["value"])
                guard let label else {
                    return nil
                }
                return QuestionOption(
                    id: "\(questionID)-\(index)",
                    title: label,
                    detail: normalizedString(dictionary["description"]) ?? normalizedString(dictionary["detail"]),
                    value: normalizedString(dictionary["value"]) ?? label,
                    isDefault: boolValue(dictionary["default"]) ?? boolValue(dictionary["isDefault"]) ?? false
                )
            }

            guard let label = stringValue(rawOption) else {
                return nil
            }
            return QuestionOption(
                id: "\(questionID)-\(index)",
                title: label,
                detail: nil,
                value: label,
                isDefault: false
            )
        }
    }

    private func questionAnswer(from response: ClaudeQuestionResponse) -> String {
        nonEmptyString(response.textAnswer)
            ?? nonEmptyString(response.selectedOptionValue)
            ?? nonEmptyString(response.displaySummary)
            ?? ""
    }

    private func questionOutput(prompt: ClaudeQuestionPrompt, answer: String) -> String {
        let question = nonEmptyString(prompt.message) ?? prompt.title
        return "User has answered your questions: \"\(question)\"=\"\(answer)\". You can now continue with the user's answers in mind."
    }

    private func extractServerURL(from payload: [String: Any]) -> URL? {
        let urlString = stringFromAny(paths: [
            ["input", "serverURL"],
            ["input", "serverUrl"],
            ["input", "server", "url"],
            ["input", "url"],
            ["input", "event", "serverURL"],
            ["input", "event", "serverUrl"],
            ["input", "event", "server", "url"],
            ["input", "event", "properties", "serverURL"],
            ["input", "event", "properties", "serverUrl"],
            ["input", "event", "properties", "url"],
            ["event", "serverURL"],
            ["event", "serverUrl"],
            ["event", "server", "url"],
            ["event", "properties", "serverURL"],
            ["event", "properties", "serverUrl"],
            ["event", "properties", "url"],
            ["serverURL"],
            ["serverUrl"],
            ["server", "url"],
            ["context", "serverURL"],
            ["context", "server", "url"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["serverURL", "serverUrl", "url"], preferredPrefix: "http")

        if let url = urlString.flatMap(URL.init(string:)) {
            return url
        }

        return serverURLFromHostPort(payload)
    }

    private func isRunningStatus(_ status: String?) -> Bool {
        guard let normalized = status?.lowercased() else {
            return false
        }

        return ["run", "running", "busy", "work", "working", "stream", "streaming", "active"]
            .contains { normalized.contains($0) }
    }

    private func partType(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "part", "type"],
            ["input", "event", "part", "type"],
            ["input", "event", "properties", "part", "type"],
            ["event", "part", "type"],
            ["event", "properties", "part", "type"],
            ["part", "type"]
        ], in: payload)?.lowercased()
    }

    private func partReason(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "part", "reason"],
            ["input", "event", "part", "reason"],
            ["input", "event", "properties", "part", "reason"],
            ["event", "part", "reason"],
            ["event", "properties", "part", "reason"],
            ["part", "reason"],
            ["input", "reason"],
            ["input", "event", "reason"],
            ["input", "event", "properties", "reason"],
            ["event", "reason"],
            ["event", "properties", "reason"],
            ["reason"]
        ], in: payload)?.lowercased()
    }

    private func toolStatus(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["output", "status"],
            ["output", "state", "status"],
            ["output", "state"],
            ["input", "tool", "status"],
            ["input", "event", "tool", "status"],
            ["input", "event", "properties", "tool", "status"],
            ["event", "tool", "status"],
            ["event", "properties", "tool", "status"],
            ["tool", "status"]
        ], in: payload)
    }

    private func isTerminalStepFinish(_ payload: [String: Any]) -> Bool {
        guard partType(from: payload) == "step-finish" else {
            return false
        }
        return partReason(from: payload) != "tool-calls"
    }

    private func isFailedToolEvent(_ payload: [String: Any]) -> Bool {
        if let status = toolStatus(from: payload)?.lowercased(),
           ["fail", "failed", "error", "errored", "reject", "rejected", "denied"].contains(where: { status.contains($0) }) {
            return true
        }

        return stringFromAny(paths: [
            ["output", "error"],
            ["input", "error"],
            ["input", "event", "error"],
            ["input", "event", "properties", "error"],
            ["event", "error"],
            ["event", "properties", "error"],
            ["error"]
        ], in: payload) != nil
    }

    private func permissionReply(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["output", "response"],
            ["output", "reply"],
            ["output", "decision"],
            ["input", "response"],
            ["input", "reply"],
            ["input", "decision"],
            ["input", "event", "response"],
            ["input", "event", "reply"],
            ["input", "event", "decision"],
            ["input", "event", "properties", "response"],
            ["input", "event", "properties", "reply"],
            ["input", "event", "properties", "decision"],
            ["event", "response"],
            ["event", "reply"],
            ["event", "decision"],
            ["event", "properties", "response"],
            ["event", "properties", "reply"],
            ["event", "properties", "decision"],
            ["response"],
            ["reply"],
            ["decision"]
        ], in: payload)?.lowercased()
    }

    private func isCompletedAssistantMessage(_ payload: [String: Any]) -> Bool {
        let role = messageRole(from: payload)
        let completionMarker = stringFromAny(paths: [
            ["input", "message", "time", "completed"],
            ["input", "message", "timeCompleted"],
            ["input", "message", "time_completed"],
            ["input", "event", "message", "time", "completed"],
            ["input", "event", "message", "timeCompleted"],
            ["input", "event", "message", "time_completed"],
            ["input", "event", "properties", "message", "time", "completed"],
            ["input", "event", "properties", "message", "timeCompleted"],
            ["input", "event", "properties", "message", "time_completed"],
            ["event", "message", "time", "completed"],
            ["event", "message", "timeCompleted"],
            ["event", "message", "time_completed"],
            ["event", "properties", "message", "time", "completed"],
            ["event", "properties", "message", "timeCompleted"],
            ["event", "properties", "message", "time_completed"],
            ["message", "time", "completed"],
            ["message", "timeCompleted"],
            ["message", "time_completed"],
            ["completed"],
            ["done"],
            ["finished"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["completed", "timeCompleted", "time_completed", "done", "finished"])
        let messageStatus = deepStringValue(in: payload, keys: ["status", "state"])?.lowercased()
        let finishedByStatus = messageStatus.map { status in
            ["complete", "completed", "done", "finished", "success"].contains { status.contains($0) }
        } ?? false
        let finish = stringFromAny(paths: [
            ["input", "message", "finish"],
            ["input", "event", "message", "finish"],
            ["input", "event", "properties", "message", "finish"],
            ["event", "message", "finish"],
            ["event", "properties", "message", "finish"],
            ["message", "finish"],
            ["finish"]
        ], in: payload)?.lowercased()
        let terminalByFinish = finish != nil && finish != "tool-calls"

        guard role == "assistant",
              completionMarker != nil || finishedByStatus || terminalByFinish else {
            return false
        }
        return finish != "tool-calls"
    }

    private func messageRole(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "message", "role"],
            ["input", "event", "message", "role"],
            ["input", "event", "properties", "message", "role"],
            ["input", "role"],
            ["input", "event", "role"],
            ["input", "event", "properties", "role"],
            ["event", "message", "role"],
            ["event", "properties", "message", "role"],
            ["event", "role"],
            ["event", "properties", "role"],
            ["message", "role"],
            ["role"]
        ], in: payload)?.lowercased()
            ?? deepStringValue(in: payload, keys: ["role"])?.lowercased()
    }

    private func messageID(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "message", "id"],
            ["input", "messageID"],
            ["input", "messageId"],
            ["input", "message_id"],
            ["input", "event", "message", "id"],
            ["input", "event", "messageID"],
            ["input", "event", "messageId"],
            ["input", "event", "message_id"],
            ["input", "event", "properties", "message", "id"],
            ["input", "event", "properties", "messageID"],
            ["input", "event", "properties", "messageId"],
            ["input", "event", "properties", "message_id"],
            ["event", "message", "id"],
            ["event", "messageID"],
            ["event", "messageId"],
            ["event", "message_id"],
            ["event", "properties", "message", "id"],
            ["event", "properties", "messageID"],
            ["event", "properties", "messageId"],
            ["event", "properties", "message_id"],
            ["message", "id"],
            ["messageID"],
            ["messageId"],
            ["message_id"]
        ], in: payload)
            ?? deepStringValue(in: payload, keys: ["messageID", "messageId", "message_id"])
            ?? deepStringValue(in: payload, keys: ["id"], preferredPrefix: "msg_")
    }

    private func messageCreatedAt(from payload: [String: Any]) -> Date? {
        timestampDate(paths: [
            ["input", "message", "time", "created"],
            ["input", "message", "timeCreated"],
            ["input", "message", "time_created"],
            ["input", "event", "message", "time", "created"],
            ["input", "event", "message", "timeCreated"],
            ["input", "event", "message", "time_created"],
            ["input", "event", "properties", "message", "time", "created"],
            ["input", "event", "properties", "message", "timeCreated"],
            ["input", "event", "properties", "message", "time_created"],
            ["input", "time", "created"],
            ["input", "timeCreated"],
            ["input", "time_created"],
            ["event", "message", "time", "created"],
            ["event", "message", "timeCreated"],
            ["event", "message", "time_created"],
            ["event", "properties", "message", "time", "created"],
            ["event", "properties", "message", "timeCreated"],
            ["event", "properties", "message", "time_created"],
            ["event", "time", "created"],
            ["event", "timeCreated"],
            ["event", "time_created"],
            ["message", "time", "created"],
            ["message", "timeCreated"],
            ["message", "time_created"],
            ["time", "created"],
            ["timeCreated"],
            ["time_created"]
        ], in: payload)
    }

    private func makeFocusTarget(sessionID: String, cwd: String?) -> FocusTarget {
        FocusTarget(
            clientOrigin: .openCodeCLI,
            sessionID: sessionID,
            displayName: "OpenCode CLI",
            cwd: cwd,
            terminalClient: .unknown,
            terminalSessionHint: nil,
            workspaceHint: cwd
        )
    }

    private func stringFromAny(paths: [[String]], in payload: [String: Any]) -> String? {
        for path in paths {
            if let value = value(at: path, in: payload) {
                if let string = normalizedString(value) {
                    return string
                }

                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }

        return nil
    }

    private func stringArrayValue(paths: [[String]], in payload: [String: Any]) -> [String]? {
        for path in paths {
            guard let value = value(at: path, in: payload) else {
                continue
            }
            if let strings = value as? [String] {
                return strings
            }
            if let values = value as? [Any] {
                let strings = values.compactMap(stringValue)
                if !strings.isEmpty {
                    return strings
                }
            }
        }

        return nil
    }

    private func timestampDate(paths: [[String]], in payload: [String: Any]) -> Date? {
        for path in paths {
            guard let value = value(at: path, in: payload),
                  let date = timestampDate(from: value) else {
                continue
            }
            return date
        }

        return nil
    }

    private func timestampDate(from value: Any) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let string = stringValue(value) {
            raw = Double(string)
        } else {
            raw = nil
        }

        guard let raw, raw > 0 else {
            return nil
        }

        let seconds = raw > 100_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private func permissionName(from payload: [String: Any]) -> String? {
        stringFromAny(paths: [
            ["input", "permission"],
            ["input", "event", "permission"],
            ["input", "event", "properties", "permission"],
            ["event", "permission"],
            ["event", "properties", "permission"],
            ["permission"]
        ], in: payload)
    }

    private func serverURLFromHostPort(_ payload: [String: Any]) -> URL? {
        let host = stringFromAny(paths: [
            ["input", "hostname"],
            ["input", "host"],
            ["input", "event", "hostname"],
            ["input", "event", "host"],
            ["input", "event", "properties", "hostname"],
            ["input", "event", "properties", "host"],
            ["event", "hostname"],
            ["event", "host"],
            ["event", "properties", "hostname"],
            ["event", "properties", "host"],
            ["hostname"],
            ["host"],
            ["context", "hostname"],
            ["context", "host"]
        ], in: payload) ?? "127.0.0.1"

        guard let port = stringFromAny(paths: [
            ["input", "port"],
            ["input", "event", "port"],
            ["input", "event", "properties", "port"],
            ["event", "port"],
            ["event", "properties", "port"],
            ["port"],
            ["context", "port"]
        ], in: payload) else {
            return nil
        }

        return URL(string: "http://\(host):\(port)")
    }

    private func string(at path: [String], in payload: [String: Any]) -> String? {
        guard let value = value(at: path, in: payload) else {
            return nil
        }

        return normalizedString(value)
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

    private func normalizedString(_ value: Any?) -> String? {
        guard let value, let string = value as? String else {
            return nil
        }

        return nonEmptyString(string)
    }

    private func nonEmptyString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deepStringValue(
        in value: Any,
        keys: Set<String>,
        preferredPrefix: String? = nil
    ) -> String? {
        if let dictionary = value as? [String: Any] {
            var fallback: String?
            for (key, nestedValue) in dictionary {
                if keys.contains(key),
                   let string = stringValue(nestedValue),
                   preferredPrefix == nil || string.hasPrefix(preferredPrefix!) {
                    return string
                }
                if keys.contains(key), fallback == nil {
                    fallback = stringValue(nestedValue)
                }
                if let nested = deepStringValue(in: nestedValue, keys: keys, preferredPrefix: preferredPrefix) {
                    return nested
                }
            }
            return fallback
        }

        if let array = value as? [Any] {
            for item in array {
                if let nested = deepStringValue(in: item, keys: keys, preferredPrefix: preferredPrefix) {
                    return nested
                }
            }
        }

        return nil
    }

    private func stringValue(_ value: Any) -> String? {
        if let string = normalizedString(value) {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func priority(for state: IslandCodexActivityState) -> Int {
        switch state {
        case .failure:
            return 3
        case .running:
            return 2
        case .success:
            return 1
        case .idle:
            return 0
        }
    }

    private func parseRequest(from data: Data) -> OpenCodeHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let headerLines = header.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }

        let contentLength = headerLines
            .dropFirst()
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
                    return nil
                }
                return Int(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let components = URLComponents(string: parts[1])
        let queryItems = components?.queryItems?.reduce(into: [String: String]()) { result, item in
            if result[item.name] == nil {
                result[item.name] = item.value ?? ""
            }
        } ?? [:]

        return OpenCodeHTTPRequest(
            method: parts[0],
            path: components?.path ?? parts[1],
            queryItems: queryItems,
            body: Data(data[bodyStart..<bodyStart + contentLength])
        )
    }

    private func sendJSON(_ object: Any, on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        sendHTTPResponse(status: 200, body: body, contentType: "application/json", on: connection)
    }

    private func sendHTTPResponse(
        status: Int,
        body: String,
        contentType: String = "text/plain",
        on connection: NWConnection
    ) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
        let data = Data("""
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.cleanup(connection)
        })
    }

    private func cleanup(_ connection: NWConnection) {
        connection.cancel()
    }
}

private struct OpenCodeTrackedSession {
    let id: String
    let title: String
    let detail: String
    let state: IslandCodexActivityState
    let runningDetail: IslandRunningDetail?
    let updatedAt: Date
    let cwd: String?
    let focusTarget: FocusTarget
    let currentTurnStartedAt: Date?
    let currentTurnMessageID: String?
    let terminalAt: Date?
    let lastEventType: String?
}

private struct OpenCodeEventContext {
    let type: String
    let sessionID: String
    let title: String?
    let detail: String
    let cwd: String?
    let focusTarget: FocusTarget
    let status: String?
    let role: String?
    let messageID: String?
    let messageCreatedAt: Date?
    let assistantFinal: Bool
    let partType: String?
    let partReason: String?
    let toolStatus: String?
    let toolFailed: Bool
    let permissionReply: String?
}

private struct OpenCodeStateMachineResult {
    let session: OpenCodeTrackedSession?
    let transition: String
    let ignoredReason: String?
}

private struct OpenCodeSessionStateMachine {
    static func reduce(
        existing: OpenCodeTrackedSession?,
        event: OpenCodeEventContext,
        now: Date
    ) -> OpenCodeStateMachineResult {
        switch event.type {
        case "permission.asked":
            return transition(
                existing: existing,
                event: event,
                state: .running,
                runningDetail: .working,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now,
                currentTurnMessageID: existing?.currentTurnMessageID ?? event.messageID,
                terminalAt: nil,
                transition: "running.working.permission-asked"
            )
        case "permission.replied":
            if isRejected(event.permissionReply) {
                return transition(
                    existing: existing,
                    event: event,
                    state: .failure,
                    runningDetail: nil,
                    updatedAt: now,
                    currentTurnStartedAt: existing?.currentTurnStartedAt,
                    currentTurnMessageID: existing?.currentTurnMessageID,
                    terminalAt: now,
                    transition: "failure.permission-rejected"
                )
            }
            return transition(
                existing: existing,
                event: event,
                state: .running,
                runningDetail: .working,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now,
                currentTurnMessageID: existing?.currentTurnMessageID ?? event.messageID,
                terminalAt: nil,
                transition: "running.working.permission-replied"
            )
        case "tool.execute.before":
            return transition(
                existing: existing,
                event: event,
                state: .running,
                runningDetail: .working,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now,
                currentTurnMessageID: existing?.currentTurnMessageID ?? event.messageID,
                terminalAt: nil,
                transition: "running.working.tool-before"
            )
        case "tool.execute.after":
            if event.toolFailed {
                return transition(
                    existing: existing,
                    event: event,
                    state: .failure,
                    runningDetail: nil,
                    updatedAt: now,
                    currentTurnStartedAt: existing?.currentTurnStartedAt,
                    currentTurnMessageID: existing?.currentTurnMessageID,
                    terminalAt: now,
                    transition: "failure.tool-after"
                )
            }
            return transition(
                existing: existing,
                event: event,
                state: .running,
                runningDetail: .thinking,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now,
                currentTurnMessageID: existing?.currentTurnMessageID ?? event.messageID,
                terminalAt: nil,
                transition: "running.thinking.tool-after"
            )
        case "session.error":
            return transition(
                existing: existing,
                event: event,
                state: .failure,
                runningDetail: nil,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt,
                currentTurnMessageID: existing?.currentTurnMessageID,
                terminalAt: now,
                transition: "failure.session-error"
            )
        case "session.idle":
            return transition(
                existing: existing,
                event: event,
                state: .success,
                runningDetail: nil,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt,
                currentTurnMessageID: existing?.currentTurnMessageID,
                terminalAt: now,
                transition: "success.session-idle"
            )
        case "session.status":
            guard isRunningStatus(event.status) else {
                return metadataOnly(existing: existing, event: event, now: now, ignoredReason: "session-status-metadata-only")
            }
            let runningDetail: IslandRunningDetail = existing?.runningDetail == .working ? .working : .thinking
            return transition(
                existing: existing,
                event: event,
                state: .running,
                runningDetail: runningDetail,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now,
                currentTurnMessageID: existing?.currentTurnMessageID ?? event.messageID,
                terminalAt: nil,
                transition: runningDetail == .working ? "running.working.status-preserved" : "running.thinking.status"
            )
        case "message.updated", "message.part.updated":
            return reduceMessage(existing: existing, event: event, now: now)
        case "session.created", "session.updated":
            return metadataOnly(existing: existing, event: event, now: now, ignoredReason: "session-metadata-only")
        default:
            return OpenCodeStateMachineResult(session: nil, transition: "ignored", ignoredReason: "unknown-event")
        }
    }

    private static func reduceMessage(
        existing: OpenCodeTrackedSession?,
        event: OpenCodeEventContext,
        now: Date
    ) -> OpenCodeStateMachineResult {
        if event.assistantFinal {
            return transition(
                existing: existing,
                event: event,
                state: .success,
                runningDetail: nil,
                updatedAt: now,
                currentTurnStartedAt: existing?.currentTurnStartedAt,
                currentTurnMessageID: existing?.currentTurnMessageID,
                terminalAt: now,
                transition: terminalTransitionName(for: event)
            )
        }

        if let existing,
           existing.terminalAt != nil || existing.state == .success || existing.state == .failure {
            if let createdAt = event.messageCreatedAt {
                if isKnownTailMessage(existing: existing, event: event),
                   let terminalAt = existing.terminalAt,
                   createdAt <= terminalAt {
                    return OpenCodeStateMachineResult(
                        session: existing,
                        transition: "ignored",
                        ignoredReason: "tail-message-before-terminal"
                    )
                }
                if isKnownTailMessage(existing: existing, event: event),
                   let currentTurnStartedAt = existing.currentTurnStartedAt,
                   createdAt <= currentTurnStartedAt {
                    return OpenCodeStateMachineResult(
                        session: existing,
                        transition: "ignored",
                        ignoredReason: "tail-message-before-current-turn"
                    )
                }
                if event.role != "user" {
                    return OpenCodeStateMachineResult(
                        session: existing,
                        transition: "ignored",
                        ignoredReason: "post-terminal-non-user-message"
                    )
                }
            } else {
                if event.role == "user",
                   let messageID = event.messageID,
                   messageID != existing.currentTurnMessageID {
                    return startNewMessageTurn(existing: existing, event: event, now: now)
                }
                return OpenCodeStateMachineResult(
                    session: existing,
                    transition: "ignored",
                    ignoredReason: "post-terminal-message-without-created-at"
                )
            }
        }

        let turnStartedAt: Date
        if event.role == "user" {
            turnStartedAt = event.messageCreatedAt ?? now
        } else {
            turnStartedAt = existing?.currentTurnStartedAt ?? event.messageCreatedAt ?? now
        }

        return transition(
            existing: existing,
            event: event,
            state: .running,
            runningDetail: .thinking,
            updatedAt: now,
            currentTurnStartedAt: turnStartedAt,
            currentTurnMessageID: event.role == "user" ? (event.messageID ?? existing?.currentTurnMessageID) : existing?.currentTurnMessageID,
            terminalAt: nil,
            transition: "running.thinking.message"
        )
    }

    private static func startNewMessageTurn(
        existing: OpenCodeTrackedSession,
        event: OpenCodeEventContext,
        now: Date
    ) -> OpenCodeStateMachineResult {
        transition(
            existing: existing,
            event: event,
            state: .running,
            runningDetail: .thinking,
            updatedAt: now,
            currentTurnStartedAt: event.messageCreatedAt ?? now,
            currentTurnMessageID: event.messageID,
            terminalAt: nil,
            transition: "running.thinking.new-user-message"
        )
    }

    private static func isKnownTailMessage(existing: OpenCodeTrackedSession, event: OpenCodeEventContext) -> Bool {
        guard let messageID = event.messageID,
              let currentTurnMessageID = existing.currentTurnMessageID else {
            return true
        }
        return messageID == currentTurnMessageID
    }

    private static func transition(
        existing: OpenCodeTrackedSession?,
        event: OpenCodeEventContext,
        state: IslandCodexActivityState,
        runningDetail: IslandRunningDetail?,
        updatedAt: Date,
        currentTurnStartedAt: Date?,
        currentTurnMessageID: String?,
        terminalAt: Date?,
        transition: String
    ) -> OpenCodeStateMachineResult {
        let session = OpenCodeTrackedSession(
            id: event.sessionID,
            title: event.title ?? existing?.title ?? "OpenCode Session",
            detail: event.cwd ?? existing?.detail ?? event.detail,
            state: state,
            runningDetail: state == .running ? runningDetail : nil,
            updatedAt: updatedAt,
            cwd: event.cwd ?? existing?.cwd,
            focusTarget: event.cwd == nil ? (existing?.focusTarget ?? event.focusTarget) : event.focusTarget,
            currentTurnStartedAt: currentTurnStartedAt,
            currentTurnMessageID: currentTurnMessageID,
            terminalAt: terminalAt,
            lastEventType: event.type
        )
        return OpenCodeStateMachineResult(session: session, transition: transition, ignoredReason: nil)
    }

    private static func metadataOnly(
        existing: OpenCodeTrackedSession?,
        event: OpenCodeEventContext,
        now: Date,
        ignoredReason: String
    ) -> OpenCodeStateMachineResult {
        guard let existing else {
            let session = OpenCodeTrackedSession(
                id: event.sessionID,
                title: event.title ?? "OpenCode Session",
                detail: event.cwd ?? event.detail,
                state: .idle,
                runningDetail: nil,
                updatedAt: now,
                cwd: event.cwd,
                focusTarget: event.focusTarget,
                currentTurnStartedAt: nil,
                currentTurnMessageID: nil,
                terminalAt: nil,
                lastEventType: event.type
            )
            return OpenCodeStateMachineResult(session: session, transition: "idle.metadata", ignoredReason: ignoredReason)
        }

        let session = OpenCodeTrackedSession(
            id: existing.id,
            title: event.title ?? existing.title,
            detail: event.cwd ?? existing.detail,
            state: existing.state,
            runningDetail: existing.runningDetail,
            updatedAt: existing.updatedAt,
            cwd: event.cwd ?? existing.cwd,
            focusTarget: event.cwd == nil ? existing.focusTarget : event.focusTarget,
            currentTurnStartedAt: existing.currentTurnStartedAt,
            currentTurnMessageID: existing.currentTurnMessageID,
            terminalAt: existing.terminalAt,
            lastEventType: event.type
        )
        return OpenCodeStateMachineResult(session: session, transition: "metadata", ignoredReason: ignoredReason)
    }

    private static func isRunningStatus(_ status: String?) -> Bool {
        guard let normalized = status?.lowercased() else {
            return false
        }

        return ["run", "running", "busy", "work", "working", "stream", "streaming", "active"]
            .contains { normalized.contains($0) }
    }

    private static func isRejected(_ reply: String?) -> Bool {
        guard let reply else {
            return false
        }
        return ["reject", "rejected", "deny", "denied", "false", "no"].contains { reply.contains($0) }
    }

    private static func terminalTransitionName(for event: OpenCodeEventContext) -> String {
        if event.partType == "step-finish" {
            return "success.step-finish"
        }
        return "success.assistant-final"
    }
}

private struct OpenCodeEventDiagnostic {
    let type: String
    let sessionID: String?
    let role: String?
    let messageID: String?
    let partType: String?
    let status: String?
    let computedTransition: String
    let ignoredReason: String?
    let createdAt: Date

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "type": type,
            "computedTransition": computedTransition,
            "at": ISO8601DateFormatter().string(from: createdAt)
        ]
        if let sessionID {
            result["sessionID"] = sessionID
        }
        if let role {
            result["role"] = role
        }
        if let messageID {
            result["messageID"] = messageID
        }
        if let partType {
            result["partType"] = partType
        }
        if let status {
            result["status"] = status
        }
        if let ignoredReason {
            result["ignoredReason"] = ignoredReason
        }
        return result
    }
}

private struct OpenCodePendingApproval {
    let request: ApprovalRequest
    let sessionID: String
    let requestID: String
    let serverBaseURL: URL?
}

private struct OpenCodeQueuedApprovalDecision {
    let approvalID: String
    let requestID: String
    let reply: String
    let message: String?
    let createdAt: Date
}

private struct OpenCodePendingQuestion {
    let prompt: ClaudeQuestionPrompt
    let rawQuestionID: String?
    let createdAt: Date
}

private struct OpenCodeQueuedQuestionDecision {
    let questionID: String
    let status: String
    let answers: [[String]]
    let output: String
    let createdAt: Date
}

private struct OpenCodePluginDebugEvent {
    let stage: String
    let requestID: String?
    let sessionID: String?
    let message: String?
    let createdAt: Date

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "stage": stage,
            "at": ISO8601DateFormatter().string(from: createdAt)
        ]
        if let requestID {
            result["requestID"] = requestID
        }
        if let sessionID {
            result["sessionID"] = sessionID
        }
        if let message {
            result["message"] = message
        }
        return result
    }
}

private struct OpenCodeHTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let body: Data
}

private extension IslandCodexActivityState {
    var isActive: Bool {
        switch self {
        case .running:
            return true
        case .idle, .success, .failure:
            return false
        }
    }
}
