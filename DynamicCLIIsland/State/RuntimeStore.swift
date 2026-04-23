//
//  RuntimeStore.swift
//  HermitFlow
//
//  Phase 4 reducer-backed runtime store.
//

import AppKit
import Foundation

struct PollingBackoffPolicy: Equatable {
    let activeInterval: TimeInterval
    let idleInterval: TimeInterval
    let approvalActiveInterval: TimeInterval
    let approvalIdleInterval: TimeInterval
    let recentChangeWindow: TimeInterval

    init(
        activeInterval: TimeInterval = 5.0,
        idleInterval: TimeInterval = 15.0,
        approvalActiveInterval: TimeInterval = 5.0,
        approvalIdleInterval: TimeInterval = 15.0,
        recentChangeWindow: TimeInterval = 30.0
    ) {
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
        self.approvalActiveInterval = approvalActiveInterval
        self.approvalIdleInterval = approvalIdleInterval
        self.recentChangeWindow = recentChangeWindow
    }

    func activityInterval(isActive: Bool, lastChangedAt: Date?, now: Date = .now) -> TimeInterval {
        if isActive || isRecent(lastChangedAt, now: now) {
            return activeInterval
        }
        return idleInterval
    }

    func approvalInterval(
        isActive: Bool,
        hasPendingApproval: Bool,
        lastChangedAt: Date?,
        now: Date = .now
    ) -> TimeInterval {
        if hasPendingApproval || isRecent(lastChangedAt, now: now) {
            return approvalActiveInterval
        }
        return approvalIdleInterval
    }

    private func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date else {
            return true
        }
        return now.timeIntervalSince(date) < recentChangeWindow
    }
}

final class LocalSourceFileWatcher: @unchecked Sendable {
    typealias EventHandler = @Sendable () -> Void

    private struct WatchTarget {
        let url: URL
        let eventMask: DispatchSource.FileSystemEvent
        let triggersActivity: Bool
        let triggersApproval: Bool
    }

    private struct Monitor {
        let fileDescriptor: CInt
        let source: DispatchSourceFileSystemObject
    }

    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private var monitors: [Monitor] = []
    private var pendingActivityRefresh: DispatchWorkItem?
    private var pendingApprovalRefresh: DispatchWorkItem?
    private var onActivityChange: EventHandler?
    private var onApprovalChange: EventHandler?
    private var running = false

    init(
        debounceInterval: TimeInterval = 0.25,
        queue: DispatchQueue = DispatchQueue(label: "HermitFlow.localSourceFileWatcher", qos: .utility)
    ) {
        self.debounceInterval = debounceInterval
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start(
        onActivityChange: @escaping EventHandler,
        onApprovalChange: @escaping EventHandler
    ) {
        queue.sync {
            stopLocked()
            self.onActivityChange = onActivityChange
            self.onApprovalChange = onApprovalChange
            for target in Self.watchTargets() {
                startMonitor(for: target)
            }
            running = !monitors.isEmpty
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func stopLocked() {
        pendingActivityRefresh?.cancel()
        pendingActivityRefresh = nil
        pendingApprovalRefresh?.cancel()
        pendingApprovalRefresh = nil
        for monitor in monitors {
            monitor.source.cancel()
        }
        monitors.removeAll()
        onActivityChange = nil
        onApprovalChange = nil
        running = false
    }

    private func startMonitor(for target: WatchTarget) {
        guard FileManager.default.fileExists(atPath: target.url.path) else {
            return
        }

        let fileDescriptor = open(target.url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: target.eventMask,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleEvent(target)
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        monitors.append(Monitor(fileDescriptor: fileDescriptor, source: source))
    }

    private func handleEvent(_ target: WatchTarget) {
        if target.triggersActivity {
            scheduleActivityRefresh()
        }
        if target.triggersApproval {
            scheduleApprovalRefresh()
        }
    }

    private func scheduleActivityRefresh() {
        pendingActivityRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onActivityChange?()
        }
        pendingActivityRefresh = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func scheduleApprovalRefresh() {
        pendingApprovalRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onApprovalChange?()
        }
        pendingApprovalRefresh = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private static func watchTargets() -> [WatchTarget] {
        let codexSessions = FilePaths.codexHome.appendingPathComponent("sessions", isDirectory: true)
        let codexHistory = FilePaths.codexHome.appendingPathComponent("history.jsonl", isDirectory: false)
        let codexShellSnapshots = FilePaths.codexHome.appendingPathComponent("shell_snapshots", isDirectory: true)
        let claudeQuestions = FilePaths.hermitFlowHome.appendingPathComponent("claude-questions", isDirectory: true)
        let claudeLatestQuestion = claudeQuestions.appendingPathComponent("latest-question.json", isDirectory: false)

        return [
            WatchTarget(url: codexSessions, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: true),
            WatchTarget(url: codexHistory, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: false),
            WatchTarget(url: codexShellSnapshots, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: false),
            WatchTarget(url: FilePaths.claudeStatusLineDebug, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: false),
            WatchTarget(url: claudeQuestions, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: true),
            WatchTarget(url: claudeLatestQuestion, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: true),
            WatchTarget(url: FilePaths.openCodeDataDirectory, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: true),
            WatchTarget(url: FilePaths.openCodeDatabase, eventMask: [.write, .rename, .delete, .extend], triggersActivity: true, triggersApproval: true)
        ]
    }
}

struct UsageRefreshPolicy: Equatable {
    let minimumInterval: TimeInterval
    let failureBackoffInterval: TimeInterval

    init(
        minimumInterval: TimeInterval,
        failureBackoffInterval: TimeInterval = 5 * 60
    ) {
        self.minimumInterval = minimumInterval
        self.failureBackoffInterval = failureBackoffInterval
    }

    func shouldRefresh(
        lastRefreshAt: Date?,
        backoffUntil: Date?,
        force: Bool = false,
        now: Date = .now
    ) -> Bool {
        if let backoffUntil, now < backoffUntil {
            return false
        }

        if force {
            return true
        }

        guard let lastRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshAt) >= minimumInterval
    }

    func backoffUntil(snapshotWasMissing: Bool, now: Date = .now) -> Date? {
        snapshotWasMissing ? now.addingTimeInterval(failureBackoffInterval) : nil
    }
}

private enum UsageRefreshProvider {
    case claude
    case codex
    case openCode
}

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

    var openCodeUsageSnapshot: OpenCodeUsageSnapshot? {
        usageProviderState.openCode
    }

    private let accessibilityPermissionPollInterval: TimeInterval = 1.0
    private let claudeUsageRefreshMinimumInterval: TimeInterval = 60.0
    private let codexUsageRefreshMinimumInterval: TimeInterval = 120.0
    private let openCodeUsageRefreshMinimumInterval: TimeInterval = 120.0
    private let usageFailureBackoffInterval: TimeInterval = 5 * 60
    private let accessibilityPromptDismissedDefaultsKey = "HermitFlow.accessibilityPromptDismissed"
    private let aggregateSuccessFlashDuration: TimeInterval = 1.25
    private let aggregateFailureFlashDuration: TimeInterval = 2.0

    private var timer: Timer?
    private var approvalTimer: Timer?
    private var accessibilityTimer: Timer?
    private var localCodexRefreshInFlight = false
    private var localCodexRefreshPending = false
    private var localApprovalRefreshInFlight = false
    private var localApprovalRefreshPending = false
    private var usageRefreshInFlight = false
    private var codexRealtimeSourceStarted = false
    private var localHookRefreshDebounceTask: Task<Void, Never>?
    private var lastFileModificationDate: Date?
    private var lastClaudeUsageRefreshAt: Date?
    private var lastCodexUsageRefreshAt: Date?
    private var lastOpenCodeUsageRefreshAt: Date?
    private var claudeUsageBackoffUntil: Date?
    private var codexUsageBackoffUntil: Date?
    private var openCodeUsageBackoffUntil: Date?
    private var lastRuntimeChangeAt: Date?
    private var lastApprovalChangeAt: Date?
    private let pollingBackoffPolicy = PollingBackoffPolicy()
    private var localCodexRefreshCount = 0
    private var localApprovalRefreshCount = 0
    private var usageRefreshCount = 0
    private var claudeUsageFetchCount = 0
    private var codexUsageFetchCount = 0
    private var openCodeUsageFetchCount = 0
    private var lastPerformanceLogAt = Date()
    private var reducer = RuntimeReducer()
    private var reducerState = RuntimeReducer.State()
    private var aggregateStatusOverride: AggregateStatusOverride?
    private var aggregateStatusOverrideTask: Task<Void, Never>?
    private var lastAppliedActivitySignature: String?

    // TODO: Remove these legacy dependencies once reducer migration is complete.
    let sessionStore: SessionStore
    let approvalStore: ApprovalStore
    let focusRouter: FocusRouter
    let focusLauncher: FocusLauncher
    let notificationSoundPlayer: NotificationSoundPlayer
    let accessibilityPermissionMonitor: AccessibilityPermissionMonitor
    let localCodexSource: LocalCodexSource
    let localClaudeSource: LocalClaudeSource
    let localOpenCodeSource: LocalOpenCodeSource
    let claudeUsageSource: ClaudeUsageSource
    let codexUsageSource: CodexRolloutUsageSource
    let openCodeUsageSource: OpenCodeUsageSource
    let claudeHookInstaller: ClaudeHookInstaller
    let claudeHookHealthChecker: ClaudeHookHealthChecker
    let claudeHookBootstrap: ClaudeHookBootstrap
    let claudeHTTPCallbackServer: ClaudeHTTPCallbackServer
    let openCodeHookInstaller: OpenCodeHookInstaller
    let codexHookSource: CodexHookSource
    let localSourceFileWatcher: LocalSourceFileWatcher
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
    let openCodeApprovalExecutor: OpenCodeApprovalExecutor

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
        localOpenCodeSource: LocalOpenCodeSource = LocalOpenCodeSource(),
        claudeUsageSource: ClaudeUsageSource = ClaudeUsageSource(),
        codexUsageSource: CodexRolloutUsageSource = CodexRolloutUsageSource(),
        openCodeUsageSource: OpenCodeUsageSource = OpenCodeUsageSource(),
        claudeHookInstaller: ClaudeHookInstaller? = nil,
        claudeHookHealthChecker: ClaudeHookHealthChecker? = nil,
        claudeHookBootstrap: ClaudeHookBootstrap? = nil,
        claudeHTTPCallbackServer: ClaudeHTTPCallbackServer? = nil,
        openCodeHookInstaller: OpenCodeHookInstaller = OpenCodeHookInstaller(),
        codexHookSource: CodexHookSource? = nil,
        localSourceFileWatcher: LocalSourceFileWatcher = LocalSourceFileWatcher(),
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
        openCodeApprovalExecutor: OpenCodeApprovalExecutor? = nil,
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
        self.localOpenCodeSource = localOpenCodeSource
        self.claudeUsageSource = claudeUsageSource
        self.codexUsageSource = codexUsageSource
        self.openCodeUsageSource = openCodeUsageSource
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
        self.openCodeHookInstaller = openCodeHookInstaller
        self.codexHookSource = codexHookSource ?? CodexHookSource(source: localCodexSource, sessionReader: codexSessionReader)
        self.localSourceFileWatcher = localSourceFileWatcher
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
        self.openCodeApprovalExecutor = openCodeApprovalExecutor ?? OpenCodeApprovalExecutor()
        accessibilityPromptDismissed = UserDefaults.standard.bool(forKey: accessibilityPromptDismissedDefaultsKey)
    }

    func handleLaunch() {
        let claudeReport = claudeHookBootstrap.bootstrap()
        localOpenCodeSource.startCallbackServer()
        do {
            try openCodeHookInstaller.resync()
        } catch {
            dispatch(.runtimeErrorUpdated("OpenCode hook setup failed"))
        }
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
        dispatch([event])
    }

    func dispatch(_ events: [IslandEvent]) {
        let aggregateOverride = aggregateStatusOverrideCandidate(for: events)
        reducer.apply(events, to: &reducerState)
        if let aggregateOverride {
            applyAggregateStatusOverride(aggregateOverride)
        }
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
        timer?.invalidate()
        approvalTimer?.invalidate()
        codexHookSource.stop()
        codexRealtimeSourceStarted = false
        sourceMode = .localCodex
        externalFilePath = nil
        lastFileModificationDate = nil
        localCodexRefreshPending = false
        localApprovalRefreshPending = false
        lastRuntimeChangeAt = .now
        lastApprovalChangeAt = .now
        lastAppliedActivitySignature = nil
        dispatch([
            .diagnosticUpdated(DiagnosticsEvent(approvalDiagnosticMessage: nil)),
            .runtimeStatusMessageUpdated("Loading local Codex activity")
        ])
        refreshUsageIfNeeded(force: true)
        startLocalHookRefreshCallbacks()
        startLocalSourceFileWatcher()
        refreshSourceHealthReports()
        refreshLocalCodexStatus()
        refreshLocalApprovalStatus()
        scheduleNextLocalCodexPoll()
        scheduleNextApprovalPoll()
    }

    func startDemoMode() {
        codexHookSource.stop()
        codexRealtimeSourceStarted = false
        localSourceFileWatcher.stop()
        stopLocalHookRefreshCallbacks()
        stopApprovalTimer()
        sourceMode = .demo
        externalFilePath = nil
        lastFileModificationDate = nil
        lastAppliedActivitySignature = nil
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
        localSourceFileWatcher.stop()
        stopLocalHookRefreshCallbacks()
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
            localCodexRefreshPending = true
            return
        }

        localCodexRefreshInFlight = true
        localCodexRefreshCount += 1
        logPerformanceCountersIfNeeded()
        let source = localCodexSource
        let claudeSource = localClaudeSource
        let openCodeSource = localOpenCodeSource
        localCodexQueue.async { [weak self] in
            let codexSnapshot = source.fetchActivity()
            let claudeSnapshot = claudeSource.fetchActivity()
            let openCodeSnapshot = openCodeSource.fetchActivity()
            let snapshot = ActivitySnapshotMerger.merge(
                ActivitySnapshotMerger.merge(codexSnapshot, claudeSnapshot),
                openCodeSnapshot
            )

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.localCodexRefreshInFlight = false
                guard case .localCodex = self.sourceMode else {
                    return
                }

                if self.shouldApply(activitySnapshot: snapshot) {
                    self.apply(activitySnapshot: snapshot)
                }
                if self.localCodexRefreshPending {
                    self.localCodexRefreshPending = false
                    self.refreshLocalCodexStatus()
                } else {
                    self.scheduleNextLocalCodexPoll()
                }
            }
        }
    }

    func refreshLocalApprovalStatus() {
        guard !localApprovalRefreshInFlight else {
            localApprovalRefreshPending = true
            return
        }

        localApprovalRefreshInFlight = true
        localApprovalRefreshCount += 1
        logPerformanceCountersIfNeeded()
        let source = localCodexSource
        let claudeSource = localClaudeSource
        let openCodeSource = localOpenCodeSource
        localApprovalQueue.async { [weak self] in
            let codexApprovalProbe = source.fetchApprovalProbeResult()
            let claudeApprovalRequest = claudeSource.fetchLatestApprovalRequest()
            let openCodeApprovalRequest = openCodeSource.fetchLatestApprovalRequest()
            let approvalRequest = ApprovalRequestMerger.merge(
                ApprovalRequestMerger.merge(
                    codexApprovalProbe.pendingRequest,
                    claudeApprovalRequest
                ),
                openCodeApprovalRequest
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
                if self.localApprovalRefreshPending {
                    self.localApprovalRefreshPending = false
                    self.refreshLocalApprovalStatus()
                } else {
                    self.scheduleNextApprovalPoll()
                }
            }
        }
    }

    func refreshClaudeUsage() {
        refreshUsageIfNeeded(force: true, includeCodex: false, includeOpenCode: false)
    }

    func refreshCodexUsage() {
        refreshUsageIfNeeded(force: true, includeClaude: false, includeOpenCode: false)
    }

    func refreshOpenCodeUsage() {
        refreshUsageIfNeeded(force: true, includeClaude: false, includeCodex: false)
    }

    func refreshUsage() {
        refreshUsageIfNeeded(force: true)
    }

    func apply(activitySnapshot: ActivitySourceSnapshot) {
        let knownSessionIDs = Set(reducerState.sessionState.sessionsByID.keys)
        let events = ActivitySnapshotEventAdapter.events(from: activitySnapshot, knownSessionIDs: knownSessionIDs)
        dispatch(events)
    }

    private func shouldApply(activitySnapshot: ActivitySourceSnapshot) -> Bool {
        let signature = semanticSignature(for: activitySnapshot)
        guard signature != lastAppliedActivitySignature else {
            return false
        }
        lastAppliedActivitySignature = signature
        return true
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
        let previousSessionFingerprint = sessionFingerprint(sessions)

        let liveApprovalRequest = reducerState.approvalRequest
        let previewApprovalRequest = reducerState.approvalState.previewRequest
        let resolvedApprovalRequest = previewApprovalRequest
            ?? liveApprovalRequest
            ?? preservedCodexApprovalRequest(from: previousApprovalRequest)
        let shouldForceRunningStatus = resolvedApprovalRequest != nil
            && reducerState.approvalState.collapsedRequestID != resolvedApprovalRequest?.id
        let resolvedCodexStatus: CodexActivityState =
            activeAggregateStatusOverride(now: .now)
            ?? (shouldForceRunningStatus ? .running : reducerState.codexStatus)
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

        if previousCodexStatus != codexStatus || previousSessionFingerprint != sessionFingerprint(sessions) {
            lastRuntimeChangeAt = .now
        }
        if previousApprovalRequestID != approvalRequest?.id {
            lastApprovalChangeAt = .now
        }

        presentationStore?.syncRuntimeContext(
            approvalRequest: resolvedApprovalRequest,
            sessions: reducerState.sessions,
            usageCardCount: reducerState.usageProviderState.usageCardCount
        )

        let shouldPlayApprovalSound = reducerState.approvalState.previewRequest == nil
            && resolvedApprovalRequest?.id != nil
            && resolvedApprovalRequest?.id != previousApprovalRequestID
        let shouldPlaySuccessSound = previousCodexStatus != .success && resolvedCodexStatus == .success

        if presentationStore?.isSoundMuted != true {
            if shouldPlayApprovalSound {
                notificationSoundPlayer.playApprovalSound()
            }

            if shouldPlaySuccessSound {
                notificationSoundPlayer.playCompletionSound()
            }
        }

        if previousWindowSize != presentationStore?.windowSize {
            presentationStore?.onWindowSizeChange?(presentationStore?.windowSize ?? .zero)
        }
    }

    private func sessionFingerprint(_ sessions: [AgentSessionSnapshot]) -> String {
        sessions
            .map { "\($0.id):\($0.activityState.rawValue):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
    }

    private func semanticSignature(for snapshot: ActivitySourceSnapshot) -> String {
        let sessionSignature = snapshot.sessions
            .map { session in
                [
                    session.id,
                    session.origin.rawValue,
                    session.activityState.rawValue,
                    session.runningDetail?.rawValue ?? "",
                    String(session.updatedAt.timeIntervalSince1970),
                    session.cwd ?? "",
                    session.focusTarget?.clientOrigin.rawValue ?? "",
                    session.focusTarget?.terminalClient?.rawValue ?? ""
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        let usageSignature = snapshot.usageSnapshots
            .map { "\($0.origin.rawValue):\($0.updatedAt.timeIntervalSince1970):\($0.shortWindowRemaining):\($0.longWindowRemaining)" }
            .joined(separator: "|")
        let approvalSignature = snapshot.approvalRequest.map {
            "\($0.id):\($0.commandText):\($0.createdAt.timeIntervalSince1970)"
        } ?? ""

        return [
            sessionSignature,
            snapshot.statusMessage,
            snapshot.errorMessage ?? "",
            approvalSignature,
            usageSignature
        ].joined(separator: "||")
    }

    private func executeApproval(_ decision: ApprovalDecision, request: ApprovalRequest) {
        dispatch(.runtimeErrorUpdated(nil))

        let executorResult: ApprovalExecutionResult
        switch request.resolutionKind {
        case .localHTTPHook:
            executorResult = httpHookApprovalExecutor.execute(decision: decision, request: request)
        case .openCodeServerAPI:
            executorResult = openCodeApprovalExecutor.execute(decision: decision, request: request)
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
        includeCodex: Bool = true,
        includeOpenCode: Bool = true
    ) {
        guard !usageRefreshInFlight else {
            return
        }

        let now = Date()
        let includedProviderCount = [includeClaude, includeCodex, includeOpenCode].filter { $0 }.count
        let shouldHonorForce = force && includedProviderCount == 1
        let shouldFetchClaude = includeClaude && shouldRefreshUsageProvider(
            lastRefreshAt: lastClaudeUsageRefreshAt,
            backoffUntil: claudeUsageBackoffUntil,
            minimumInterval: claudeUsageRefreshMinimumInterval,
            force: shouldHonorForce,
            now: now
        )
        let shouldFetchCodex = includeCodex && shouldRefreshUsageProvider(
            lastRefreshAt: lastCodexUsageRefreshAt,
            backoffUntil: codexUsageBackoffUntil,
            minimumInterval: codexUsageRefreshMinimumInterval,
            force: shouldHonorForce,
            now: now
        )
        let shouldFetchOpenCode = includeOpenCode && shouldRefreshUsageProvider(
            lastRefreshAt: lastOpenCodeUsageRefreshAt,
            backoffUntil: openCodeUsageBackoffUntil,
            minimumInterval: openCodeUsageRefreshMinimumInterval,
            force: shouldHonorForce,
            now: now
        )

        guard shouldFetchClaude || shouldFetchCodex || shouldFetchOpenCode else {
            return
        }

        usageRefreshInFlight = true
        usageRefreshCount += 1
        if shouldFetchClaude {
            claudeUsageFetchCount += 1
        }
        if shouldFetchCodex {
            codexUsageFetchCount += 1
        }
        if shouldFetchOpenCode {
            openCodeUsageFetchCount += 1
        }
        logPerformanceCountersIfNeeded()
        let existingState = reducerState.usageProviderState
        let claudeUsageSource = self.claudeUsageSource
        let codexUsageSource = self.codexUsageSource
        let openCodeUsageSource = self.openCodeUsageSource

        usageQueue.async { [weak self] in
            let claudeSnapshot = shouldFetchClaude ? claudeUsageSource.fetchUsageSnapshot() : existingState.claude
            let codexSnapshot = shouldFetchCodex ? codexUsageSource.fetchUsageSnapshot() : existingState.codex
            let openCodeSnapshot = shouldFetchOpenCode ? openCodeUsageSource.fetchUsageSnapshot() : existingState.openCode
            let providerState = UsageProviderState(
                claude: claudeSnapshot,
                codex: codexSnapshot,
                openCode: openCodeSnapshot
            )

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.usageRefreshInFlight = false
                let completedAt = Date()
                self.updateUsageRefreshState(
                    didFetch: shouldFetchClaude,
                    snapshot: claudeSnapshot,
                    provider: .claude,
                    now: completedAt
                )
                self.updateUsageRefreshState(
                    didFetch: shouldFetchCodex,
                    snapshot: codexSnapshot,
                    provider: .codex,
                    now: completedAt
                )
                self.updateUsageRefreshState(
                    didFetch: shouldFetchOpenCode,
                    snapshot: openCodeSnapshot,
                    provider: .openCode,
                    now: completedAt
                )
                self.dispatch(.usageProviderStateUpdated(providerState))
            }
        }
    }

    private func shouldRefreshUsageProvider(
        lastRefreshAt: Date?,
        backoffUntil: Date?,
        minimumInterval: TimeInterval,
        force: Bool,
        now: Date
    ) -> Bool {
        UsageRefreshPolicy(
            minimumInterval: minimumInterval,
            failureBackoffInterval: usageFailureBackoffInterval
        ).shouldRefresh(
            lastRefreshAt: lastRefreshAt,
            backoffUntil: backoffUntil,
            force: force,
            now: now
        )
    }

    private func updateUsageRefreshState<Snapshot>(
        didFetch: Bool,
        snapshot: Snapshot?,
        provider: UsageRefreshProvider,
        now: Date
    ) {
        guard didFetch else {
            return
        }

        let failureBackoffUntil = UsageRefreshPolicy(
            minimumInterval: 0,
            failureBackoffInterval: usageFailureBackoffInterval
        ).backoffUntil(snapshotWasMissing: snapshot == nil, now: now)
        switch provider {
        case .claude:
            lastClaudeUsageRefreshAt = now
            claudeUsageBackoffUntil = failureBackoffUntil
        case .codex:
            lastCodexUsageRefreshAt = now
            codexUsageBackoffUntil = failureBackoffUntil
        case .openCode:
            lastOpenCodeUsageRefreshAt = now
            openCodeUsageBackoffUntil = failureBackoffUntil
        }
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

    private func startLocalSourceFileWatcher() {
        localSourceFileWatcher.start(
            onActivityChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, case .localCodex = self.sourceMode else {
                        return
                    }
                    self.refreshLocalCodexStatus()
                }
            },
            onApprovalChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, case .localCodex = self.sourceMode else {
                        return
                    }
                    self.refreshLocalApprovalStatus()
                }
            }
        )
    }

    private func startLocalHookRefreshCallbacks() {
        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleLocalHookRefresh()
            }
        }
        localClaudeSource.setActivityChangeHandler(handler)
        localOpenCodeSource.setActivityChangeHandler(handler)
    }

    private func stopLocalHookRefreshCallbacks() {
        localHookRefreshDebounceTask?.cancel()
        localHookRefreshDebounceTask = nil
        localClaudeSource.setActivityChangeHandler(nil)
        localOpenCodeSource.setActivityChangeHandler(nil)
    }

    private func scheduleLocalHookRefresh() {
        guard case .localCodex = sourceMode else {
            return
        }

        localHookRefreshDebounceTask?.cancel()
        localHookRefreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, case .localCodex = self.sourceMode else {
                return
            }
            self.refreshLocalCodexStatus()
            self.refreshLocalApprovalStatus()
        }
    }

    private func refreshSourceHealthReports(claudeReport: SourceHealthReport? = nil) {
        let effectiveClaudeReport = filteredHealthReport(claudeReport ?? claudeHookHealthChecker.healthReport())
        let openCodeReport = filteredHealthReport(openCodeHookInstaller.healthReport())
        let codexIssues = filteredHealthIssues(
            codexHookSource.healthReport().issues
                + codexSQLiteReader.healthIssues()
                + codexSessionReader.healthIssues()
                + codexLogReader.healthIssues()
        )
        let codexReport = SourceHealthReport(sourceName: "Codex", issues: codexIssues)

        sourceHealthReports = [effectiveClaudeReport, codexReport, openCodeReport].filter(\.hasIssues)
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

    private func scheduleNextLocalCodexPoll() {
        guard case .localCodex = sourceMode else {
            return
        }

        let interval = pollingBackoffPolicy.activityInterval(
            isActive: isRuntimeActive,
            lastChangedAt: lastRuntimeChangeAt
        )
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalCodexStatus()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func scheduleNextApprovalPoll() {
        guard case .localCodex = sourceMode else {
            return
        }

        let interval = pollingBackoffPolicy.approvalInterval(
            isActive: isRuntimeActive,
            hasPendingApproval: approvalRequest != nil,
            lastChangedAt: lastApprovalChangeAt
        )
        approvalTimer?.invalidate()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalApprovalStatus()
            }
        }
        RunLoop.main.add(approvalTimer!, forMode: .common)
    }

    private var isRuntimeActive: Bool {
        codexStatus == .running || sessions.contains { $0.activityState == .running }
    }

    private func logPerformanceCountersIfNeeded(now: Date = .now) {
        guard now.timeIntervalSince(lastPerformanceLogAt) >= 60 else {
            return
        }

        Logger.log(
            "Performance counters/min localRefresh=\(localCodexRefreshCount) approvalRefresh=\(localApprovalRefreshCount) usageRefresh=\(usageRefreshCount) usageFetches=claude:\(claudeUsageFetchCount),codex:\(codexUsageFetchCount),openCode:\(openCodeUsageFetchCount) status=\(codexStatus.rawValue) pendingApproval=\(approvalRequest != nil).",
            category: .store
        )
        localCodexRefreshCount = 0
        localApprovalRefreshCount = 0
        usageRefreshCount = 0
        claudeUsageFetchCount = 0
        codexUsageFetchCount = 0
        openCodeUsageFetchCount = 0
        lastPerformanceLogAt = now
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

    private func stopApprovalTimer() {
        approvalTimer?.invalidate()
        approvalTimer = nil
        localApprovalRefreshInFlight = false
    }

    private func aggregateStatusOverrideCandidate(for events: [IslandEvent]) -> AggregateStatusOverride? {
        guard !events.isEmpty else {
            return nil
        }

        let previousSessions = reducerState.sessionState.sessionsByID
        let explicitCompletedEvents = events.compactMap { event -> SessionEvent? in
            guard case let .sessionCompleted(payload) = event else {
                return nil
            }
            return payload
        }

        if explicitCompletedEvents.contains(where: { $0.activityState == .failure }) {
            return AggregateStatusOverride(
                state: .failure,
                expiresAt: Date().addingTimeInterval(aggregateFailureFlashDuration)
            )
        }

        if explicitCompletedEvents.contains(where: { $0.activityState == .success }) {
            return AggregateStatusOverride(
                state: .success,
                expiresAt: Date().addingTimeInterval(aggregateSuccessFlashDuration)
            )
        }

        let explicitIdleEvents = events.compactMap { event -> SessionEvent? in
            switch event {
            case let .sessionStarted(payload), let .sessionUpdated(payload):
                return payload.activityState == .idle ? payload : nil
            case .sessionCompleted, .sessionsReconciled, .approvalRequested, .approvalResolved,
                 .diagnosticUpdated, .focusTargetUpdated, .runtimeStatusMessageUpdated,
                 .runtimeErrorUpdated, .runtimeLastUpdated, .usageSnapshotsUpdated,
                 .usageProviderStateUpdated:
                return nil
            }
        }

        if explicitIdleEvents.contains(where: { payload in
            guard let previousSession = previousSessions[payload.id],
                  previousSession.activityState == .running,
                  payload.updatedAt >= previousSession.updatedAt else {
                return false
            }

            return true
        }) {
            return AggregateStatusOverride(
                state: .success,
                expiresAt: Date().addingTimeInterval(aggregateSuccessFlashDuration)
            )
        }

        let explicitlyCompletedIDs = Set(explicitCompletedEvents.map(\.id))
        for event in events {
            guard case let .sessionsReconciled(currentSessionIDs, _) = event else {
                continue
            }

            let visibleIDs = Set(currentSessionIDs)
            let removedRunningSession = previousSessions.contains { sessionID, snapshot in
                guard !visibleIDs.contains(sessionID) else {
                    return false
                }

                guard !explicitlyCompletedIDs.contains(sessionID) else {
                    return false
                }

                return snapshot.activityState == .running
            }

            if removedRunningSession {
                return AggregateStatusOverride(
                    state: .success,
                    expiresAt: Date().addingTimeInterval(aggregateSuccessFlashDuration)
                )
            }
        }

        return nil
    }

    private func applyAggregateStatusOverride(_ override: AggregateStatusOverride) {
        aggregateStatusOverride = override
        aggregateStatusOverrideTask?.cancel()

        let expiresAt = override.expiresAt
        aggregateStatusOverrideTask = Task { @MainActor [weak self] in
            let remaining = max(expiresAt.timeIntervalSinceNow, 0)
            guard remaining > 0 else {
                self?.clearAggregateStatusOverrideIfExpired()
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            self?.clearAggregateStatusOverrideIfExpired()
        }
    }

    private func clearAggregateStatusOverrideIfExpired(now: Date = .now) {
        guard let aggregateStatusOverride, aggregateStatusOverride.expiresAt <= now else {
            return
        }

        self.aggregateStatusOverride = nil
        aggregateStatusOverrideTask = nil
        resolvePresentationState()
    }

    private func activeAggregateStatusOverride(now: Date) -> CodexActivityState? {
        guard let aggregateStatusOverride else {
            return nil
        }

        guard aggregateStatusOverride.expiresAt > now else {
            self.aggregateStatusOverride = nil
            aggregateStatusOverrideTask = nil
            return nil
        }

        return aggregateStatusOverride.state
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
            terminalClient: .warp,
            terminalSessionHint: nil,
            workspaceHint: "/Users/fuyue/Documents/New project"
        )

        return ApprovalRequest(
            id: "preview-approval",
            contextTitle: sessions.first?.title ?? "Sample approval request",
            commandSummary: "open -a Calculator",
            commandText: "open -a Calculator",
            rationale: "Preview approval UI in island mode without waiting for a real pending request.",
            focusTarget: previewTarget,
            createdAt: .now,
            source: .generic,
            resolutionKind: .accessibilityAutomation
        )
    }
}

private struct AggregateStatusOverride {
    let state: IslandCodexActivityState
    let expiresAt: Date
}
