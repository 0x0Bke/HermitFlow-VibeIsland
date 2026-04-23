//
//  AppStore.swift
//  HermitFlow
//
//  Phase 3 store decomposition.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    let runtimeStore: RuntimeStore
    let presentationStore: PresentationStore

    private var cancellables: Set<AnyCancellable> = []

    init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        presentationStore: PresentationStore = PresentationStore()
    ) {
        self.runtimeStore = runtimeStore
        self.presentationStore = presentationStore

        runtimeStore.presentationStore = presentationStore

        runtimeStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        presentationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        runtimeStore.resolvePresentationState()
    }

    var onWindowSizeChange: ((CGSize) -> Void)? {
        get { presentationStore.onWindowSizeChange }
        set { presentationStore.onWindowSizeChange = newValue }
    }

    var displayMode: IslandDisplayMode { presentationStore.displayMode }
    var windowSize: CGSize { presentationStore.windowSize }
    var sessions: [AgentSessionSnapshot] { runtimeStore.sessions }
    var approvalRequest: ApprovalRequest? { runtimeStore.approvalRequest }
    var codexStatus: IslandCodexActivityState { runtimeStore.codexStatus }
    var activeRunningDetail: IslandRunningDetail? {
        runtimeStore.sessions.first(where: { $0.activityState == .running && $0.runningDetail == .thinking })?.runningDetail
            ?? runtimeStore.sessions.first(where: { $0.activityState == .running })?.runningDetail
    }
    var selectedLogo: IslandBrandLogo { presentationStore.selectedLogo }
    var customLogoPath: String? { presentationStore.customLogoPath }
    var focusTarget: FocusTarget? { runtimeStore.focusTarget }
    var statusMessage: String { runtimeStore.statusMessage }
    var errorMessage: String? { runtimeStore.errorMessage }
    var accessibilityPermissionMessage: String? {
        guard !runtimeStore.accessibilityPermissionGranted, !runtimeStore.accessibilityPromptDismissed else {
            return nil
        }

        return "请在“系统设置 > 隐私与安全性 > 辅助功能”中允许 HermitFlow。"
    }

    // TODO: This bridge surface exists only while views still depend on ProgressStore.
    var tasks: [CLIJob] { runtimeStore.tasks }
    var compactHeight: CGFloat { presentationStore.compactHeight }
    var cameraHousingWidth: CGFloat { presentationStore.cameraHousingWidth }
    var cameraHousingHeight: CGFloat { presentationStore.cameraHousingHeight }
    var usesExternalDisplayLayout: Bool { presentationStore.usesExternalDisplayLayout }
    var approvalDiagnosticMessage: String? { runtimeStore.approvalDiagnosticMessage }
    var approvalPreviewEnabled: Bool { presentationStore.approvalPreviewEnabled }
    var approvalDefaultFocus: ApprovalDefaultFocusOption { presentationStore.approvalDefaultFocus }
    var usageDisplayType: UsageDisplayType { presentationStore.usageDisplayType }
    var dotMatrixAnimationEnabled: Bool { presentationStore.dotMatrixAnimationEnabled }
    var inlineApprovalCommandExpanded: Bool { presentationStore.inlineApprovalCommandExpanded }
    var collapsedInlineApprovalID: String? { presentationStore.collapsedInlineApprovalID }
    var accessibilityPermissionGranted: Bool { runtimeStore.accessibilityPermissionGranted }
    var accessibilityPromptDismissed: Bool { runtimeStore.accessibilityPromptDismissed }
    var runningGlyphAnimationSuppressed: Bool { presentationStore.runningGlyphAnimationSuppressed }
    var isSoundMuted: Bool { presentationStore.isSoundMuted }
    var customApprovalNotificationSoundPath: String? { presentationStore.customApprovalNotificationSoundPath }
    var customCompletionNotificationSoundPath: String? { presentationStore.customCompletionNotificationSoundPath }
    var usageSnapshots: [ProviderUsageSnapshot] { runtimeStore.usageSnapshots }
    var usageProviderState: UsageProviderState { runtimeStore.usageProviderState }
    var claudeUsageSnapshot: ClaudeUsageSnapshot? { runtimeStore.claudeUsageSnapshot }
    var codexUsageSnapshot: CodexUsageSnapshot? { runtimeStore.codexUsageSnapshot }
    var openCodeUsageSnapshot: OpenCodeUsageSnapshot? { runtimeStore.openCodeUsageSnapshot }
    var sourceHealthReports: [SourceHealthReport] { runtimeStore.sourceHealthReports }
    var sourceMode: IslandSourceMode { runtimeStore.sourceMode }
    var externalFilePath: String? { runtimeStore.externalFilePath }
    var lastUpdatedAt: Date { runtimeStore.lastUpdatedAt }
    var cameraGapWidth: CGFloat { presentationStore.cameraGapWidth }
    var isExpanded: Bool { presentationStore.isExpanded }
    var isHiddenMode: Bool { presentationStore.isHiddenMode }
    var hasInlineApprovalIsland: Bool { presentationStore.hasInlineApprovalIsland }
    var hasInlineQuestionIsland: Bool { presentationStore.hasInlineQuestionIsland }
    var panelTransition: PresentationStore.PanelTransitionConfiguration { presentationStore.panelTransition }
    var windowResizeAnimation: PresentationStore.WindowResizeAnimation { presentationStore.windowResizeAnimation }
    var modeName: String { presentationStore.displayMode.rawValue }
    var focusTargetLabel: String? { runtimeStore.focusTarget?.displayName }
    var panelTitle: String {
        if runtimeStore.approvalRequest != nil {
            return "Approval Needed"
        }

        switch runtimeStore.codexStatus {
        case .idle:
            return "Ready"
        case .running:
            return activeRunningDetail?.displayTitle ?? "Working"
        case .success:
            return "Completed"
        case .failure:
            return "Needs Attention"
        }
    }
    var panelSubtitle: String {
        if runtimeStore.approvalRequest != nil {
            return "Codex is waiting for your decision"
        }

        return runtimeStore.statusMessage
    }
    var hasPanelContent: Bool {
        !runtimeStore.sessions.isEmpty || runtimeStore.approvalRequest != nil
    }
    var activeTask: CLIJob? {
        runtimeStore.tasks.first(where: { $0.stage == .running || $0.stage == .blocked }) ?? runtimeStore.tasks.first
    }
    var completedCount: Int {
        runtimeStore.tasks.filter { $0.stage == .success }.count
    }
    var runningCount: Int {
        runtimeStore.tasks.filter { $0.stage == .running }.count
    }
    var sourceLabel: String {
        switch runtimeStore.sourceMode {
        case .localCodex:
            return "Local Codex"
        case .demo:
            return "Demo"
        case .file:
            return "Live JSON"
        }
    }

    func handleLaunch() {
        runtimeStore.handleLaunch()
    }

    func handleAppDidBecomeActive() {
        runtimeStore.handleAppDidBecomeActive()
    }

    // TODO: Remove this bridge when callers dispatch directly into RuntimeStore.
    func dispatch(_ event: IslandEvent) {
        runtimeStore.dispatch(event)
    }

    // TODO: Remove this bridge when callers dispatch directly into RuntimeStore.
    func dispatch(_ events: [IslandEvent]) {
        runtimeStore.dispatch(events)
    }

    func handlePrimaryTap() {
        presentationStore.handlePrimaryTap()
    }

    func handleSecondaryTap() {
        presentationStore.handleSecondaryTap()
    }

    func showPanel() {
        presentationStore.showPanel()
    }

    func showIsland() {
        presentationStore.showIsland()
    }

    func showHidden() {
        presentationStore.showHidden()
    }

    func collapsePanel() {
        presentationStore.collapsePanel()
    }

    func resyncClaudeHooks() {
        runtimeStore.resyncClaudeHooks()
    }

    func openAccessibilitySettings() {
        runtimeStore.openAccessibilitySettings()
    }

    func rejectApproval() {
        runtimeStore.rejectApproval()
    }

    func acceptApproval() {
        runtimeStore.acceptApproval()
    }

    func acceptAllApprovals() {
        runtimeStore.acceptAllApprovals()
    }

    func selectLogo(_ logo: IslandBrandLogo) {
        presentationStore.selectLogo(logo)
    }

    func setCustomLogoPath(_ path: String?) {
        presentationStore.setCustomLogoPath(path)
    }

    func clearCustomLogo() {
        presentationStore.clearCustomLogo()
    }

    func toggleSoundMuted() {
        presentationStore.toggleSoundMuted()
    }

    func setCustomNotificationSoundPath(_ path: String?, for kind: NotificationSoundKind) {
        presentationStore.setCustomNotificationSoundPath(path, for: kind)
    }

    func setApprovalDefaultFocus(_ option: ApprovalDefaultFocusOption) {
        presentationStore.setApprovalDefaultFocus(option)
    }

    func setUsageDisplayType(_ type: UsageDisplayType) {
        presentationStore.setUsageDisplayType(type)
    }

    func setDotMatrixAnimationEnabled(_ enabled: Bool) {
        presentationStore.setDotMatrixAnimationEnabled(enabled)
    }

    func updateInlineApprovalCommandExpanded(_ expanded: Bool) {
        presentationStore.updateInlineApprovalCommandExpanded(expanded)
    }

    func bringForward(_ target: FocusTarget?) {
        runtimeStore.bringForward(target)
    }

    func updateCompactHeight(_ height: CGFloat) {
        presentationStore.updateCompactHeight(height)
    }

    func syncCameraHousingMetrics(width: CGFloat, height: CGFloat) {
        presentationStore.syncCameraHousingMetrics(width: width, height: height)
    }

    func updateDisplayLayout(isExternal: Bool, screenWidth: CGFloat) {
        presentationStore.updateDisplayLayout(isExternal: isExternal, screenWidth: screenWidth)
    }

    func handlePanelHover(_ isHovering: Bool) {
        presentationStore.handlePanelHover(isHovering)
    }

    func armPanelHoverMonitoring() {
        presentationStore.armPanelHoverMonitoring()
    }

    func suppressPanelAutoCollapse(for duration: TimeInterval) {
        presentationStore.suppressPanelAutoCollapse(for: duration)
    }

    func collapseInlineApproval() {
        runtimeStore.collapseInlineApproval()
    }

    func toggleApprovalPreview() {
        runtimeStore.toggleApprovalPreview()
    }

    func dismissAccessibilityPrompt() {
        runtimeStore.dismissAccessibilityPrompt()
    }

    func syncQuestionPrompt(_ prompt: ClaudeQuestionPrompt?) {
        presentationStore.syncQuestionPrompt(prompt)
    }

    func updateCameraHousingWidth(_ width: CGFloat) {
        presentationStore.updateCameraHousingWidth(width)
    }

    func updateCameraHousingHeight(_ height: CGFloat) {
        presentationStore.updateCameraHousingHeight(height)
    }

    func startLocalCodexMonitoring() {
        runtimeStore.startLocalCodexMonitoring()
    }

    func refreshClaudeUsage() {
        runtimeStore.refreshClaudeUsage()
    }

    func refreshCodexUsage() {
        runtimeStore.refreshCodexUsage()
    }

    func refreshOpenCodeUsage() {
        runtimeStore.refreshOpenCodeUsage()
    }

    func refreshUsage() {
        runtimeStore.refreshUsage()
    }

    func startDemoMode() {
        runtimeStore.startDemoMode()
    }

    func chooseProgressFile() {
        runtimeStore.chooseProgressFile()
    }

    func attachProgressFile(_ url: URL) {
        runtimeStore.attachProgressFile(url)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
