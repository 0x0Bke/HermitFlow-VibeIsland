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
    private var usageTimer: Timer?
    private var lastClaudeUsageRefreshAt: Date?
    private var lastCodexUsageRefreshAt: Date?

    @Published private(set) var claudeUsageSnapshot: ClaudeUsageSnapshot?
    @Published private(set) var codexUsageSnapshot: CodexUsageSnapshot?

    init(appStore: AppStore = AppStore()) {
        self.appStore = appStore
        claudeUsageSnapshot = appStore.claudeUsageSnapshot
        codexUsageSnapshot = appStore.codexUsageSnapshot

        appStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        appStore.runtimeStore.$usageProviderState
            .sink { [weak self] providerState in
                self?.claudeUsageSnapshot = providerState.claude
                self?.codexUsageSnapshot = providerState.codex
            }
            .store(in: &cancellables)
    }

    var onWindowSizeChange: ((CGSize) -> Void)? {
        get { appStore.onWindowSizeChange }
        set { appStore.onWindowSizeChange = newValue }
    }

    var tasks: [CLIJob] { appStore.tasks }
    var codexStatus: CodexActivityState { appStore.codexStatus }
    var selectedLogo: BrandLogo { appStore.selectedLogo }
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
    var collapsedInlineApprovalID: String? { appStore.collapsedInlineApprovalID }
    var accessibilityPermissionGranted: Bool { appStore.accessibilityPermissionGranted }
    var accessibilityPromptDismissed: Bool { appStore.accessibilityPromptDismissed }
    var runningGlyphAnimationSuppressed: Bool { appStore.runningGlyphAnimationSuppressed }
    var isSoundMuted: Bool { appStore.isSoundMuted }
    var usageSnapshots: [ProviderUsageSnapshot] { appStore.usageSnapshots }
    var usageProviderState: UsageProviderState { appStore.usageProviderState }
    var hasUsageContent: Bool { claudeUsageSnapshot?.isEmpty == false || codexUsageSnapshot?.isEmpty == false }
    var claudeUsageSummaryText: String? { UsageSummaryFormatter.claudeSummaryText(claudeUsageSnapshot) }
    var codexUsageSummaryText: String? { UsageSummaryFormatter.codexSummaryText(codexUsageSnapshot) }
    var sourceHealthReports: [SourceHealthReport] { appStore.sourceHealthReports }
    var windowSize: CGSize { appStore.windowSize }
    var cameraGapWidth: CGFloat { appStore.cameraGapWidth }
    var isExpanded: Bool { appStore.isExpanded }
    var isHiddenMode: Bool { appStore.isHiddenMode }
    var hasInlineApprovalIsland: Bool { appStore.hasInlineApprovalIsland }
    var panelTransition: PresentationStore.PanelTransitionConfiguration { appStore.panelTransition }
    var windowResizeAnimation: PresentationStore.WindowResizeAnimation { appStore.windowResizeAnimation }
    var modeName: String { appStore.modeName }
    var focusTargetLabel: String? { appStore.focusTargetLabel }
    var accessibilityPermissionMessage: String? { appStore.accessibilityPermissionMessage }
    var panelTitle: String { appStore.panelTitle }
    var panelSubtitle: String { appStore.panelSubtitle }
    var hasPanelContent: Bool { appStore.hasPanelContent }
    var activeTask: CLIJob? { appStore.activeTask }
    var completedCount: Int { appStore.completedCount }
    var runningCount: Int { appStore.runningCount }
    var sourceLabel: String { appStore.sourceLabel }

    func handleLaunch() {
        appStore.handleLaunch()
        refreshUsageState()
        startUsageMonitoringIfNeeded()
    }

    func handleAppDidBecomeActive() {
        appStore.handleAppDidBecomeActive()
        refreshUsageState()
        startUsageMonitoringIfNeeded()
    }

    func handlePrimaryTap() {
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

    func toggleSoundMuted() {
        appStore.toggleSoundMuted()
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

    func updateDisplayLayout(isExternal: Bool) {
        appStore.updateDisplayLayout(isExternal: isExternal)
    }

    func updateCameraHousingWidth(_ width: CGFloat) {
        appStore.updateCameraHousingWidth(width)
    }

    func updateCameraHousingHeight(_ height: CGFloat) {
        appStore.updateCameraHousingHeight(height)
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

    func refreshClaudeUsageState() {
        appStore.refreshClaudeUsage()
        lastClaudeUsageRefreshAt = .now
    }

    func refreshCodexUsageState() {
        appStore.refreshCodexUsage()
        lastCodexUsageRefreshAt = .now
    }

    func refreshUsageState() {
        refreshClaudeUsageState()
        refreshCodexUsageState()
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

    func stopUsageMonitoring() {
        usageTimer?.invalidate()
        usageTimer = nil
    }

    func chooseProgressFile() {
        appStore.chooseProgressFile()
    }

    func attachProgressFile(_ url: URL) {
        appStore.attachProgressFile(url)
    }

    private func refreshUsageTimerTick(now: Date = .now) {
        if shouldRefreshClaudeUsage(now: now) {
            refreshClaudeUsageState()
        }

        if shouldRefreshCodexUsage(now: now) {
            refreshCodexUsageState()
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
}
