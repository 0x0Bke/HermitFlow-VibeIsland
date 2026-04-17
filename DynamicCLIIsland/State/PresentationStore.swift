//
//  PresentationStore.swift
//  HermitFlow
//
//  Phase 3 store decomposition.
//

import Foundation
import SwiftUI

enum ApprovalDefaultFocusOption: String, CaseIterable {
    case accept
    case acceptAll

    var menuTitle: String {
        switch self {
        case .accept:
            return "接受"
        case .acceptAll:
            return "全部接受"
        }
    }
}

enum UsageDisplayType: String, CaseIterable {
    case remaining
    case used

    var menuTitle: String {
        switch self {
        case .remaining:
            return "剩余量"
        case .used:
            return "使用量"
        }
    }

    var englishSubtitleSuffix: String {
        switch self {
        case .remaining:
            return "remaining"
        case .used:
            return "used"
        }
    }

    func percentageText(used: Int, remaining: Int) -> String {
        switch self {
        case .remaining:
            return "\(remaining)%"
        case .used:
            return "\(used)%"
        }
    }

    func percentageValue(used: Double, remaining: Double) -> Double {
        switch self {
        case .remaining:
            return remaining
        case .used:
            return used
        }
    }
}

enum AskUserQuestionHandlingMode: String, CaseIterable {
    case takeOver
    case mirror

    var menuTitle: String {
        switch self {
        case .takeOver:
            return "HermitFlow 回答"
        case .mirror:
            return "Claude 原生回答"
        }
    }

    var promptHint: String? {
        switch self {
        case .takeOver:
            return "Answer here to send the response back to Claude Code."
        case .mirror:
            return "Answer in Claude CLI or the Claude extension. HermitFlow is mirroring this prompt only."
        }
    }
}

@MainActor
final class PresentationStore: ObservableObject {
    typealias BrandLogo = IslandBrandLogo
    typealias DisplayMode = IslandDisplayMode

    struct PanelTransitionConfiguration {
        let windowDuration: TimeInterval
        let contentDuration: Double
        let contentVerticalOffset: CGFloat

        var contentAnimation: Animation {
            .easeInOut(duration: contentDuration)
        }

        static let standard = PanelTransitionConfiguration(
            windowDuration: 0.24,
            contentDuration: 0.18,
            contentVerticalOffset: 8
        )
    }

    enum WindowResizeAnimation {
        case none
        case panelTransition
    }

    @Published private(set) var displayMode: DisplayMode = .island
    @Published private(set) var selectedLogo: BrandLogo
    @Published private(set) var compactHeight: CGFloat = 37
    @Published private(set) var cameraHousingWidth: CGFloat = 0
    @Published private(set) var cameraHousingHeight: CGFloat = 37
    @Published private(set) var activeScreenWidth: CGFloat = 0
    @Published private(set) var usesExternalDisplayLayout = false
    @Published private(set) var collapsedInlineApprovalID: String?
    @Published private(set) var approvalPreviewEnabled = false
    @Published private(set) var inlineApprovalCommandExpanded = false
    @Published private(set) var runningGlyphAnimationSuppressed = false
    @Published private(set) var isSoundMuted: Bool
    @Published private(set) var customApprovalNotificationSoundPath: String?
    @Published private(set) var customCompletionNotificationSoundPath: String?
    @Published private(set) var approvalDefaultFocus: ApprovalDefaultFocusOption
    @Published private(set) var usageDisplayType: UsageDisplayType

    private let compactHeightOverscan: CGFloat = 2.5
    private let inlineApprovalMinimumHeight: CGFloat = 300
    private let inlineApprovalExpandedHeight: CGFloat = 460
    private let inlineApprovalIslandFixedWidth: CGFloat = 560
    private let inlineQuestionCompactHeight: CGFloat = 350
    private let inlineQuestionExpandedHeight: CGFloat = 430
    private let inlineQuestionIslandFixedWidth: CGFloat = 560
    private let externalDisplayCompactWidthMultiplier: CGFloat = 1.6
    private let externalDisplayPanelWidthMultiplier: CGFloat = 1.2
    private let externalDisplayIslandMaxWidth: CGFloat = 392
    private let externalDisplayInlineApprovalMaxWidth: CGFloat = 500
    private let externalDisplayInlineQuestionMaxWidth: CGFloat = 500
    private let externalDisplayPanelMaxWidthWithoutApproval: CGFloat = 560
    private let externalDisplayPanelMaxWidthWithApproval: CGFloat = 640
    private let logoDefaultsKey = "HermitFlow.selectedLogo"
    private let soundMutedDefaultsKey = "HermitFlow.soundMuted"
    private let approvalDefaultFocusDefaultsKey = "HermitFlow.approvalDefaultFocus"
    private let usageDisplayTypeDefaultsKey = "HermitFlow.usageDisplayType"

    // TODO: These timing fields are still coupled to legacy AppDelegate behaviors.
    private var hasHoveredInsidePanelSinceShown = false
    private var panelShownAt = Date.distantPast
    private var panelCollapseTask: Task<Void, Never>?
    private var panelAutoCollapseSuppressedUntil = Date.distantPast
    private var runningGlyphUnsuppressTask: Task<Void, Never>?

    // TODO: Remove these temporary runtime mirrors once the views read from AppStore directly.
    private var currentApprovalRequest: ApprovalRequest?
    private var currentQuestionPrompt: ClaudeQuestionPrompt?
    private var currentSessions: [AgentSessionSnapshot] = []
    private var currentUsageCardCount = 0

    var onWindowSizeChange: ((CGSize) -> Void)?
    private(set) var windowResizeAnimation: WindowResizeAnimation = .none
    let panelTransition = PanelTransitionConfiguration.standard

    init() {
        let storedLogo = UserDefaults.standard.string(forKey: logoDefaultsKey)
        selectedLogo = BrandLogo(rawValue: storedLogo ?? "") ?? .clawd
        isSoundMuted = UserDefaults.standard.bool(forKey: soundMutedDefaultsKey)
        Self.migrateLegacyNotificationSoundSettingsIfNeeded()
        customApprovalNotificationSoundPath = Self.normalizedCustomSoundPath(
            UserDefaults.standard.string(forKey: NotificationSoundKind.approval.customSoundPathDefaultsKey)
        )
        customCompletionNotificationSoundPath = Self.normalizedCustomSoundPath(
            UserDefaults.standard.string(forKey: NotificationSoundKind.completion.customSoundPathDefaultsKey)
        )
        let storedApprovalDefaultFocus = UserDefaults.standard.string(forKey: approvalDefaultFocusDefaultsKey)
        approvalDefaultFocus = ApprovalDefaultFocusOption(rawValue: storedApprovalDefaultFocus ?? "") ?? .accept
        let storedUsageDisplayType = UserDefaults.standard.string(forKey: usageDisplayTypeDefaultsKey)
        usageDisplayType = UsageDisplayType(rawValue: storedUsageDisplayType ?? "") ?? .remaining
    }

    var windowSize: CGSize {
        switch displayMode {
        case .panel:
            return CGSize(width: expandedWidth, height: panelHeight)
        case .island:
            return CGSize(width: islandWidth, height: islandHeight)
        case .hidden:
            return CGSize(width: hiddenWidth, height: compactHeight)
        }
    }

    var cameraGapWidth: CGFloat {
        cameraHousingWidth > 0 ? cameraHousingWidth + 28 : 0
    }

    var isExpanded: Bool {
        displayMode == .panel
    }

    var isHiddenMode: Bool {
        displayMode == .hidden
    }

    var hasInlineApprovalIsland: Bool {
        displayMode == .island && prioritizedInlineContent == .approval
    }

    var hasInlineQuestionIsland: Bool {
        displayMode == .island && prioritizedInlineContent == .question
    }

    private var isInlineApprovalExpanded: Bool {
        currentApprovalRequest != nil && collapsedInlineApprovalID != currentApprovalRequest?.id
    }

    private var prioritizedInlineContent: PrioritizedInlineContent? {
        let inlineApprovalRequest = isInlineApprovalExpanded ? currentApprovalRequest : nil

        switch (inlineApprovalRequest, currentQuestionPrompt) {
        case let (approval?, question?):
            return approval.createdAt >= question.createdAt ? .approval : .question
        case (.some, nil):
            return .approval
        case (nil, .some):
            return .question
        case (nil, nil):
            return nil
        }
    }

    private var islandWidth: CGFloat {
        switch prioritizedInlineContent {
        case .approval:
            let width = inlineApprovalIslandFixedWidth
            guard usesExternalDisplayLayout else {
                return width
            }

            return min(width, externalDisplayInlineApprovalMaxWidth)
        case .question:
            let width = inlineQuestionIslandFixedWidth
            guard usesExternalDisplayLayout else {
                return width
            }

            return min(width, externalDisplayInlineQuestionMaxWidth)
        case .none:
            break
        }

        let baseWidth = max(
            228,
            cameraGapWidth + 140,
            proportionalCompactWidth(for: activeScreenWidth, ratio: 0.24)
        )

        let width = scaledWidth(baseWidth, for: .island)
        guard usesExternalDisplayLayout else {
            return width
        }

        return min(width, externalDisplayIslandMaxWidth)
    }

    private var islandHeight: CGFloat {
        switch prioritizedInlineContent {
        case .approval:
            let minimumHeight = inlineApprovalCommandExpanded ? inlineApprovalExpandedHeight : inlineApprovalMinimumHeight
            return max(compactHeight, minimumHeight)
        case .question:
            let minimumHeight = currentQuestionPrompt?.allowsFreeText == true
                ? inlineQuestionExpandedHeight
                : inlineQuestionCompactHeight
            return max(compactHeight, minimumHeight)
        case .none:
            break
        }

        return compactHeight
    }

    private var hiddenWidth: CGFloat {
        scaledWidth(max(cameraHousingWidth, 176), for: .hidden)
    }

    private var expandedWidth: CGFloat {
        let minimumBaseWidth: CGFloat = currentApprovalRequest == nil ? 720 : 860
        let proportionalRatio: CGFloat = currentApprovalRequest == nil ? 0.42 : 0.5
        let baseWidth = max(
            560,
            cameraGapWidth + (currentApprovalRequest == nil ? 279 : 380),
            proportionalPanelWidth(
                for: activeScreenWidth,
                ratio: proportionalRatio,
                minimumBaseWidth: minimumBaseWidth
            )
        )

        let width = scaledWidth(baseWidth, for: .panel)
        guard usesExternalDisplayLayout else {
            return width
        }

        let maximumWidth = currentApprovalRequest == nil
            ? externalDisplayPanelMaxWidthWithoutApproval
            : externalDisplayPanelMaxWidthWithApproval
        return min(width, maximumWidth)
    }

    private var panelHeight: CGFloat {
        let baseHeight: CGFloat = 252
        switch currentUsageCardCount {
        case 2...:
            return baseHeight + 88
        case 1:
            return baseHeight + 54
        default:
            return baseHeight
        }
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

    func collapseInlineApproval() {
        guard let currentApprovalRequest else {
            return
        }

        collapsedInlineApprovalID = currentApprovalRequest.id
        suppressRunningGlyphAnimation(for: 0.45)
        notifyWindowSizeChange()
    }

    func toggleApprovalPreview() {
        approvalPreviewEnabled.toggle()
        if approvalPreviewEnabled {
            setDisplayMode(.island)
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

        notifyWindowSizeChange()
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

        notifyWindowSizeChange()
    }

    func updateDisplayLayout(isExternal: Bool, screenWidth: CGFloat) {
        let normalizedScreenWidth = max(screenWidth.rounded(.up), 0)
        guard usesExternalDisplayLayout != isExternal || abs(activeScreenWidth - normalizedScreenWidth) > 0.5 else {
            return
        }

        usesExternalDisplayLayout = isExternal
        activeScreenWidth = normalizedScreenWidth
        notifyWindowSizeChange()
    }

    func updateCameraHousingWidth(_ width: CGFloat) {
        let normalizedWidth = max(width.rounded(.up), 0)
        guard abs(cameraHousingWidth - normalizedWidth) > 0.5 else {
            return
        }

        cameraHousingWidth = normalizedWidth
        notifyWindowSizeChange()
    }

    func updateCameraHousingHeight(_ height: CGFloat) {
        let normalizedHeight = min(max(height.rounded(.up), 28), 64)
        guard abs(cameraHousingHeight - normalizedHeight) > 0.5 else {
            return
        }

        cameraHousingHeight = normalizedHeight
        updateCompactHeight(normalizedHeight + compactHeightOverscan)
    }

    func selectLogo(_ logo: BrandLogo) {
        guard selectedLogo != logo else {
            return
        }

        selectedLogo = logo
        UserDefaults.standard.set(logo.rawValue, forKey: logoDefaultsKey)
    }

    func toggleSoundMuted() {
        isSoundMuted.toggle()
        UserDefaults.standard.set(isSoundMuted, forKey: soundMutedDefaultsKey)
    }

    func setCustomNotificationSoundPath(_ path: String?, for kind: NotificationSoundKind) {
        let normalizedPath = Self.normalizedCustomSoundPath(path)
        switch kind {
        case .approval:
            guard customApprovalNotificationSoundPath != normalizedPath else {
                return
            }
            customApprovalNotificationSoundPath = normalizedPath
        case .completion:
            guard customCompletionNotificationSoundPath != normalizedPath else {
                return
            }
            customCompletionNotificationSoundPath = normalizedPath
        }

        let defaults = UserDefaults.standard
        if let normalizedPath {
            defaults.set(normalizedPath, forKey: kind.customSoundPathDefaultsKey)
        } else {
            defaults.removeObject(forKey: kind.customSoundPathDefaultsKey)
            defaults.removeObject(forKey: kind.customSoundBookmarkDefaultsKey)
            try? FileManager.default.removeItem(at: kind.customFileURL)
        }
    }

    private static func migrateLegacyNotificationSoundSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        let approvalPathKey = NotificationSoundKind.approval.customSoundPathDefaultsKey
        let approvalBookmarkKey = NotificationSoundKind.approval.customSoundBookmarkDefaultsKey
        let legacyPathKey = "HermitFlow.customNotificationSoundPath"
        let legacyBookmarkKey = "HermitFlow.customNotificationSoundBookmark"

        guard defaults.string(forKey: approvalPathKey) == nil,
              defaults.data(forKey: approvalBookmarkKey) == nil else {
            return
        }

        if let legacyPath = defaults.string(forKey: legacyPathKey), !legacyPath.isEmpty {
            defaults.set(legacyPath, forKey: approvalPathKey)
        }

        if let legacyBookmark = defaults.data(forKey: legacyBookmarkKey) {
            defaults.set(legacyBookmark, forKey: approvalBookmarkKey)
        }

        let legacyCustomURL = FilePaths.notificationSoundsDirectory
            .appendingPathComponent("Custom", isDirectory: false)
        if FileManager.default.fileExists(atPath: legacyCustomURL.path),
           !FileManager.default.fileExists(atPath: FilePaths.customApprovalNotificationSound.path) {
            try? FileManager.default.moveItem(at: legacyCustomURL, to: FilePaths.customApprovalNotificationSound)
        }

        defaults.removeObject(forKey: legacyPathKey)
        defaults.removeObject(forKey: legacyBookmarkKey)
    }

    func setApprovalDefaultFocus(_ option: ApprovalDefaultFocusOption) {
        guard approvalDefaultFocus != option else {
            return
        }

        approvalDefaultFocus = option
        UserDefaults.standard.set(option.rawValue, forKey: approvalDefaultFocusDefaultsKey)
    }

    func setUsageDisplayType(_ type: UsageDisplayType) {
        guard usageDisplayType != type else {
            return
        }

        usageDisplayType = type
        UserDefaults.standard.set(type.rawValue, forKey: usageDisplayTypeDefaultsKey)
    }

    func syncRuntimeContext(
        approvalRequest: ApprovalRequest?,
        sessions: [AgentSessionSnapshot],
        usageCardCount: Int = 0
    ) {
        if approvalRequest?.id != currentApprovalRequest?.id || approvalRequest == nil {
            inlineApprovalCommandExpanded = false
        }
        currentApprovalRequest = approvalRequest
        currentSessions = sessions
        currentUsageCardCount = usageCardCount
    }

    func syncQuestionPrompt(_ prompt: ClaudeQuestionPrompt?) {
        currentQuestionPrompt = prompt
    }

    func resetCollapsedInlineApproval() {
        collapsedInlineApprovalID = nil
    }

    func updateInlineApprovalCommandExpanded(_ expanded: Bool) {
        guard inlineApprovalCommandExpanded != expanded else {
            return
        }

        inlineApprovalCommandExpanded = expanded
        guard isInlineApprovalExpanded else {
            return
        }

        notifyWindowSizeChange()
    }

    private func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else {
            return
        }

        let previousMode = displayMode

        panelCollapseTask?.cancel()
        panelCollapseTask = nil
        hasHoveredInsidePanelSinceShown = false
        if mode == .panel {
            panelShownAt = Date()
        }

        displayMode = mode
        notifyWindowSizeChange(animation: panelModeTransitionAnimation(from: previousMode, to: mode))
    }

    private static func normalizedCustomSoundPath(_ path: String?) -> String? {
        guard let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedPath.isEmpty else {
            return nil
        }

        return trimmedPath
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

    private func proportionalCompactWidth(for screenWidth: CGFloat, ratio: CGFloat) -> CGFloat {
        guard usesExternalDisplayLayout, cameraHousingWidth <= 0, screenWidth > 0 else {
            return 0
        }

        return (screenWidth * ratio) / externalDisplayCompactWidthMultiplier
    }

    private func proportionalPanelWidth(
        for screenWidth: CGFloat,
        ratio: CGFloat,
        minimumBaseWidth: CGFloat
    ) -> CGFloat {
        guard usesExternalDisplayLayout, cameraHousingWidth <= 0, screenWidth > 0 else {
            return 0
        }

        let proportionalBaseWidth = (screenWidth * ratio) / externalDisplayPanelWidthMultiplier
        return max(minimumBaseWidth, proportionalBaseWidth)
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

    private func panelModeTransitionAnimation(from oldMode: DisplayMode, to newMode: DisplayMode) -> WindowResizeAnimation {
        let modes: Set<DisplayMode> = [oldMode, newMode]
        if modes == [.island, .panel] {
            return .panelTransition
        }

        return .none
    }

    private func notifyWindowSizeChange(animation: WindowResizeAnimation = .none) {
        windowResizeAnimation = animation
        onWindowSizeChange?(windowSize)
        windowResizeAnimation = .none
    }
}

private extension PresentationStore {
    enum PrioritizedInlineContent {
        case approval
        case question
    }
}
