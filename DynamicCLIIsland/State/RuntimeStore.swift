//
//  RuntimeStore.swift
//  HermitFlow
//
//  Phase 4 reducer-backed runtime store.
//

import AppKit
import Foundation

@MainActor
final class RuntimeStore: ObservableObject {
    typealias SourceMode = IslandSourceMode
    typealias CodexActivityState = IslandCodexActivityState

    @Published var tasks: [CLIJob] = []
    @Published private(set) var codexStatus: CodexActivityState = .idle
    @Published private(set) var sessions: [AgentSessionSnapshot] = []
    @Published var sourceMode: SourceMode = .demo
    @Published var externalFilePath: String?
    @Published var statusMessage = "Waiting for CLI status"
    @Published var lastUpdatedAt = Date()
    @Published var errorMessage: String?
    @Published private(set) var focusTarget: FocusTarget?
    @Published private(set) var approvalRequest: ApprovalRequest?
    @Published private(set) var approvalDiagnostic: ApprovalDiagnostic?
    @Published private(set) var approvalDiagnosticMessage: String?
    @Published private(set) var accessibilityPermissionGranted = false
    @Published private(set) var accessibilityPromptDismissed: Bool
    @Published private(set) var usageSnapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var usageProviderState: UsageProviderState = .empty
    @Published private(set) var sourceHealthReports: [SourceHealthReport] = []

    var claudeUsageSnapshot: ClaudeUsageSnapshot? {
        usageProviderState.claude
    }

    var codexUsageSnapshot: CodexUsageSnapshot? {
        usageProviderState.codex
    }

    private let localCodexPollInterval: TimeInterval = 1.0
    private let localApprovalPollInterval: TimeInterval = 0.25
    private let accessibilityPermissionPollInterval: TimeInterval = 1.0
    private let usageRefreshMinimumInterval: TimeInterval = 30.0
    private let accessibilityPromptDismissedDefaultsKey = "HermitFlow.accessibilityPromptDismissed"

    private var timer: Timer?
    private var approvalTimer: Timer?
    private var accessibilityTimer: Timer?
    private var localCodexRefreshInFlight = false
    private var localApprovalRefreshInFlight = false
    private var usageRefreshInFlight = false
    private var codexRealtimeSourceStarted = false
    private var lastFileModificationDate: Date?
    private var lastUsageRefreshAt: Date?
    private var reducer = RuntimeReducer()
    private var reducerState = RuntimeReducer.State()

    // TODO: Remove these legacy dependencies once reducer migration is complete.
    let sessionStore: SessionStore
    let approvalStore: ApprovalStore
    let focusRouter: FocusRouter
    let focusLauncher: FocusLauncher
    let notificationSoundPlayer: NotificationSoundPlayer
    let accessibilityPermissionMonitor: AccessibilityPermissionMonitor
    let localCodexSource: LocalCodexSource
    let localClaudeSource: LocalClaudeSource
    let claudeUsageSource: ClaudeUsageSource
    let codexUsageSource: CodexRolloutUsageSource
    let claudeHookInstaller: ClaudeHookInstaller
    let claudeHookHealthChecker: ClaudeHookHealthChecker
    let claudeHookBootstrap: ClaudeHookBootstrap
    let claudeHTTPCallbackServer: ClaudeHTTPCallbackServer
    let codexHookSource: CodexHookSource
    let codexSQLiteReader: CodexSQLiteReader
    let codexSessionReader: CodexSessionReader
    let codexLogReader: CodexLogReader
    let localCodexQueue: DispatchQueue
    let localApprovalQueue: DispatchQueue
    let usageQueue: DispatchQueue
    let externalProgressSource: ExternalProgressFileSource
    let demoProgressSource: DemoProgressSource
    let decoder: JSONDecoder
    let accessibilityApprovalExecutor: AccessibilityApprovalExecutor
    let httpHookApprovalExecutor: HTTPHookApprovalExecutor

    weak var presentationStore: PresentationStore?

    init(
        sessionStore: SessionStore = SessionStore(),
        approvalStore: ApprovalStore = ApprovalStore(),
        focusRouter: FocusRouter = FocusRouter(),
        focusLauncher: FocusLauncher = FocusLauncher(),
        notificationSoundPlayer: NotificationSoundPlayer = NotificationSoundPlayer(),
        accessibilityPermissionMonitor: AccessibilityPermissionMonitor = AccessibilityPermissionMonitor(),
        localCodexSource: LocalCodexSource = LocalCodexSource(),
        localClaudeSource: LocalClaudeSource = LocalClaudeSource(),
        claudeUsageSource: ClaudeUsageSource = ClaudeUsageSource(),
        codexUsageSource: CodexRolloutUsageSource = CodexRolloutUsageSource(),
        claudeHookInstaller: ClaudeHookInstaller? = nil,
        claudeHookHealthChecker: ClaudeHookHealthChecker? = nil,
        claudeHookBootstrap: ClaudeHookBootstrap? = nil,
        claudeHTTPCallbackServer: ClaudeHTTPCallbackServer? = nil,
        codexHookSource: CodexHookSource? = nil,
        codexSQLiteReader: CodexSQLiteReader = CodexSQLiteReader(),
        codexSessionReader: CodexSessionReader = CodexSessionReader(),
        codexLogReader: CodexLogReader = CodexLogReader(),
        localCodexQueue: DispatchQueue = DispatchQueue(label: "HermitFlow.localCodex", qos: .utility),
        localApprovalQueue: DispatchQueue = DispatchQueue(label: "HermitFlow.localApproval", qos: .userInitiated),
        usageQueue: DispatchQueue = DispatchQueue(label: "HermitFlow.usage", qos: .utility),
        externalProgressSource: ExternalProgressFileSource = ExternalProgressFileSource(),
        demoProgressSource: DemoProgressSource = DemoProgressSource(),
        accessibilityApprovalExecutor: AccessibilityApprovalExecutor? = nil,
        httpHookApprovalExecutor: HTTPHookApprovalExecutor? = nil,
        decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    ) {
        self.sessionStore = sessionStore
        self.approvalStore = approvalStore
        self.focusRouter = focusRouter
        self.focusLauncher = focusLauncher
        self.notificationSoundPlayer = notificationSoundPlayer
        self.accessibilityPermissionMonitor = accessibilityPermissionMonitor
        self.localCodexSource = localCodexSource
        self.localClaudeSource = localClaudeSource
        self.claudeUsageSource = claudeUsageSource
        self.codexUsageSource = codexUsageSource
        let resolvedClaudeHookInstaller = claudeHookInstaller ?? ClaudeHookInstaller(source: localClaudeSource)
        let resolvedClaudeHTTPCallbackServer = claudeHTTPCallbackServer ?? ClaudeHTTPCallbackServer(source: localClaudeSource)
        let resolvedClaudeHookHealthChecker = claudeHookHealthChecker ?? ClaudeHookHealthChecker(
            installer: resolvedClaudeHookInstaller,
            callbackServer: resolvedClaudeHTTPCallbackServer
        )
        self.claudeHookInstaller = resolvedClaudeHookInstaller
        self.claudeHTTPCallbackServer = resolvedClaudeHTTPCallbackServer
        self.claudeHookHealthChecker = resolvedClaudeHookHealthChecker
        self.claudeHookBootstrap = claudeHookBootstrap ?? ClaudeHookBootstrap(
            installer: resolvedClaudeHookInstaller,
            callbackServer: resolvedClaudeHTTPCallbackServer,
            healthChecker: resolvedClaudeHookHealthChecker
        )
        self.codexHookSource = codexHookSource ?? CodexHookSource(source: localCodexSource, sessionReader: codexSessionReader)
        self.codexSQLiteReader = codexSQLiteReader
        self.codexSessionReader = codexSessionReader
        self.codexLogReader = codexLogReader
        self.localCodexQueue = localCodexQueue
        self.localApprovalQueue = localApprovalQueue
        self.usageQueue = usageQueue
        self.externalProgressSource = externalProgressSource
        self.demoProgressSource = demoProgressSource
        self.decoder = decoder
        self.accessibilityApprovalExecutor = accessibilityApprovalExecutor
            ?? AccessibilityApprovalExecutor(
                focusLauncher: focusLauncher,
                accessibilityPermissionMonitor: accessibilityPermissionMonitor
            )
        self.httpHookApprovalExecutor = httpHookApprovalExecutor
            ?? HTTPHookApprovalExecutor(localClaudeSource: localClaudeSource)
        accessibilityPromptDismissed = UserDefaults.standard.bool(forKey: accessibilityPromptDismissedDefaultsKey)
    }

    func handleLaunch() {
        let claudeReport = claudeHookBootstrap.bootstrap()
        refreshSourceHealthReports(claudeReport: claudeReport)
        refreshAccessibilityPermissionStatus()
        refreshUsageIfNeeded(force: true)
        startLocalCodexMonitoring()
    }

    func handleAppDidBecomeActive() {
        refreshAccessibilityPermissionStatus()
        refreshUsageIfNeeded(force: true)
        refreshSourceHealthReports()
    }

    func dispatch(_ event: IslandEvent) {
        reducer.apply(event, to: &reducerState)
        resolvePresentationState()
    }

    func dispatch(_ events: [IslandEvent]) {
        reducer.apply(events, to: &reducerState)
        resolvePresentationState()
    }

    func bringForward(_ target: FocusTarget?) {
        guard let target else {
            dispatch(.runtimeErrorUpdated("No focus target available"))
            return
        }

        dispatch(.runtimeErrorUpdated(nil))
        dispatch(.runtimeStatusMessageUpdated("Opening \(target.displayName)"))

        guard focusLauncher.bringToFront(target) else {
            dispatch(.runtimeErrorUpdated("Unable to locate \(target.displayName)"))
            return
        }
    }

    func openAccessibilitySettings() {
        dispatch(.runtimeErrorUpdated(nil))

        guard focusLauncher.openAccessibilitySettings() else {
            dispatch(.runtimeErrorUpdated("无法打开辅助功能设置"))
            return
        }

        dispatch(.runtimeStatusMessageUpdated("已打开辅助功能设置"))
        beginAccessibilityPermissionPolling()
    }

    func resyncClaudeHooks() {
        dispatch(.runtimeStatusMessageUpdated("Resyncing Claude hooks"))
        do {
            try claudeHookInstaller.resync()
        } catch {
            dispatch(.runtimeErrorUpdated("Claude hook resync failed"))
        }
        refreshSourceHealthReports()
        refreshLocalCodexStatus()
        refreshLocalApprovalStatus()
    }

    func dismissAccessibilityPrompt() {
        accessibilityPromptDismissed = true
        UserDefaults.standard.set(true, forKey: accessibilityPromptDismissedDefaultsKey)
        stopAccessibilityPermissionPolling()
    }

    func rejectApproval() {
        guard let request = approvalRequest else {
            dispatch(.runtimeErrorUpdated("No approval request available"))
            return
        }

        executeApproval(.reject, request: request)
    }

    func acceptApproval() {
        guard let request = approvalRequest else {
            dispatch(.runtimeErrorUpdated("No approval request available"))
            return
        }

        executeApproval(.accept, request: request)
    }

    func acceptAllApprovals() {
        guard let request = approvalRequest else {
            dispatch(.runtimeErrorUpdated("No approval request available"))
            return
        }

        executeApproval(.acceptAll, request: request)
    }

    func collapseInlineApproval() {
        presentationStore?.collapseInlineApproval()
        reducer.setCollapsedApprovalRequestID(presentationStore?.collapsedInlineApprovalID, state: &reducerState)
        resolvePresentationState()
    }

    func toggleApprovalPreview() {
        presentationStore?.toggleApprovalPreview()
        reducer.setApprovalPreviewRequest(
            presentationStore?.approvalPreviewEnabled == true ? makePreviewApprovalRequest() : nil,
            state: &reducerState
        )
        resolvePresentationState()
    }

    func startLocalCodexMonitoring() {
        sourceMode = .localCodex
        externalFilePath = nil
        lastFileModificationDate = nil
        dispatch([
            .diagnosticUpdated(DiagnosticsEvent(approvalDiagnosticMessage: nil)),
            .runtimeStatusMessageUpdated("Loading local Codex activity")
        ])
        refreshUsageIfNeeded(force: true)
        startCodexRealtimeSourceIfNeeded()
        refreshSourceHealthReports()
        refreshLocalCodexStatus()
        refreshLocalApprovalStatus()
        restartTimer(interval: localCodexPollInterval) { [weak self] in
            self?.refreshLocalCodexStatus()
        }
        restartApprovalTimer(interval: localApprovalPollInterval) { [weak self] in
            self?.refreshLocalApprovalStatus()
        }
    }

    func startDemoMode() {
        codexHookSource.stop()
        codexRealtimeSourceStarted = false
        stopApprovalTimer()
        sourceMode = .demo
        externalFilePath = nil
        lastFileModificationDate = nil
        dispatch([
            .approvalResolved(
                ApprovalEvent(
                    requestID: approvalRequest?.id ?? "demo-clear",
                    source: .generic,
                    resolutionKind: .accessibilityAutomation
                )
            ),
            .diagnosticUpdated(DiagnosticsEvent(approvalDiagnosticMessage: nil))
        ])
        let initialTasks = demoProgressSource.makeInitialTasks()
        dispatch(events(from: ProgressEnvelope(generatedAt: .now, tasks: initialTasks),
                        sourceLabel: "Watching simulated Claude/Codex tasks",
                        errorMessage: nil))
        refreshSourceHealthReports()
        restartTimer(interval: 1.0) { [weak self] in
            self?.advanceDemoTasks()
        }
    }

    func chooseProgressFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = "Select a JSON file with CLI progress"

        if panel.runModal() == .OK, let url = panel.url {
            attachProgressFile(url)
        }
    }

    func attachProgressFile(_ url: URL) {
        codexHookSource.stop()
        codexRealtimeSourceStarted = false
        stopApprovalTimer()
        sourceMode = .file(url)
        externalFilePath = url.path
        dispatch([
            .diagnosticUpdated(DiagnosticsEvent(approvalDiagnosticMessage: nil)),
            .runtimeStatusMessageUpdated("Watching \(url.lastPathComponent)")
        ])
        refreshUsageIfNeeded(force: true)
        refreshSourceHealthReports()
        loadFromFile(url)
        restartTimer(interval: 1.0) { [weak self] in
            self?.refreshExternalFileIfNeeded()
        }
    }

    func refreshLocalCodexStatus() {
        guard !localCodexRefreshInFlight else {
            return
        }

        localCodexRefreshInFlight = true
        let source = localCodexSource
        let claudeSource = localClaudeSource
        localCodexQueue.async { [weak self] in
            let codexSnapshot = source.fetchActivity()
            let claudeSnapshot = claudeSource.fetchActivity()
            let snapshot = ActivitySnapshotMerger.merge(codexSnapshot, claudeSnapshot)

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.localCodexRefreshInFlight = false
                guard case .localCodex = self.sourceMode else {
                    return
                }

                self.apply(activitySnapshot: snapshot)
                self.refreshUsageIfNeeded()
            }
        }
    }

    func refreshLocalApprovalStatus() {
        guard !localApprovalRefreshInFlight else {
            return
        }

        localApprovalRefreshInFlight = true
        let source = localCodexSource
        let claudeSource = localClaudeSource
        localApprovalQueue.async { [weak self] in
            let codexApprovalProbe = source.fetchApprovalProbeResult()
            let approvalRequest = ApprovalRequestMerger.merge(
                codexApprovalProbe.pendingRequest,
                claudeSource.fetchLatestApprovalRequest()
            )

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.localApprovalRefreshInFlight = false
                guard case .localCodex = self.sourceMode else {
                    return
                }

                var events = codexApprovalProbe.resolvedRequestIDs.map {
                    IslandEvent.approvalResolved(
                        ApprovalEvent(
                            requestID: $0,
                            source: .codex,
                            resolutionKind: .accessibilityAutomation
                        )
                    )
                }

                if approvalRequest == nil,
                   let currentApprovalRequest = self.reducerState.approvalRequest,
                   !codexApprovalProbe.resolvedRequestIDs.contains(currentApprovalRequest.id) {
                    // Treat disappearance from the local approval sources as resolution so the
                    // panel and inline approval UI collapse when the user acts in the terminal.
                    events.append(
                        .approvalResolved(
                            ApprovalEvent(
                                requestID: currentApprovalRequest.id,
                                source: currentApprovalRequest.source,
                                resolutionKind: currentApprovalRequest.resolutionKind
                            )
                        )
                    )
                }

                if let approvalRequest {
                    events.append(.approvalRequested(ApprovalEvent(request: approvalRequest)))
                }

                if !events.isEmpty {
                    self.dispatch(events)
                }
            }
        }
    }

    func refreshClaudeUsage() {
        refreshUsageIfNeeded(force: true, includeCodex: false)
    }

    func refreshCodexUsage() {
        refreshUsageIfNeeded(force: true, includeClaude: false)
    }

    func apply(activitySnapshot: ActivitySourceSnapshot) {
        let knownSessionIDs = Set(reducerState.sessionState.sessionsByID.keys)
        let events = ActivitySnapshotEventAdapter.events(from: activitySnapshot, knownSessionIDs: knownSessionIDs)
        dispatch(events)
    }

    func apply(runtimeState: IslandRuntimeState) {
        let snapshot = ActivitySourceSnapshot(
            sessions: runtimeState.sessions,
            statusMessage: runtimeState.statusMessage,
            lastUpdatedAt: runtimeState.lastUpdatedAt,
            errorMessage: runtimeState.errorMessage,
            approvalRequest: runtimeState.approvalRequest,
            usageSnapshots: runtimeState.usageSnapshots
        )
        apply(activitySnapshot: snapshot)
    }

    func resolvePresentationState() {
        let previousWindowSize = presentationStore?.windowSize
        let previousCodexStatus = codexStatus
        let previousApprovalRequest = approvalRequest
        let previousApprovalRequestID = previousApprovalRequest?.id

        let liveApprovalRequest = reducerState.approvalRequest
        let previewApprovalRequest = reducerState.approvalState.previewRequest
        let resolvedApprovalRequest = previewApprovalRequest
            ?? liveApprovalRequest
            ?? preservedCodexApprovalRequest(from: previousApprovalRequest)
        let shouldForceRunningStatus = resolvedApprovalRequest != nil
            && reducerState.approvalState.collapsedRequestID != resolvedApprovalRequest?.id
        let resolvedCodexStatus: CodexActivityState = shouldForceRunningStatus ? .running : reducerState.codexStatus
        let resolvedFocusTarget = resolvedApprovalRequest?.focusTarget
            ?? focusRouter.preferredTarget(from: reducerState.sessions, approvalRequest: liveApprovalRequest)

        if let resolvedApprovalRequest {
            if reducerState.approvalState.collapsedRequestID != resolvedApprovalRequest.id,
               approvalRequest?.id != resolvedApprovalRequest.id {
                presentationStore?.resetCollapsedInlineApproval()
                reducer.setCollapsedApprovalRequestID(nil, state: &reducerState)
                reducer.setApprovalDiagnostic(nil, state: &reducerState)
            }
        } else {
            presentationStore?.resetCollapsedInlineApproval()
            reducer.setCollapsedApprovalRequestID(nil, state: &reducerState)
            reducer.setApprovalDiagnostic(nil, state: &reducerState)
        }

        reducerState.focusTarget = resolvedFocusTarget

        sessions = reducerState.sessions
        tasks = reducerState.tasks
        codexStatus = resolvedCodexStatus
        statusMessage = reducerState.approvalState.previewRequest != nil
            ? "Previewing approval UI"
            : reducerState.statusMessage
        lastUpdatedAt = reducerState.lastUpdatedAt
        errorMessage = reducerState.errorMessage?.isEmpty == true ? nil : reducerState.errorMessage
        approvalRequest = resolvedApprovalRequest
        approvalDiagnostic = reducerState.approvalDiagnostic
        approvalDiagnosticMessage = reducerState.approvalDiagnostic?.message
        focusTarget = resolvedFocusTarget
        usageSnapshots = reducerState.usageSnapshots
        usageProviderState = reducerState.usageProviderState

        presentationStore?.syncRuntimeContext(
            approvalRequest: resolvedApprovalRequest,
            sessions: reducerState.sessions,
            usageCardCount: reducerState.usageProviderState.usageCardCount
        )

        let shouldPlayApprovalSound = reducerState.approvalState.previewRequest == nil
            && resolvedApprovalRequest?.id != nil
            && resolvedApprovalRequest?.id != previousApprovalRequestID
        let shouldPlaySuccessSound = previousCodexStatus != .success && resolvedCodexStatus == .success

        if presentationStore?.isSoundMuted != true && (shouldPlayApprovalSound || shouldPlaySuccessSound) {
            notificationSoundPlayer.playNotificationPing()
        }

        if previousWindowSize != presentationStore?.windowSize {
            presentationStore?.onWindowSizeChange?(presentationStore?.windowSize ?? .zero)
        }
    }

    private func executeApproval(_ decision: ApprovalDecision, request: ApprovalRequest) {
        dispatch(.runtimeErrorUpdated(nil))

        let executorResult: ApprovalExecutionResult
        switch request.resolutionKind {
        case .localHTTPHook:
            executorResult = httpHookApprovalExecutor.execute(decision: decision, request: request)
        case .accessibilityAutomation:
            refreshAccessibilityPermissionStatus()
            executorResult = accessibilityApprovalExecutor.execute(decision: decision, request: request)
        }

        applyApprovalExecutionResult(executorResult, for: request)
    }

    private func applyApprovalExecutionResult(_ result: ApprovalExecutionResult, for request: ApprovalRequest) {
        reducer.setApprovalDiagnostic(result.diagnostic, state: &reducerState)

        if let statusMessage = result.statusMessage {
            dispatch(.runtimeStatusMessageUpdated(statusMessage))
        }

        switch result.outcome {
        case .succeeded:
            var events: [IslandEvent] = []
            if result.statusMessage != nil {
                events.append(.runtimeStatusMessageUpdated(result.statusMessage!))
            }
            events.append(.diagnosticUpdated(DiagnosticsEvent(approvalDiagnosticMessage: nil)))
            if result.shouldResolveRequest {
                events.append(.approvalResolved(ApprovalEvent(request: request)))
            }
            dispatch(events)
        case .routedToManualHandling:
            if let diagnostic = result.diagnostic {
                reducer.setApprovalDiagnostic(diagnostic, state: &reducerState)
            }
            resolvePresentationState()
        case .failed:
            if let diagnostic = result.diagnostic {
                if diagnostic.severity == .error {
                    dispatch(.runtimeErrorUpdated(diagnostic.message))
                } else {
                    reducer.setApprovalDiagnostic(diagnostic, state: &reducerState)
                    resolvePresentationState()
                }
            }
            if result.statusMessage == nil, result.diagnostic == nil {
                dispatch(.runtimeErrorUpdated("Approval execution failed"))
            }
        }
    }

    private func refreshAccessibilityPermissionStatus() {
        accessibilityPermissionGranted = accessibilityPermissionMonitor.isTrusted()
        if accessibilityPermissionGranted {
            accessibilityPromptDismissed = false
            UserDefaults.standard.set(false, forKey: accessibilityPromptDismissedDefaultsKey)
            stopAccessibilityPermissionPolling()
            return
        }

        if !accessibilityPromptDismissed {
            beginAccessibilityPermissionPolling()
        }
    }

    private func beginAccessibilityPermissionPolling() {
        guard accessibilityTimer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: accessibilityPermissionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityPermissionStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    private func stopAccessibilityPermissionPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    private func refreshUsageIfNeeded(
        force: Bool = false,
        includeClaude: Bool = true,
        includeCodex: Bool = true
    ) {
        guard force || shouldRefreshUsage(now: .now) else {
            return
        }

        guard !usageRefreshInFlight else {
            return
        }

        usageRefreshInFlight = true
        let existingState = reducerState.usageProviderState
        let claudeUsageSource = self.claudeUsageSource
        let codexUsageSource = self.codexUsageSource

        usageQueue.async { [weak self] in
            let claudeSnapshot = includeClaude ? claudeUsageSource.fetchUsageSnapshot() : existingState.claude
            let codexSnapshot = includeCodex ? codexUsageSource.fetchUsageSnapshot() : existingState.codex
            let providerState = UsageProviderState(
                claude: claudeSnapshot,
                codex: codexSnapshot
            )

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.usageRefreshInFlight = false
                self.lastUsageRefreshAt = .now
                self.dispatch(.usageProviderStateUpdated(providerState))
            }
        }
    }

    private func shouldRefreshUsage(now: Date) -> Bool {
        guard let lastUsageRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastUsageRefreshAt) >= usageRefreshMinimumInterval
    }

    private func startCodexRealtimeSourceIfNeeded() {
        guard !codexRealtimeSourceStarted else {
            return
        }

        let started = codexHookSource.start(
            knownSessionIDs: { [] },
            eventSink: { [weak self] events in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    guard case .localCodex = self.sourceMode else {
                        return
                    }

                    self.dispatch(events)
                }
            }
        )

        codexRealtimeSourceStarted = started
    }

    private func refreshSourceHealthReports(claudeReport: SourceHealthReport? = nil) {
        let effectiveClaudeReport = filteredHealthReport(claudeReport ?? claudeHookHealthChecker.healthReport())
        let codexIssues = filteredHealthIssues(
            codexHookSource.healthReport().issues
                + codexSQLiteReader.healthIssues()
                + codexSessionReader.healthIssues()
                + codexLogReader.healthIssues()
        )
        let codexReport = SourceHealthReport(sourceName: "Codex", issues: codexIssues)

        sourceHealthReports = [effectiveClaudeReport, codexReport].filter(\.hasIssues)
    }

    private func filteredHealthReport(_ report: SourceHealthReport) -> SourceHealthReport {
        SourceHealthReport(sourceName: report.sourceName, issues: filteredHealthIssues(report.issues))
    }

    private func filteredHealthIssues(_ issues: [DiagnosticIssue]) -> [DiagnosticIssue] {
        let severeIssues = issues.filter { $0.severity != .info }
        return severeIssues.isEmpty ? [] : severeIssues
    }

    private func refreshExternalFileIfNeeded() {
        guard case let .file(url) = sourceMode else {
            return
        }

        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if values.contentModificationDate != lastFileModificationDate {
                loadFromFile(url)
            }
        } catch {
            dispatch(.runtimeErrorUpdated("Cannot read file metadata"))
        }
    }

    private func loadFromFile(_ url: URL) {
        do {
            let envelope = try externalProgressSource.loadEnvelope(from: url, using: decoder)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            lastFileModificationDate = values.contentModificationDate
            dispatch(events(from: envelope, sourceLabel: "Watching \(url.lastPathComponent)", errorMessage: nil))
        } catch {
            let failureState = sessionStore.makeFailureState(
                statusMessage: "Watching \(url.lastPathComponent)",
                errorMessage: "JSON parse failed"
            )
            apply(runtimeState: failureState)
        }
    }

    private func advanceDemoTasks() {
        let updated = demoProgressSource.advance(tasks)
        dispatch(events(from: ProgressEnvelope(generatedAt: .now, tasks: updated),
                        sourceLabel: "Watching simulated Claude/Codex tasks",
                        errorMessage: nil))
    }

    private func events(
        from progressEnvelope: ProgressEnvelope,
        sourceLabel: String,
        errorMessage: String?
    ) -> [IslandEvent] {
        let sortedTasks = progressEnvelope.tasks.sorted { lhs, rhs in
            if lhs.stage == .running && rhs.stage != .running {
                return true
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let knownSessionIDs = Set(reducerState.sessionState.sessionsByID.keys)
        var events: [IslandEvent] = sortedTasks.map { task in
            let payload = reducer.sessionEvent(from: task)
            if [.success, .failed].contains(task.stage) {
                return .sessionCompleted(payload)
            }
            if knownSessionIDs.contains(task.id) {
                return .sessionUpdated(payload)
            }
            return .sessionStarted(payload)
        }

        events.append(.sessionsReconciled(currentSessionIDs: sortedTasks.map(\.id), capturedAt: progressEnvelope.generatedAt))
        events.append(.runtimeStatusMessageUpdated(sourceLabel))
        events.append(.runtimeErrorUpdated(errorMessage))
        events.append(.runtimeLastUpdated(progressEnvelope.generatedAt))
        events.append(.usageSnapshotsUpdated([]))
        return events
    }

    private func restartTimer(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func restartApprovalTimer(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        approvalTimer?.invalidate()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        RunLoop.main.add(approvalTimer!, forMode: .common)
    }

    private func stopApprovalTimer() {
        approvalTimer?.invalidate()
        approvalTimer = nil
        localApprovalRefreshInFlight = false
    }

    private func preservedCodexApprovalRequest(from previousApprovalRequest: ApprovalRequest?) -> ApprovalRequest? {
        guard
            let previousApprovalRequest,
            previousApprovalRequest.source == .codex,
            !reducerState.approvalState.resolvedRequestIDs.contains(previousApprovalRequest.id)
        else {
            return nil
        }

        return previousApprovalRequest
    }

    private func makePreviewApprovalRequest() -> ApprovalRequest {
        let previewTarget = focusTarget ?? FocusTarget(
            clientOrigin: .codexCLI,
            sessionID: "preview-approval",
            displayName: "Warp Codex",
            cwd: "/Users/fuyue/Documents/New project",
            terminalClient: .warp
        )

        return ApprovalRequest(
            id: "preview-approval",
            commandSummary: "open -a Calculator",
            rationale: "Preview approval UI in island mode without waiting for a real pending request.",
            focusTarget: previewTarget,
            createdAt: .now,
            source: .generic,
            resolutionKind: .accessibilityAutomation
        )
    }
}
