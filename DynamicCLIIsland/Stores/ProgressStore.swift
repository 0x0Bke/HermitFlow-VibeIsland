//
//  ProgressStore.swift
//  HermitFlow
//
//  Legacy compatibility facade for the Phase 3 store split.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ProgressStore: ObservableObject {
    typealias BrandLogo = IslandBrandLogo
    typealias SourceMode = IslandSourceMode
    typealias DisplayMode = IslandDisplayMode
    typealias CodexActivityState = IslandCodexActivityState

    let appStore: AppStore

    private var cancellables: Set<AnyCancellable> = []
    private let claudeUsageRefreshInterval: TimeInterval = 10
    private let codexUsageRefreshInterval: TimeInterval = 120
    private let openCodeUsageRefreshInterval: TimeInterval = 120
    private let localQuestionRefreshInterval: TimeInterval = 0.4
    private var usageTimer: Timer?
    private var questionTimer: Timer?
    private var lastClaudeUsageRefreshAt: Date?
    private var lastCodexUsageRefreshAt: Date?
    private var lastOpenCodeUsageRefreshAt: Date?
    private var lastQuestionRefreshAt: Date?
    private let askUserQuestionModeDefaultsKey = "HermitFlow.askUserQuestionHandlingMode"
    private let questionStore = QuestionStore()
    private let claudeQuestionSource = ClaudeQuestionSource()

    var onOpenSettingsPanel: (() -> Void)?

    @Published private(set) var claudeUsageSnapshot: ClaudeUsageSnapshot?
    @Published private(set) var codexUsageSnapshot: CodexUsageSnapshot?
    @Published private(set) var openCodeUsageSnapshot: OpenCodeUsageSnapshot?
    @Published private(set) var questionPrompt: ClaudeQuestionPrompt?
    @Published private(set) var questionErrorMessage: String?
    @Published private(set) var activeQuestionSupportsSubmission = true
    @Published private(set) var askUserQuestionHandlingMode: AskUserQuestionHandlingMode

    init(appStore: AppStore = AppStore()) {
        self.appStore = appStore
        askUserQuestionHandlingMode = AskUserQuestionHandlingMode(
            rawValue: UserDefaults.standard.string(forKey: askUserQuestionModeDefaultsKey) ?? ""
        ) ?? .takeOver
        claudeUsageSnapshot = appStore.claudeUsageSnapshot
        codexUsageSnapshot = appStore.codexUsageSnapshot
        openCodeUsageSnapshot = appStore.openCodeUsageSnapshot

        appStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        appStore.runtimeStore.$usageProviderState
            .sink { [weak self] providerState in
                self?.claudeUsageSnapshot = providerState.claude
                self?.codexUsageSnapshot = providerState.codex
                self?.openCodeUsageSnapshot = providerState.openCode
            }
            .store(in: &cancellables)
    }

    var onWindowSizeChange: ((CGSize) -> Void)? {
        get { appStore.onWindowSizeChange }
        set { appStore.onWindowSizeChange = newValue }
    }

    var tasks: [CLIJob] { appStore.tasks }
    var codexStatus: CodexActivityState { appStore.codexStatus }
    var activeRunningDetail: IslandRunningDetail? { appStore.activeRunningDetail }
    var selectedLogo: BrandLogo { appStore.selectedLogo }
    var customLogoPath: String? { appStore.customLogoPath }
    var sessions: [AgentSessionSnapshot] { appStore.sessions }
    var displayMode: DisplayMode { appStore.displayMode }
    var sourceMode: SourceMode { appStore.sourceMode }
    var externalFilePath: String? { appStore.externalFilePath }
    var statusMessage: String { appStore.statusMessage }
    var lastUpdatedAt: Date { appStore.lastUpdatedAt }
    var errorMessage: String? { appStore.errorMessage }
    var compactHeight: CGFloat { appStore.compactHeight }
    var cameraHousingWidth: CGFloat { appStore.cameraHousingWidth }
    var cameraHousingHeight: CGFloat { appStore.cameraHousingHeight }
    var usesExternalDisplayLayout: Bool { appStore.usesExternalDisplayLayout }
    var focusTarget: FocusTarget? { appStore.focusTarget }
    var approvalRequest: ApprovalRequest? { appStore.approvalRequest }
    var approvalDiagnosticMessage: String? { appStore.approvalDiagnosticMessage }
    var approvalPreviewEnabled: Bool { appStore.approvalPreviewEnabled }
    var approvalDefaultFocus: ApprovalDefaultFocusOption { appStore.approvalDefaultFocus }
    var usageDisplayType: UsageDisplayType { appStore.usageDisplayType }
    var inlineApprovalCommandExpanded: Bool { appStore.inlineApprovalCommandExpanded }
    var collapsedInlineApprovalID: String? { appStore.collapsedInlineApprovalID }
    var accessibilityPermissionGranted: Bool { appStore.accessibilityPermissionGranted }
    var accessibilityPromptDismissed: Bool { appStore.accessibilityPromptDismissed }
    var runningGlyphAnimationSuppressed: Bool { appStore.runningGlyphAnimationSuppressed }
    var isSoundMuted: Bool { appStore.isSoundMuted }
    var customApprovalNotificationSoundPath: String? { appStore.customApprovalNotificationSoundPath }
    var customCompletionNotificationSoundPath: String? { appStore.customCompletionNotificationSoundPath }
    var usageSnapshots: [ProviderUsageSnapshot] { appStore.usageSnapshots }
    var usageProviderState: UsageProviderState { appStore.usageProviderState }
    var hasUsageContent: Bool {
        claudeUsageSnapshot?.isEmpty == false
            || codexUsageSnapshot?.isEmpty == false
            || openCodeUsageSnapshot?.isEmpty == false
    }
    var claudeUsageSummaryText: String? { UsageSummaryFormatter.claudeSummaryText(claudeUsageSnapshot, displayType: usageDisplayType) }
    var codexUsageSummaryText: String? { UsageSummaryFormatter.codexSummaryText(codexUsageSnapshot, displayType: usageDisplayType) }
    var openCodeUsageSummaryText: String? { UsageSummaryFormatter.openCodeSummaryText(openCodeUsageSnapshot, displayType: usageDisplayType) }
    var sourceHealthReports: [SourceHealthReport] { appStore.sourceHealthReports }
    var windowSize: CGSize { appStore.windowSize }
    var cameraGapWidth: CGFloat { appStore.cameraGapWidth }
    var isExpanded: Bool { appStore.isExpanded }
    var isHiddenMode: Bool { appStore.isHiddenMode }
    var hasInlineApprovalIsland: Bool { appStore.hasInlineApprovalIsland }
    var hasInlineQuestionIsland: Bool { appStore.hasInlineQuestionIsland }
    var panelTransition: PresentationStore.PanelTransitionConfiguration { appStore.panelTransition }
    var windowResizeAnimation: PresentationStore.WindowResizeAnimation { appStore.windowResizeAnimation }
    var modeName: String { appStore.modeName }
    var focusTargetLabel: String? { appStore.focusTargetLabel }
    var accessibilityPermissionMessage: String? { appStore.accessibilityPermissionMessage }
    var panelTitle: String {
        if let prompt = activeQuestionPrompt {
            return prompt.source == .openCode ? "OpenCode Needs Input" : "Claude Needs Input"
        }
        return appStore.panelTitle
    }
    var panelSubtitle: String {
        if let prompt = activeQuestionPrompt {
            let fallback = prompt.source == .openCode
                ? "OpenCode is waiting for your answer"
                : "Claude is waiting for your answer"
            return prompt.title.isEmpty ? (prompt.message ?? fallback) : prompt.title
        }
        return appStore.panelSubtitle
    }
    var hasPanelContent: Bool { appStore.hasPanelContent || hasQuestionPrompt }
    var activeTask: CLIJob? { appStore.activeTask }
    var completedCount: Int { appStore.completedCount }
    var runningCount: Int { appStore.runningCount }
    var sourceLabel: String { appStore.sourceLabel }
    var questionInputStore: QuestionStore { questionStore }
    var hasQuestionPrompt: Bool { activeQuestionPrompt != nil }
    var activeQuestionPrompt: ClaudeQuestionPrompt? {
        guard let questionPrompt, !questionPrompt.isExpired else {
            return nil
        }
        return questionPrompt
    }
    var questionPresentationMode: QuestionPresentationMode { .inlineIsland }

    func handleLaunch() {
        appStore.handleLaunch()
        refreshUsageState()
        startUsageMonitoringIfNeeded()
        refreshLocalQuestionStatus()
        startQuestionMonitoringIfNeeded()
    }

    func handleAppDidBecomeActive() {
        appStore.handleAppDidBecomeActive()
        refreshUsageState()
        startUsageMonitoringIfNeeded()
        refreshLocalQuestionStatus()
        startQuestionMonitoringIfNeeded()
    }

    func handlePrimaryTap() {
        if hasInlineQuestionIsland, displayMode == .island, questionPresentationMode == .inlineIsland {
            return
        }
        appStore.handlePrimaryTap()
    }

    func handleSecondaryTap() {
        appStore.handleSecondaryTap()
    }

    func showIsland() {
        appStore.showIsland()
    }

    func showPanel() {
        appStore.showPanel()
    }

    func collapsePanel() {
        appStore.collapsePanel()
    }

    func showHidden() {
        appStore.showHidden()
    }

    func handlePanelHover(_ isHovering: Bool) {
        appStore.handlePanelHover(isHovering)
    }

    func armPanelHoverMonitoring() {
        appStore.armPanelHoverMonitoring()
    }

    func suppressPanelAutoCollapse(for duration: TimeInterval) {
        appStore.suppressPanelAutoCollapse(for: duration)
    }

    func quitApp() {
        appStore.quitApp()
    }

    func selectLogo(_ logo: BrandLogo) {
        appStore.selectLogo(logo)
    }

    func setCustomLogoPath(_ path: String?) {
        appStore.setCustomLogoPath(path)
    }

    func clearCustomLogo() {
        appStore.clearCustomLogo()
    }

    func toggleSoundMuted() {
        appStore.toggleSoundMuted()
    }

    func setCustomNotificationSoundPath(_ path: String?, for kind: NotificationSoundKind) {
        appStore.setCustomNotificationSoundPath(path, for: kind)
    }

    func setApprovalDefaultFocus(_ option: ApprovalDefaultFocusOption) {
        appStore.setApprovalDefaultFocus(option)
    }

    func setUsageDisplayType(_ type: UsageDisplayType) {
        appStore.setUsageDisplayType(type)
    }

    func setAskUserQuestionHandlingMode(_ mode: AskUserQuestionHandlingMode) {
        guard askUserQuestionHandlingMode != mode else {
            return
        }

        askUserQuestionHandlingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: askUserQuestionModeDefaultsKey)
        appStore.resyncClaudeHooks()
        refreshLocalQuestionStatus()
    }

    func updateInlineApprovalCommandExpanded(_ expanded: Bool) {
        appStore.updateInlineApprovalCommandExpanded(expanded)
    }

    func openSettingsPanel() {
        onOpenSettingsPanel?()
    }

    func bringForward(_ target: FocusTarget?) {
        appStore.bringForward(target)
    }

    func openAccessibilitySettings() {
        appStore.openAccessibilitySettings()
    }

    func resyncClaudeHooks() {
        appStore.resyncClaudeHooks()
    }

    func dismissAccessibilityPrompt() {
        appStore.dismissAccessibilityPrompt()
    }

    func rejectApproval() {
        appStore.rejectApproval()
    }

    func acceptApproval() {
        appStore.acceptApproval()
    }

    func acceptAllApprovals() {
        appStore.acceptAllApprovals()
    }

    func collapseInlineApproval() {
        appStore.collapseInlineApproval()
    }

    func toggleApprovalPreview() {
        appStore.toggleApprovalPreview()
    }

    func updateCompactHeight(_ height: CGFloat) {
        appStore.updateCompactHeight(height)
    }

    func syncCameraHousingMetrics(width: CGFloat, height: CGFloat) {
        appStore.syncCameraHousingMetrics(width: width, height: height)
    }

    func updateDisplayLayout(isExternal: Bool, screenWidth: CGFloat) {
        appStore.updateDisplayLayout(isExternal: isExternal, screenWidth: screenWidth)
    }

    func updateCameraHousingWidth(_ width: CGFloat) {
        appStore.updateCameraHousingWidth(width)
    }

    func updateCameraHousingHeight(_ height: CGFloat) {
        appStore.updateCameraHousingHeight(height)
    }

    func submitQuestionAnswer() {
        performQuestionSubmit()
    }

    func dismissQuestionPrompt() {
        guard let prompt = activeQuestionPrompt else {
            questionErrorMessage = nil
            questionPrompt = nil
            questionStore.clear()
            syncQuestionPresentation()
            return
        }

        let dismissed = claudeQuestionSource.dismissQuestion(id: prompt.id)
        if dismissed {
            questionErrorMessage = nil
            questionPrompt = nil
            questionStore.clear()
            syncQuestionPresentation()
            appStore.dispatch(.runtimeStatusMessageUpdated(questionStatusMessage(for: prompt, action: "cancelled")))
            return
        }

        questionErrorMessage = "Unable to cancel question"
        questionStore.setErrorMessage(questionErrorMessage)
    }

    func startLocalCodexMonitoring() {
        appStore.startLocalCodexMonitoring()
    }

    func startDemoMode() {
        appStore.startDemoMode()
    }

    func refreshClaudeUsage() {
        appStore.refreshClaudeUsage()
    }

    func refreshCodexUsage() {
        appStore.refreshCodexUsage()
    }

    func refreshOpenCodeUsage() {
        appStore.refreshOpenCodeUsage()
    }

    func refreshClaudeUsageState() {
        appStore.refreshClaudeUsage()
        lastClaudeUsageRefreshAt = .now
    }

    func refreshCodexUsageState() {
        appStore.refreshCodexUsage()
        lastCodexUsageRefreshAt = .now
    }

    func refreshOpenCodeUsageState() {
        appStore.refreshOpenCodeUsage()
        lastOpenCodeUsageRefreshAt = .now
    }

    func refreshUsageState() {
        appStore.refreshUsage()
        let now = Date()
        lastClaudeUsageRefreshAt = now
        lastCodexUsageRefreshAt = now
        lastOpenCodeUsageRefreshAt = now
    }

    func refreshLocalQuestionStatus() {
        let latestPrompt = claudeQuestionSource.fetchLatestQuestionPrompt()
        let supportsSubmission = latestPrompt.map { claudeQuestionSource.isPromptSubmittable(id: $0.id) } ?? true
        let previousPrompt = questionPrompt
        let previousPromptID = previousPrompt?.id
        let previousSupportsSubmission = activeQuestionSupportsSubmission

        if latestPrompt?.isExpired == true {
            let didHaveQuestion = questionPrompt != nil || !questionStore.textAnswer.isEmpty
            if questionPrompt != nil {
                questionPrompt = nil
            }
            questionStore.clear()
            if activeQuestionSupportsSubmission != true {
                activeQuestionSupportsSubmission = true
            }
            questionErrorMessage = "Question prompt expired"
            if didHaveQuestion || previousSupportsSubmission != true {
                syncQuestionPresentation()
            }
            return
        }

        let promptChanged = previousPrompt != latestPrompt
        let supportsSubmissionChanged = previousSupportsSubmission != supportsSubmission

        if promptChanged {
            questionPrompt = latestPrompt
        }
        if supportsSubmissionChanged {
            activeQuestionSupportsSubmission = supportsSubmission
        }
        if promptChanged || supportsSubmissionChanged {
            questionStore.update(with: latestPrompt, supportsSubmission: supportsSubmission)
            syncQuestionPresentation()
        }

        guard let latestPrompt else {
            if previousPromptID != nil {
                questionErrorMessage = nil
            }
            activeQuestionSupportsSubmission = true
            return
        }

        questionErrorMessage = nil
        if previousPromptID != latestPrompt.id {
            switch questionPresentationMode {
            case .inlineIsland:
                appStore.showIsland()
            case .panel:
                appStore.showPanel()
            }
        }
    }

    func startUsageMonitoringIfNeeded() {
        guard usageTimer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: claudeUsageRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUsageTimerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    func startQuestionMonitoringIfNeeded() {
        guard questionTimer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: localQuestionRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshQuestionTimerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        questionTimer = timer
    }

    func stopUsageMonitoring() {
        usageTimer?.invalidate()
        usageTimer = nil
    }

    func stopQuestionMonitoring() {
        questionTimer?.invalidate()
        questionTimer = nil
    }

    func chooseProgressFile() {
        appStore.chooseProgressFile()
    }

    func attachProgressFile(_ url: URL) {
        appStore.attachProgressFile(url)
    }

    private func refreshUsageTimerTick(now: Date = .now) {
        if shouldRefreshClaudeUsage(now: now)
            || shouldRefreshCodexUsage(now: now)
            || shouldRefreshOpenCodeUsage(now: now) {
            refreshUsageState()
        }
    }

    private func refreshQuestionTimerTick(now: Date = .now) {
        if shouldRefreshQuestion(now: now) {
            refreshLocalQuestionStatus()
            lastQuestionRefreshAt = now
        }
    }

    private func shouldRefreshClaudeUsage(now: Date) -> Bool {
        guard let lastClaudeUsageRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastClaudeUsageRefreshAt) >= claudeUsageRefreshInterval
    }

    private func shouldRefreshCodexUsage(now: Date) -> Bool {
        guard let lastCodexUsageRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastCodexUsageRefreshAt) >= codexUsageRefreshInterval
    }

    private func shouldRefreshOpenCodeUsage(now: Date) -> Bool {
        guard let lastOpenCodeUsageRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastOpenCodeUsageRefreshAt) >= openCodeUsageRefreshInterval
    }

    private func shouldRefreshQuestion(now: Date) -> Bool {
        guard let lastQuestionRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastQuestionRefreshAt) >= localQuestionRefreshInterval
    }

    private func performQuestionSubmit() {
        guard let prompt = activeQuestionPrompt else {
            questionErrorMessage = "Question prompt expired"
            questionStore.setErrorMessage(questionErrorMessage)
            return
        }

        guard let response = questionStore.makeResponse() else {
            questionErrorMessage = questionStore.errorMessage
            return
        }

        questionStore.setSubmitting(true)
        let resolved = claudeQuestionSource.resolveQuestion(id: prompt.id, response: response)
        questionStore.setSubmitting(false)

        guard resolved else {
            let latestPrompt = claudeQuestionSource.fetchLatestQuestionPrompt()
            if latestPrompt == nil || latestPrompt?.id != prompt.id {
                questionPrompt = nil
                questionStore.clear()
                questionErrorMessage = "Question prompt expired"
                syncQuestionPresentation()
                return
            }

            questionErrorMessage = "Unable to send answer to Claude"
            questionStore.setErrorMessage(questionErrorMessage)
            return
        }

        questionErrorMessage = nil
        questionPrompt = nil
        questionStore.clear()
        syncQuestionPresentation()
        appStore.dispatch(.runtimeStatusMessageUpdated(questionStatusMessage(for: prompt, action: "received your answer")))
    }

    private func questionStatusMessage(for prompt: ClaudeQuestionPrompt, action: String) -> String {
        let source = prompt.source == .openCode ? "OpenCode" : "Claude Code"
        return "\(source) \(action)"
    }

    private func syncQuestionPresentation() {
        let previousWindowSize = appStore.windowSize
        appStore.syncQuestionPrompt(activeQuestionPrompt)
        if appStore.displayMode != .panel, previousWindowSize != appStore.windowSize {
            appStore.onWindowSizeChange?(appStore.windowSize)
        }
    }
}
