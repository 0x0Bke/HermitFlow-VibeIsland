import AppKit
import Foundation
import SwiftUI

@MainActor
final class ProgressStore: ObservableObject {
    typealias BrandLogo = IslandBrandLogo
    typealias SourceMode = IslandSourceMode
    typealias DisplayMode = IslandDisplayMode
    typealias CodexActivityState = IslandCodexActivityState

    @Published var tasks: [CLIJob] = []
    @Published private(set) var codexStatus: CodexActivityState = .idle
    @Published private(set) var selectedLogo: BrandLogo
    @Published private(set) var sessions: [AgentSessionSnapshot] = []
    @Published private(set) var displayMode: DisplayMode = .island {
        didSet {
            onWindowSizeChange?(windowSize)
        }
    }
    @Published var sourceMode: SourceMode = .demo
    @Published var externalFilePath: String?
    @Published var statusMessage = "Waiting for CLI status"
    @Published var lastUpdatedAt = Date()
    @Published var errorMessage: String?
    @Published private(set) var compactHeight: CGFloat = 37
    @Published private(set) var cameraHousingWidth: CGFloat = 0
    @Published private(set) var cameraHousingHeight: CGFloat = 37
    @Published private(set) var usesExternalDisplayLayout = false
    @Published private(set) var focusTarget: FocusTarget?
    @Published private(set) var approvalRequest: ApprovalRequest?
    @Published private(set) var approvalDiagnosticMessage: String?
    @Published private(set) var approvalPreviewEnabled = false
    @Published private(set) var collapsedInlineApprovalID: String?
    @Published private(set) var accessibilityPermissionGranted = false
    @Published private(set) var accessibilityPromptDismissed: Bool
    @Published private(set) var runningGlyphAnimationSuppressed = false

    private let compactHeightOverscan: CGFloat = 8
    private let inlineApprovalMinimumHeight: CGFloat = 240
    private let localCodexPollInterval: TimeInterval = 1.0
    private let localApprovalPollInterval: TimeInterval = 0.25
    private let panelHoverActivationDelay: TimeInterval = 0.2
    private let panelCollapseDelayNanoseconds: UInt64 = 180_000_000
    private let accessibilityPermissionPollInterval: TimeInterval = 1.0
    private let externalDisplayCompactWidthMultiplier: CGFloat = 1.6
    private let externalDisplayPanelWidthMultiplier: CGFloat = 1.2

    var onWindowSizeChange: ((CGSize) -> Void)?

    private var timer: Timer?
    private var approvalTimer: Timer?
    private var accessibilityTimer: Timer?
    private var hasHoveredInsidePanelSinceShown = false
    private var panelShownAt = Date.distantPast
    private var panelCollapseTask: Task<Void, Never>?
    private var panelAutoCollapseSuppressedUntil = Date.distantPast
    private var runningGlyphUnsuppressTask: Task<Void, Never>?
    private var localCodexRefreshInFlight = false
    private var localApprovalRefreshInFlight = false
    private var lastFileModificationDate: Date?
    private let logoDefaultsKey = "HermitFlow.selectedLogo"
    private let accessibilityPromptDismissedDefaultsKey = "HermitFlow.accessibilityPromptDismissed"
    private let sessionStore = SessionStore()
    private let approvalStore = ApprovalStore()
    private let focusRouter = FocusRouter()
    private let focusLauncher = FocusLauncher()
    private let accessibilityPermissionMonitor = AccessibilityPermissionMonitor()
    private let localCodexSource = LocalCodexSource()
    private let localClaudeSource = LocalClaudeSource()
    private let localCodexQueue = DispatchQueue(label: "HermitFlow.localCodex", qos: .utility)
    private let localApprovalQueue = DispatchQueue(label: "HermitFlow.localApproval", qos: .userInitiated)
    private let externalProgressSource = ExternalProgressFileSource()
    private let demoProgressSource = DemoProgressSource()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var lastRuntimeState: IslandRuntimeState?

    init() {
        let storedLogo = UserDefaults.standard.string(forKey: logoDefaultsKey)
        selectedLogo = BrandLogo(rawValue: storedLogo ?? "") ?? .clawd
        accessibilityPromptDismissed = UserDefaults.standard.bool(forKey: accessibilityPromptDismissedDefaultsKey)
    }

    var windowSize: CGSize {
        switch displayMode {
        case .panel:
            return CGSize(width: expandedWidth, height: 278)
        case .island:
            return CGSize(width: islandWidth, height: islandHeight)
        case .hidden:
            return CGSize(width: hiddenWidth, height: compactHeight)
        }
    }

    var cameraGapWidth: CGFloat {
        cameraHousingWidth > 0 ? cameraHousingWidth + 28 : 0
    }

    private var isInlineApprovalExpanded: Bool {
        approvalRequest != nil && collapsedInlineApprovalID != approvalRequest?.id
    }

    private var islandWidth: CGFloat {
        let baseWidth: CGFloat
        if isInlineApprovalExpanded {
            baseWidth = max(364, cameraGapWidth + 256)
        } else {
            baseWidth = max(228, cameraGapWidth + 140)
        }

        return scaledWidth(baseWidth, for: .island)
    }

    private var islandHeight: CGFloat {
        if isInlineApprovalExpanded {
            return max(compactHeight, inlineApprovalMinimumHeight)
        }

        return compactHeight
    }

    private var hiddenWidth: CGFloat {
        scaledWidth(max(cameraHousingWidth, 176), for: .hidden)
    }

    private var expandedWidth: CGFloat {
        scaledWidth(max(608, cameraGapWidth + 420), for: .panel)
    }

    var isExpanded: Bool {
        displayMode == .panel
    }

    var isHiddenMode: Bool {
        displayMode == .hidden
    }

    var hasInlineApprovalIsland: Bool {
        displayMode == .island && isInlineApprovalExpanded
    }


    var modeName: String {
        displayMode.rawValue
    }

    var focusTargetLabel: String? {
        focusTarget?.displayName
    }

    var accessibilityPermissionMessage: String? {
        guard !accessibilityPermissionGranted, !accessibilityPromptDismissed else {
            return nil
        }

        return "请在“系统设置 > 隐私与安全性 > 辅助功能”中允许 HermitFlow。"
    }

    var panelTitle: String {
        if approvalRequest != nil {
            return "Approval Needed"
        }

        switch codexStatus {
        case .idle:
            return "Ready"
        case .running:
            return "Working"
        case .success:
            return "Completed"
        case .failure:
            return "Needs Attention"
        }
    }

    var panelSubtitle: String {
        if approvalRequest != nil {
            return "Codex is waiting for your decision"
        }

        return statusMessage
    }

    var hasPanelContent: Bool {
        !sessions.isEmpty || approvalRequest != nil
    }

    var activeTask: CLIJob? {
        tasks.first(where: { $0.stage == .running || $0.stage == .blocked }) ?? tasks.first
    }

    var completedCount: Int {
        tasks.filter { $0.stage == .success }.count
    }

    var runningCount: Int {
        tasks.filter { $0.stage == .running }.count
    }

    var sourceLabel: String {
        switch sourceMode {
        case .localCodex:
            return "Local Codex"
        case .demo:
            return "Demo"
        case .file:
            return "Live JSON"
        }
    }

    func handleLaunch() {
        localClaudeSource.bootstrap()
        refreshAccessibilityPermissionStatus()
        startLocalCodexMonitoring()
    }

    func handleAppDidBecomeActive() {
        refreshAccessibilityPermissionStatus()
    }

    func handlePrimaryTap() {
        switch displayMode {
        case .hidden:
            setDisplayMode(.island)
        case .island:
            setDisplayMode(.panel)
        case .panel:
            break
        }
    }

    func handleSecondaryTap() {
        switch displayMode {
        case .hidden:
            setDisplayMode(.island)
        case .island, .panel:
            setDisplayMode(.hidden)
        }
    }

    func showIsland() {
        setDisplayMode(.island)
    }

    func showPanel() {
        setDisplayMode(.panel)
    }

    func collapsePanel() {
        guard displayMode == .panel else {
            return
        }

        setDisplayMode(.island)
    }

    func showHidden() {
        setDisplayMode(.hidden)
    }

    func handlePanelHover(_ isHovering: Bool) {
        guard displayMode == .panel else {
            return
        }

        if isHovering {
            panelCollapseTask?.cancel()
            panelCollapseTask = nil
            hasHoveredInsidePanelSinceShown = true
        }
    }

    func armPanelHoverMonitoring() {
        guard displayMode == .panel else {
            return
        }

        panelCollapseTask?.cancel()
        panelCollapseTask = nil
        hasHoveredInsidePanelSinceShown = true
    }

    func suppressPanelAutoCollapse(for duration: TimeInterval) {
        guard displayMode == .panel else {
            return
        }

        panelCollapseTask?.cancel()
        panelCollapseTask = nil
        panelAutoCollapseSuppressedUntil = Date().addingTimeInterval(duration)
        hasHoveredInsidePanelSinceShown = true
    }

    private func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else {
            return
        }

        panelCollapseTask?.cancel()
        panelCollapseTask = nil
        hasHoveredInsidePanelSinceShown = false
        if mode == .panel {
            panelShownAt = Date()
        }

        displayMode = mode
    }
    func quitApp() {
        NSApp.terminate(nil)
    }

    func selectLogo(_ logo: BrandLogo) {
        guard selectedLogo != logo else {
            return
        }

        selectedLogo = logo
        UserDefaults.standard.set(logo.rawValue, forKey: logoDefaultsKey)
    }

    func bringForward(_ target: FocusTarget?) {
        guard let target else {
            errorMessage = "No focus target available"
            return
        }

        errorMessage = nil
        statusMessage = "Opening \(target.displayName)"

        guard focusLauncher.bringToFront(target) else {
            errorMessage = "Unable to locate \(target.displayName)"
            return
        }
    }

    func openAccessibilitySettings() {
        errorMessage = nil

        guard focusLauncher.openAccessibilitySettings() else {
            errorMessage = "无法打开辅助功能设置"
            return
        }

        statusMessage = "已打开辅助功能设置"
        beginAccessibilityPermissionPolling()
    }

    func resyncClaudeHooks() {
        statusMessage = "Resyncing Claude hooks"
        localClaudeSource.resyncHooks()
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
            errorMessage = "No approval request available"
            return
        }

        performApproval(.reject, request: request)
    }

    func acceptApproval() {
        guard let request = approvalRequest else {
            errorMessage = "No approval request available"
            return
        }

        performApproval(.accept, request: request)
    }

    func acceptAllApprovals() {
        guard let request = approvalRequest else {
            errorMessage = "No approval request available"
            return
        }

        performApproval(.acceptAll, request: request)
    }

    func collapseInlineApproval() {
        guard let approvalRequest else {
            return
        }

        collapsedInlineApprovalID = approvalRequest.id
        onWindowSizeChange?(windowSize)
    }

    func toggleApprovalPreview() {
        approvalPreviewEnabled.toggle()
        if approvalPreviewEnabled {
            setDisplayMode(.island)
        }
        resolvePresentationState()
    }

    private func performApproval(_ decision: ApprovalDecision, request: ApprovalRequest) {
        collapseApprovalPresentation(for: request)

        if request.resolutionKind == .localHTTPHook {
            errorMessage = nil

            if localClaudeSource.resolveApproval(id: request.id, decision: decision) {
                approvalDiagnosticMessage = nil
                statusMessage = "\(decision.progressMessage)：Claude Code 已收到审批结果"
                approvalStore.clear()
                resolvePresentationState()
            } else {
                errorMessage = "Approval request expired"
            }
            return
        }

        guard let target = request.focusTarget else {
            errorMessage = "No focus target available"
            approvalDiagnosticMessage = "没有可用的目标窗口，无法自动审批。"
            return
        }

        refreshAccessibilityPermissionStatus()
        errorMessage = nil
        if !accessibilityPermissionGranted {
            approvalDiagnosticMessage = "缺少辅助功能权限，已回退为手动处理。"
            statusMessage = "缺少辅助功能权限，正在打开 \(target.displayName) 以手动处理审批"
            guard focusLauncher.bringToFront(target) else {
                errorMessage = "Unable to locate \(target.displayName)"
                return
            }
            return
        }

        statusMessage = "\(decision.progressMessage) in \(target.displayName)"

        let result = focusLauncher.performApproval(decision, for: target)
        if result == .success {
            approvalDiagnosticMessage = nil
            statusMessage = "\(decision.progressMessage) in \(target.displayName)：自动审批成功"
            return
        }

        if result == .routedToWindow {
            approvalDiagnosticMessage = nil
            statusMessage = "已打开 \(target.displayName)，请手动处理审批"
            return
        }

        approvalDiagnosticMessage = result.diagnosticMessage
        statusMessage = "\(result.diagnosticMessage)，正在打开 \(target.displayName) 以手动处理"
        guard focusLauncher.bringToFront(target) else {
            errorMessage = "Unable to locate \(target.displayName)"
            return
        }
    }

    private func collapseApprovalPresentation(for request: ApprovalRequest) {
        collapsedInlineApprovalID = request.id
        approvalDiagnosticMessage = nil
        suppressRunningGlyphAnimation(for: 0.45)

        if displayMode == .panel {
            setDisplayMode(.island)
            return
        }

        if displayMode == .island {
            onWindowSizeChange?(windowSize)
            return
        }

        setDisplayMode(.island)
    }

    private func suppressRunningGlyphAnimation(for duration: TimeInterval) {
        runningGlyphUnsuppressTask?.cancel()
        runningGlyphAnimationSuppressed = true

        runningGlyphUnsuppressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }

            self?.runningGlyphAnimationSuppressed = false
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

    func startLocalCodexMonitoring() {
        sourceMode = .localCodex
        externalFilePath = nil
        lastFileModificationDate = nil
        approvalStore.clear()
        statusMessage = "Loading local Codex activity"
        refreshLocalCodexStatus()
        refreshLocalApprovalStatus()
        restartTimer(interval: localCodexPollInterval) { [weak self] in
            self?.refreshLocalCodexStatus()
        }
        restartApprovalTimer(interval: localApprovalPollInterval) { [weak self] in
            self?.refreshLocalApprovalStatus()
        }
    }

    func updateCompactHeight(_ height: CGFloat) {
        let normalizedHeight = min(max(height.rounded(.up), 28), 64)
        guard abs(compactHeight - normalizedHeight) > 0.5 else {
            return
        }

        compactHeight = normalizedHeight
        guard displayMode != .panel else {
            return
        }

        onWindowSizeChange?(windowSize)
    }

    func syncCameraHousingMetrics(width: CGFloat, height: CGFloat) {
        let normalizedWidth = max(width.rounded(.up), 0)
        let normalizedHousingHeight = min(max(height.rounded(.up), 28), 64)
        let normalizedCompactHeight = min(max((normalizedHousingHeight + compactHeightOverscan).rounded(.up), 28), 64)

        var didChange = false

        if abs(cameraHousingHeight - normalizedHousingHeight) > 0.5 {
            cameraHousingHeight = normalizedHousingHeight
            didChange = true
        }

        if abs(compactHeight - normalizedCompactHeight) > 0.5 {
            compactHeight = normalizedCompactHeight
            didChange = true
        }

        if abs(cameraHousingWidth - normalizedWidth) > 0.5 {
            cameraHousingWidth = normalizedWidth
            didChange = true
        }

        guard didChange, displayMode != .panel else {
            return
        }

        onWindowSizeChange?(windowSize)
    }

    func updateDisplayLayout(isExternal: Bool) {
        guard usesExternalDisplayLayout != isExternal else {
            return
        }

        usesExternalDisplayLayout = isExternal
        onWindowSizeChange?(windowSize)
    }

    private func scaledWidth(_ width: CGFloat, for mode: DisplayMode) -> CGFloat {
        let multiplier: CGFloat
        if usesExternalDisplayLayout {
            switch mode {
            case .panel:
                multiplier = externalDisplayPanelWidthMultiplier
            case .hidden, .island:
                multiplier = externalDisplayCompactWidthMultiplier
            }
        } else {
            multiplier = 1
        }

        return (width * multiplier).rounded(.up)
    }

    func updateCameraHousingWidth(_ width: CGFloat) {
        let normalizedWidth = max(width.rounded(.up), 0)
        guard abs(cameraHousingWidth - normalizedWidth) > 0.5 else {
            return
        }

        cameraHousingWidth = normalizedWidth
        onWindowSizeChange?(windowSize)
    }

    func updateCameraHousingHeight(_ height: CGFloat) {
        let normalizedHeight = min(max(height.rounded(.up), 28), 64)
        guard abs(cameraHousingHeight - normalizedHeight) > 0.5 else {
            return
        }

        cameraHousingHeight = normalizedHeight
        updateCompactHeight(normalizedHeight + compactHeightOverscan)
    }

    func startDemoMode() {
        stopApprovalTimer()
        sourceMode = .demo
        externalFilePath = nil
        lastFileModificationDate = nil
        approvalStore.clear()
        let initialTasks = demoProgressSource.makeInitialTasks()
        let runtimeState = sessionStore.apply(
            progressEnvelope: ProgressEnvelope(generatedAt: .now, tasks: initialTasks),
            sourceLabel: "Watching simulated Claude/Codex tasks",
            errorMessage: nil
        )
        apply(runtimeState)
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
        stopApprovalTimer()
        sourceMode = .file(url)
        externalFilePath = url.path
        approvalStore.clear()
        statusMessage = "Watching \(url.lastPathComponent)"
        loadFromFile(url)
        restartTimer(interval: 1.0) { [weak self] in
            self?.refreshExternalFileIfNeeded()
        }
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
            errorMessage = "Cannot read file metadata"
        }
    }

    private func loadFromFile(_ url: URL) {
        do {
            let envelope = try externalProgressSource.loadEnvelope(from: url, using: decoder)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            lastFileModificationDate = values.contentModificationDate
            let runtimeState = sessionStore.apply(
                progressEnvelope: envelope,
                sourceLabel: "Watching \(url.lastPathComponent)",
                errorMessage: nil
            )
            apply(runtimeState)
        } catch {
            let runtimeState = sessionStore.makeFailureState(
                statusMessage: "Watching \(url.lastPathComponent)",
                errorMessage: "JSON parse failed"
            )
            apply(runtimeState)
        }
    }

    private func advanceDemoTasks() {
        let updated = demoProgressSource.advance(tasks)
        let runtimeState = sessionStore.apply(
            progressEnvelope: ProgressEnvelope(generatedAt: .now, tasks: updated),
            sourceLabel: "Watching simulated Claude/Codex tasks",
            errorMessage: nil
        )
        apply(runtimeState)
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

    private func refreshLocalCodexStatus() {
        guard !localCodexRefreshInFlight else {
            return
        }

        localCodexRefreshInFlight = true
        let source = localCodexSource
        let claudeSource = localClaudeSource
        localCodexQueue.async { [weak self] in
            let codexSnapshot = source.fetchActivity()
            let claudeSnapshot = claudeSource.fetchActivity()
            let snapshot = Self.mergeActivitySnapshots(codexSnapshot, claudeSnapshot)

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.localCodexRefreshInFlight = false
                guard case .localCodex = self.sourceMode else {
                    return
                }

                self.apply(snapshot)
            }
        }
    }

    private func refreshLocalApprovalStatus() {
        guard !localApprovalRefreshInFlight else {
            return
        }

        localApprovalRefreshInFlight = true
        let source = localCodexSource
        let claudeSource = localClaudeSource
        localApprovalQueue.async { [weak self] in
            let approvalRequest = Self.mergeApprovalRequests(
                source.fetchLatestApprovalRequest(),
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

                self.approvalStore.update(with: approvalRequest)
                self.resolvePresentationState()
            }
        }
    }

    private func apply(_ activitySnapshot: ActivitySourceSnapshot) {
        let runtimeState = sessionStore.apply(activitySnapshot: activitySnapshot)
        apply(runtimeState)
    }

    private func apply(_ runtimeState: IslandRuntimeState) {
        lastRuntimeState = runtimeState
        resolvePresentationState()
    }

    private func resolvePresentationState() {
        let previousWindowSize = windowSize
        let runtimeState = lastRuntimeState ?? IslandRuntimeState(
            sessions: [],
            tasks: [],
            codexStatus: .idle,
            statusMessage: "Waiting for CLI status",
            lastUpdatedAt: .now,
            errorMessage: nil,
            approvalRequest: nil
        )
        let previousApprovalRequest = approvalStore.currentRequest

        switch sourceMode {
        case .localCodex:
            // Keep the higher-frequency approval probe alive when the heavier
            // activity snapshot has not yet caught up to a short-lived prompt.
            if let approvalRequest = runtimeState.approvalRequest {
                approvalStore.update(with: approvalRequest)
            } else if let previousApprovalRequest,
                      runtimeState.lastUpdatedAt >= previousApprovalRequest.createdAt,
                      runtimeState.codexStatus != .running {
                approvalStore.clear()
            }
        case .demo, .file:
            approvalStore.update(with: runtimeState.approvalRequest)
        }
        let liveApprovalRequest = approvalStore.currentRequest
        let previewApprovalRequest = approvalPreviewEnabled ? makePreviewApprovalRequest() : nil
        let resolvedApprovalRequest = previewApprovalRequest ?? liveApprovalRequest
        let resolvedCodexStatus: CodexActivityState = resolvedApprovalRequest != nil ? .running : runtimeState.codexStatus
        let resolvedFocusTarget = resolvedApprovalRequest?.focusTarget
            ?? focusRouter.preferredTarget(from: runtimeState.sessions, approvalRequest: liveApprovalRequest)

        if let resolvedApprovalRequest {
            if collapsedInlineApprovalID != resolvedApprovalRequest.id,
               approvalRequest?.id != resolvedApprovalRequest.id {
                collapsedInlineApprovalID = nil
                approvalDiagnosticMessage = nil
            }
        } else {
            collapsedInlineApprovalID = nil
            approvalDiagnosticMessage = nil
        }

        sessions = runtimeState.sessions
        tasks = runtimeState.tasks
        codexStatus = resolvedCodexStatus
        statusMessage = approvalPreviewEnabled ? "Previewing approval UI" : runtimeState.statusMessage
        lastUpdatedAt = runtimeState.lastUpdatedAt
        errorMessage = runtimeState.errorMessage?.isEmpty == true ? nil : runtimeState.errorMessage
        approvalRequest = resolvedApprovalRequest
        focusTarget = resolvedFocusTarget

        if previousWindowSize != windowSize {
            onWindowSizeChange?(windowSize)
        }
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

    nonisolated private static func mergeActivitySnapshots(
        _ lhs: ActivitySourceSnapshot,
        _ rhs: ActivitySourceSnapshot
    ) -> ActivitySourceSnapshot {
        let sessions = (lhs.sessions + rhs.sessions).sorted { left, right in
            if left.activityState != right.activityState {
                return priority(for: left.activityState) > priority(for: right.activityState)
            }
            return left.updatedAt > right.updatedAt
        }

        let statusMessage: String
        if !lhs.sessions.isEmpty, !rhs.sessions.isEmpty {
            statusMessage = "Watching local Codex + Claude Code activity"
        } else if !lhs.sessions.isEmpty {
            statusMessage = lhs.statusMessage
        } else if !rhs.sessions.isEmpty {
            statusMessage = rhs.statusMessage
        } else {
            statusMessage = "Waiting for Codex / Claude activity"
        }

        let lastUpdatedAt = max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
        let approvalRequest = mergeApprovalRequests(lhs.approvalRequest, rhs.approvalRequest)
        let errorMessage = [lhs.errorMessage, rhs.errorMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return ActivitySourceSnapshot(
            sessions: sessions,
            statusMessage: statusMessage,
            lastUpdatedAt: lastUpdatedAt,
            errorMessage: errorMessage.isEmpty ? nil : errorMessage,
            approvalRequest: approvalRequest
        )
    }

    nonisolated private static func mergeApprovalRequests(
        _ lhs: ApprovalRequest?,
        _ rhs: ApprovalRequest?
    ) -> ApprovalRequest? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left.createdAt >= right.createdAt ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    nonisolated private static func priority(for state: IslandCodexActivityState) -> Int {
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
}
