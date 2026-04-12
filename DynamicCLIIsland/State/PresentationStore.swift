//
//  PresentationStore.swift
//  HermitFlow
//
//  Phase 3 store decomposition.
//

import Foundation

@MainActor
final class PresentationStore: ObservableObject {
    typealias BrandLogo = IslandBrandLogo
    typealias DisplayMode = IslandDisplayMode

    @Published private(set) var displayMode: DisplayMode = .island {
        didSet {
            onWindowSizeChange?(windowSize)
        }
    }
    @Published private(set) var selectedLogo: BrandLogo
    @Published private(set) var compactHeight: CGFloat = 37
    @Published private(set) var cameraHousingWidth: CGFloat = 0
    @Published private(set) var cameraHousingHeight: CGFloat = 37
    @Published private(set) var usesExternalDisplayLayout = false
    @Published private(set) var collapsedInlineApprovalID: String?
    @Published private(set) var approvalPreviewEnabled = false
    @Published private(set) var runningGlyphAnimationSuppressed = false
    @Published private(set) var isSoundMuted: Bool

    private let compactHeightOverscan: CGFloat = 2.5
    private let inlineApprovalMinimumHeight: CGFloat = 300
    private let externalDisplayCompactWidthMultiplier: CGFloat = 1.6
    private let externalDisplayPanelWidthMultiplier: CGFloat = 1.2
    private let logoDefaultsKey = "HermitFlow.selectedLogo"
    private let soundMutedDefaultsKey = "HermitFlow.soundMuted"

    // TODO: These timing fields are still coupled to legacy AppDelegate behaviors.
    private var hasHoveredInsidePanelSinceShown = false
    private var panelShownAt = Date.distantPast
    private var panelCollapseTask: Task<Void, Never>?
    private var panelAutoCollapseSuppressedUntil = Date.distantPast
    private var runningGlyphUnsuppressTask: Task<Void, Never>?

    // TODO: Remove these temporary runtime mirrors once the views read from AppStore directly.
    private var currentApprovalRequest: ApprovalRequest?
    private var currentSessions: [AgentSessionSnapshot] = []
    private var currentUsageCardCount = 0

    var onWindowSizeChange: ((CGSize) -> Void)?

    init() {
        let storedLogo = UserDefaults.standard.string(forKey: logoDefaultsKey)
        selectedLogo = BrandLogo(rawValue: storedLogo ?? "") ?? .clawd
        isSoundMuted = UserDefaults.standard.bool(forKey: soundMutedDefaultsKey)
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
        displayMode == .island && isInlineApprovalExpanded
    }

    private var isInlineApprovalExpanded: Bool {
        currentApprovalRequest != nil && collapsedInlineApprovalID != currentApprovalRequest?.id
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
        scaledWidth(max(420, cameraGapWidth + 279), for: .panel)
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

        guard currentApprovalRequest == nil else {
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
        onWindowSizeChange?(windowSize)
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

    func syncRuntimeContext(
        approvalRequest: ApprovalRequest?,
        sessions: [AgentSessionSnapshot],
        usageCardCount: Int = 0
    ) {
        currentApprovalRequest = approvalRequest
        currentSessions = sessions
        currentUsageCardCount = usageCardCount
    }

    func resetCollapsedInlineApproval() {
        collapsedInlineApprovalID = nil
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
}
