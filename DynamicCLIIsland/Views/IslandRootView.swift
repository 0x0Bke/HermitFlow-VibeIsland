import SwiftUI
import QuartzCore

struct IslandRootView: View {
    @ObservedObject var store: ProgressStore
    @State private var activePanelTransition: PanelTransition?
    @State private var panelTransitionCleanupTask: Task<Void, Never>?
    @State private var observedDisplayMode: ProgressStore.DisplayMode = .island
    @StateObject private var brandLogoImageCache = BrandLogoImageCache()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                islandShape
                    .fill(backgroundFill)
                    .overlay(
                        islandShape
                            .strokeBorder(borderColor, lineWidth: 1)
                    )

                bodyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if !shouldBlockCompactGestureOverlay {
                    Color.clear
                        .contentShape(islandShape)
                        .gesture(primaryClickGesture)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(islandShape)
            .contentShape(islandShape)
            .onHover { isHovering in
                store.handlePanelHover(isHovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            activePanelTransition = nil
            observedDisplayMode = store.displayMode
        }
        .onChange(of: store.displayMode) { newValue in
            let oldValue = observedDisplayMode
            observedDisplayMode = newValue
            handleDisplayModeChange(from: oldValue, to: newValue)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if shouldHoldPanelBody {
            expandedBody
                .allowsHitTesting(store.displayMode == .panel)
        } else if store.hasInlineQuestionIsland, let prompt = store.activeQuestionPrompt {
            inlineQuestionBody(prompt)
        } else if store.hasInlineApprovalIsland, let approvalRequest = store.approvalRequest {
            inlineApprovalBody(approvalRequest)
        } else if store.displayMode == .panel {
            expandedBody
        } else if store.displayMode == .island {
            compactBody
        } else {
            EmptyView()
        }
    }

    private var primaryClickGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    store.handleSecondaryTap()
                case .second:
                    store.handlePrimaryTap()
                }
            }
    }

    private var backgroundFill: Color {
        if store.isHiddenMode {
            return Color.black.opacity(0.001)
        }

        if shouldUsePanelSurfaceStyling {
            return Color.black
        }

        return .black
    }

    private var borderColor: Color {
        if store.isHiddenMode || shouldUsePanelSurfaceStyling {
            return .clear
        }

        return Color.white.opacity(0.04)
    }

    private var compactBody: some View {
        islandHeader
            .frame(width: store.windowSize.width, height: store.windowSize.height, alignment: .center)
    }

    private var compactHorizontalPadding: CGFloat { 36 }

    private var shouldHoldPanelBody: Bool {
        activePanelTransition != nil
    }

    private var shouldUsePanelSurfaceStyling: Bool {
        store.displayMode == .panel || activePanelTransition != nil
    }

    private var shouldBlockCompactGestureOverlay: Bool {
        store.displayMode == .panel || store.hasInlineApprovalIsland || store.hasInlineQuestionIsland || activePanelTransition != nil
    }

    private var railWidth: CGFloat {
        max((store.windowSize.width - store.cameraGapWidth - compactHorizontalPadding * 2) / 2, 0)
    }


    private func inlineApprovalBody(_ request: ApprovalRequest) -> some View {
        ApprovalInlineView(
            store: store,
            request: request,
            header: AnyView(islandHeader),
            sessionTitle: approvalSessionTitle(for: request),
            primaryTitle: approvalPrimaryTitle(for: request),
            timestampText: relativeTimestamp(for: request.createdAt),
            diagnosticMessage: store.approvalDiagnosticMessage,
            defaultFocus: store.approvalDefaultFocus
        )
    }

    private func inlineQuestionBody(_ prompt: ClaudeQuestionPrompt) -> some View {
        QuestionInlineView(
            store: store,
            prompt: prompt,
            header: AnyView(islandHeader),
            timestampText: relativeTimestamp(for: prompt.createdAt)
        )
    }

    private var islandHeader: some View {
        ZStack {
            HStack(spacing: 0) {
                compactBrandIcon
                    .frame(width: railWidth, alignment: .leading)

                cameraGapSpacer

                Color.clear
                    .frame(width: railWidth)
            }
        }
        .padding(.horizontal, compactHorizontalPadding)
        .frame(height: store.compactHeight)
        .overlay(alignment: .trailing) {
            compactStatusIcon
                .frame(width: 18, height: 18)
                .padding(.trailing, compactHorizontalPadding)
        }
        .contentShape(Rectangle())
        .gesture(primaryClickGesture)
    }

    private var expandedBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                panelTopBar

                if !store.sessions.isEmpty || store.hasUsageContent {
                    sessionsSection
                }

                if let accessibilityPermissionMessage = store.accessibilityPermissionMessage {
                    accessibilityPermissionCard(message: accessibilityPermissionMessage)
                }

                if !store.sourceHealthReports.isEmpty {
                    DiagnosticsCardView(reports: store.sourceHealthReports)
                }

                if let errorMessage = store.errorMessage {
                    errorCard(message: errorMessage)
                }

                if let questionErrorMessage = store.questionErrorMessage, store.activeQuestionPrompt == nil {
                    errorCard(message: questionErrorMessage)
                }

                if store.questionPresentationMode == .panel,
                   let prompt = store.activeQuestionPrompt,
                   shouldPrioritizeQuestionPrompt(prompt) {
                    questionCard(prompt)
                }

                if let approvalRequest = store.approvalRequest {
                    approvalCard(approvalRequest)
                }

                if store.questionPresentationMode == .panel,
                   let prompt = store.activeQuestionPrompt,
                   !shouldPrioritizeQuestionPrompt(prompt) {
                    questionCard(prompt)
                }

                if store.sessions.isEmpty {
                    emptyStateCard
                } else {
                    ForEach(store.sessions) { session in
                        sessionCard(session)
                    }
                }
            }
            .padding(.top, 0)
            .padding(.bottom, 18)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabledIfAvailable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var islandShape: some InsettableShape {
        TabCutShape(
            neckInset: 20,
            shoulderDrop: 12,
            bottomRadius: shouldUsePanelSurfaceStyling ? 24 : 20
        )
    }

    @ViewBuilder
    private var compactBrandIcon: some View {
        brandLogoImage(size: 18)
    }

    @ViewBuilder
    private var compactStatusIcon: some View {
        statusGlyph(for: store.codexStatus, runningDetail: store.activeRunningDetail)
            .id(statusGlyphIdentity)
            .transition(.identity)
            .animation(nil, value: store.codexStatus)
            .animation(nil, value: store.activeRunningDetail)
            .animation(nil, value: store.runningGlyphAnimationSuppressed)
            .animation(nil, value: store.dotMatrixAnimationEnabled)
    }

    @ViewBuilder
    private var cameraGapSpacer: some View {
        if store.cameraGapWidth > 0 {
            Color.clear
                .frame(width: store.cameraGapWidth)
        }
    }

    @ViewBuilder
    private func brandLogoImage(size: CGFloat) -> some View {
        if let image = brandLogoImageCache.image(
            for: store.selectedLogo,
            customLogoPath: store.customLogoPath
        ) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            EmptyView()
                .frame(width: size, height: size)
        }
    }

    private func handleDisplayModeChange(
        from oldValue: ProgressStore.DisplayMode,
        to newValue: ProgressStore.DisplayMode
    ) {
        let modes: Set<ProgressStore.DisplayMode> = [oldValue, newValue]
        guard modes == [.island, .panel] else {
            panelTransitionCleanupTask?.cancel()
            activePanelTransition = nil
            return
        }

        let transition = PanelTransition(from: oldValue, to: newValue)
        activePanelTransition = transition
        panelTransitionCleanupTask?.cancel()
        panelTransitionCleanupTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(store.panelTransition.windowDuration * 1_000_000_000)
            )
            guard !Task.isCancelled, activePanelTransition == transition else {
                return
            }

            activePanelTransition = nil
        }
    }

    @ViewBuilder
    private func statusGlyph(
        for state: IslandCodexActivityState,
        runningDetail: IslandRunningDetail?
    ) -> some View {
        if shouldUseSpinnerStatusGlyph {
            if store.dotMatrixAnimationEnabled {
                DotMatrixSpinnerStatusGlyph(isAnimating: !store.runningGlyphAnimationSuppressed)
            } else {
                BlueBreathingStatusGlyph(isAnimating: !store.runningGlyphAnimationSuppressed)
            }
        } else {
            switch state {
            case .idle:
                IdleStatusGlyph()
            case .running:
                if store.dotMatrixAnimationEnabled {
                    DotMatrixWaveStatusGlyph(isAnimating: !store.runningGlyphAnimationSuppressed)
                } else {
                    RunningStatusGlyph(animationAllowed: !store.runningGlyphAnimationSuppressed)
                }
            case .success:
                if store.dotMatrixAnimationEnabled {
                    DotMatrixSuccessStatusGlyph(isAnimating: !store.runningGlyphAnimationSuppressed)
                } else {
                    SuccessStatusGlyph()
                }
            case .failure:
                TerminalStatusGlyph(state: .failure)
            }
        }
    }

    private var statusGlyphIdentity: String {
        if let approvalRequest = store.approvalRequest {
            return "spinner-approval-\(approvalRequest.id)-\(store.runningGlyphAnimationSuppressed)-\(store.dotMatrixAnimationEnabled)"
        }

        if let prompt = store.activeQuestionPrompt {
            return "spinner-question-\(prompt.id)-\(store.runningGlyphAnimationSuppressed)-\(store.dotMatrixAnimationEnabled)"
        }

        return "\(store.codexStatus.rawValue)-\(store.activeRunningDetail?.rawValue ?? "none")-\(store.runningGlyphAnimationSuppressed)-\(store.dotMatrixAnimationEnabled)"
    }

    private var shouldUseSpinnerStatusGlyph: Bool {
        store.approvalRequest != nil || store.activeQuestionPrompt != nil
    }
}

private extension View {
    @ViewBuilder
    func scrollClipDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.scrollClipDisabled()
        } else {
            self
        }
    }
}

private struct PanelTransition: Equatable {
    let from: ProgressStore.DisplayMode
    let to: ProgressStore.DisplayMode
}

private extension IslandRootView {
    var panelTopBar: some View {
        ZStack {
            HStack(spacing: 0) {
                compactBrandIcon
                    .frame(width: 18, height: 18)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    soundToggleButton
                    settingsButton

                    compactStatusIcon
                        .frame(width: 18, height: 18)
                }
            }
        }
        .frame(height: 38)
    }

    var soundToggleButton: some View {
        Button(action: store.toggleSoundMuted) {
            Image(systemName: store.isSoundMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.isSoundMuted ? Color.white.opacity(0.42) : Color.white.opacity(0.74))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.isSoundMuted ? "Unmute notifications" : "Mute notifications")
    }

    var settingsButton: some View {
        Button(action: store.openSettingsPanel) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show settings")
    }

    var sessionsSectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(height: 1)
    }

    var sessionsSectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))

            Spacer(minLength: 8)

            Text(sessionCountLabel)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.44))
        }
        .padding(.top, 0)
        .padding(.bottom, 0)
    }

    var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.hasUsageContent {
                usageBlock
                sessionsSectionDivider
            }

            if !store.sessions.isEmpty {
                sessionsSectionHeader
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelCardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(panelCardStroke, lineWidth: 1)
        )
    }

    var usageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let claudeUsageSnapshot = store.claudeUsageSnapshot, !claudeUsageSnapshot.isEmpty {
                claudeUsageProviderRow(snapshot: claudeUsageSnapshot)
            }

            if let codexUsageSnapshot = store.codexUsageSnapshot, !codexUsageSnapshot.isEmpty {
                usageProviderRow(
                    title: "Codex",
                    shortLabel: "5h",
                    shortValue: displayedPercentage(for: codexWindow(minutes: 300, in: codexUsageSnapshot)),
                    longLabel: "wk",
                    longValue: displayedPercentage(for: codexWindow(minutes: 10_080, in: codexUsageSnapshot))
                )
            }

            if let openCodeUsageSnapshot = store.openCodeUsageSnapshot, !openCodeUsageSnapshot.isEmpty {
                openCodeUsageProviderRow(snapshot: openCodeUsageSnapshot)
            }
        }
    }

    func usageProviderRow(
        title: String,
        shortLabel: String,
        shortValue: Double?,
        longLabel: String,
        longValue: Double?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 108, alignment: .leading)

            usageMetricChip(label: shortLabel, value: shortValue)
            usageMetricChip(label: longLabel, value: longValue)
        }
    }

    func claudeUsageProviderRow(snapshot: ClaudeUsageSnapshot) -> some View {
        let windows = Array(snapshot.displayWindows.prefix(2))

        return HStack(alignment: .center, spacing: 10) {
            Text(claudeUsageTitle(for: snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 108, alignment: .leading)

            ForEach(windows, id: \.id) { item in
                usageMetricChip(label: item.label, value: displayedPercentage(for: item.window))
            }
        }
    }

    func claudeUsageTitle(for snapshot: ClaudeUsageSnapshot) -> String {
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            return "Claude · \(providerDisplayName)"
        }

        return "Claude"
    }

    func openCodeUsageProviderRow(snapshot: OpenCodeUsageSnapshot) -> some View {
        let windows = Array(snapshot.displayWindows.prefix(2))

        return HStack(alignment: .center, spacing: 10) {
            Text(openCodeUsageTitle(for: snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 108, alignment: .leading)

            ForEach(windows, id: \.id) { item in
                usageMetricChip(label: item.label, value: displayedPercentage(for: item.window))
            }
        }
    }

    func openCodeUsageTitle(for snapshot: OpenCodeUsageSnapshot) -> String {
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            return "OpenCode · \(providerDisplayName)"
        }

        return "OpenCode"
    }

    func usageMetricChip(label: String, value: Double?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.52))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 18, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))

                    Capsule(style: .continuous)
                        .fill(Color(red: 0.32, green: 0.96, blue: 0.38))
                        .frame(width: progressWidth(totalWidth: proxy.size.width, value: value))
                }
            }
            .frame(width: 56, height: 5)

            Text(value.map { "\((min(max($0, 0), 1) * 100).rounded(.toNearestOrAwayFromZero).formatted(.number.precision(.fractionLength(0))))%" } ?? "--")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 34, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func progressWidth(totalWidth: CGFloat, value: Double?) -> CGFloat {
        guard let value else {
            return 0
        }

        let normalized = min(max(value, 0), 1)
        if normalized == 0 {
            return 0
        }

        return max(totalWidth * normalized, 4)
    }

    func codexWindow(minutes: Int, in snapshot: CodexUsageSnapshot) -> CodexUsageWindow? {
        snapshot.windows.first { $0.windowMinutes == minutes }
    }

    func displayedPercentage(for window: ClaudeUsageWindow) -> Double {
        store.usageDisplayType.percentageValue(used: window.usedPercentage, remaining: window.leftPercentage)
    }

    func displayedPercentage(for window: OpenCodeUsageWindow) -> Double {
        store.usageDisplayType.percentageValue(used: window.usedPercentage, remaining: window.leftPercentage)
    }

    func displayedPercentage(for window: CodexUsageWindow?) -> Double? {
        guard let window else {
            return nil
        }

        return store.usageDisplayType.percentageValue(used: window.usedPercentage, remaining: window.leftPercentage)
    }

    func approvalCard(_ request: ApprovalRequest) -> some View {
        ApprovalPanelView(
            store: store,
            request: request,
            sessionTitle: approvalSessionTitle(for: request),
            primaryTitle: approvalPrimaryTitle(for: request),
            timestampText: relativeTimestamp(for: request.createdAt),
            diagnosticMessage: store.approvalDiagnosticMessage
        )
    }

    func questionCard(_ prompt: ClaudeQuestionPrompt) -> some View {
        QuestionPanelView(
            prompt: prompt,
            questionStore: store.questionInputStore,
            timestampText: relativeTimestamp(for: prompt.createdAt),
            onSubmit: store.submitQuestionAnswer,
            onDismiss: store.dismissQuestionPrompt
        )
    }

    func sessionCard(_ session: AgentSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                providerBadge(for: session.origin)

                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if session.activityState == .running, let runningDetail = session.runningDetail {
                    Text(runningDetail.displayTitle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }

                Text(relativeTimestamp(for: session.updatedAt))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.44))

                sessionStatusDot(session.activityState)
            }

            HStack(alignment: .center, spacing: 8) {
                if let cwd = session.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.44))
                        .lineLimit(1)
                } else if !session.detail.isEmpty {
                    Text(session.detail)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.44))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let focusTarget = session.focusTarget {
                    focusArrowButton(helpText: "Open \(focusTarget.displayName)") {
                        store.bringForward(focusTarget)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.09, blue: 0.10).opacity(0.98),
                            Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.20), lineWidth: 1)
        )
    }

    var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.panelTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text(store.panelSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Text("The island is ready to show Claude Code and Codex activity, approval requests, and focus targets when new work starts.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelSecondaryFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(panelSecondaryStroke, lineWidth: 1)
        )
    }

    func accessibilityPermissionCard(message: String) -> some View {
        accessibilityPermissionCallout(message: message, compact: false)
    }

    func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Diagnostic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                panelActionButton(title: "Resync Claude Hooks") {
                    store.resyncClaudeHooks()
                }
            }

            Text(message)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.34, green: 0.11, blue: 0.10).opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.95, green: 0.49, blue: 0.45).opacity(0.34), lineWidth: 1)
        )
    }

    func panelPill(title: String, tone: PanelPillTone = .neutral) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.background)
        )
    }

    func focusArrowButton(helpText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(helpText ?? "Bring forward")
    }

    func panelActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }


    func approvalSectionBlock<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        background: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    var permissionSettingsButton: some View {
        Button(action: store.openAccessibilitySettings) {
            Text("打开辅助功能设置")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    func accessibilityPermissionCallout(message: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Codex CLI 自动审批需要辅助功能权限")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Button(action: store.dismissAccessibilityPrompt) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }

            Text(message)
                .font(.system(size: compact ? 10 : 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            permissionSettingsButton
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.28, blue: 0.64).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                .stroke(Color(red: 0.46, green: 0.73, blue: 0.98).opacity(0.34), lineWidth: 1)
        )
    }

    func sessionStatusDot(_ state: IslandCodexActivityState) -> some View {
        Circle()
            .fill(color(for: state))
            .frame(width: 6, height: 6)
    }

    func color(for state: IslandCodexActivityState) -> Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.35)
        case .running:
            return Color(red: 0.33, green: 0.78, blue: 0.95)
        case .success:
            return Color(red: 0.18, green: 0.77, blue: 0.43)
        case .failure:
            return Color(red: 0.90, green: 0.24, blue: 0.22)
        }
    }

    func providerBadge(for origin: SessionOrigin) -> some View {
        Text(origin.provider.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(providerBadgeForeground(for: origin))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(providerBadgeBackground(for: origin))
            )
    }

    func providerBadgeForeground(for origin: SessionOrigin) -> Color {
        switch origin {
        case .claude:
            return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .codex:
            return Color(red: 0.02, green: 0.71, blue: 0.83)
        case .openCode:
            return Color(red: 0.30, green: 0.72, blue: 0.34)
        case .generic:
            return Color.white.opacity(0.72)
        }
    }

    func providerBadgeBackground(for origin: SessionOrigin) -> Color {
        switch origin {
        case .claude:
            return Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.14)
        case .codex:
            return Color(red: 0.02, green: 0.71, blue: 0.83).opacity(0.14)
        case .openCode:
            return Color(red: 0.30, green: 0.72, blue: 0.34).opacity(0.14)
        case .generic:
            return Color.white.opacity(0.08)
        }
    }

    var sessionCountLabel: String {
        let count = store.sessions.count
        let suffix = count == 1 ? "active" : "active"
        return "\(count) \(suffix)"
    }

    func approvalPrimaryTitle(for request: ApprovalRequest) -> String {
        if let contextTitle = request.contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contextTitle.isEmpty {
            return contextTitle
        }

        let commandSummary = request.commandSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commandSummary.isEmpty {
            return commandSummary
        }

        if let rationale = request.displayRationale {
            return rationale
        }

        return "Waiting for command detail"
    }

    func approvalSessionTitle(for request: ApprovalRequest) -> String {
        if let displayName = request.focusTarget?.displayName, !displayName.isEmpty {
            return displayName
        }

        return request.source.provider.displayName
    }

    func relativeTimestamp(for date: Date) -> String {
        let interval = max(Int(Date().timeIntervalSince(date)), 0)
        if interval < 5 {
            return "Just now"
        }
        if interval < 60 {
            return "\(interval)s ago"
        }

        let minutes = interval / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        return "\(hours)h ago"
    }

    func shouldPrioritizeQuestionPrompt(_ prompt: ClaudeQuestionPrompt) -> Bool {
        guard let approvalRequest = store.approvalRequest else {
            return true
        }

        return prompt.createdAt >= approvalRequest.createdAt
    }
}


private extension IslandRootView {
    var panelCardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.10, blue: 0.11).opacity(0.98),
                Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var panelCardStroke: Color {
        Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.18)
    }

    var panelSecondaryFill: Color {
        Color(red: 0.06, green: 0.07, blue: 0.08).opacity(0.94)
    }

    var panelSecondaryStroke: Color {
        Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.20)
    }

    enum PanelPillTone {
        case neutral
        case stale

        var foreground: Color {
            switch self {
            case .neutral:
                return Color.white.opacity(0.68)
            case .stale:
                return Color(red: 0.98, green: 0.79, blue: 0.43)
            }
        }

        var background: Color {
            switch self {
            case .neutral:
                return Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.12)
            case .stale:
                return Color(red: 0.98, green: 0.79, blue: 0.43).opacity(0.14)
            }
        }
    }

}

private struct TabCutShape: InsettableShape {
    var neckInset: CGFloat
    var shoulderDrop: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let x = rect.minX + insetAmount
        let y = rect.minY + insetAmount
        let width = rect.width - insetAmount * 2
        let height = rect.height - insetAmount * 2
        let radius = min(bottomRadius, height * 0.48, width * 0.2)
        let inset = min(neckInset, width * 0.24)
        let drop = min(shoulderDrop, height * 0.52)
        let leftNeckX = x + inset
        let rightNeckX = x + width - inset
        let bottomY = y + height
        let neckY = y + drop
        let shoulderEase = min(inset * 0.82, width * 0.16)
        let topEase = min(drop * 0.22, height * 0.12)
        let neckEase = min(drop * 0.28, height * 0.16)

        var path = Path()

        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + width, y: y))

        path.addCurve(
            to: CGPoint(x: rightNeckX, y: neckY),
            control1: CGPoint(x: x + width - shoulderEase, y: y + topEase),
            control2: CGPoint(x: rightNeckX, y: neckY - neckEase)
        )

        path.addLine(to: CGPoint(x: rightNeckX, y: bottomY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rightNeckX - radius, y: bottomY),
            control: CGPoint(x: rightNeckX, y: bottomY)
        )

        path.addLine(to: CGPoint(x: leftNeckX + radius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: leftNeckX, y: bottomY - radius),
            control: CGPoint(x: leftNeckX, y: bottomY)
        )

        path.addLine(to: CGPoint(x: leftNeckX, y: neckY))
        path.addCurve(
            to: CGPoint(x: x, y: y),
            control1: CGPoint(x: leftNeckX, y: neckY - neckEase),
            control2: CGPoint(x: x + shoulderEase, y: y + topEase)
        )

        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct IdleStatusGlyph: View {
    var body: some View {
        Image(systemName: "zzz")
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .frame(width: 18, height: 18)
    }
}

private struct RunningStatusGlyph: View {
    let animationAllowed: Bool

    var body: some View {
        BlueBreathingStatusGlyph(isAnimating: animationAllowed)
    }
}

private struct StaticRunningStatusGlyph: View {
    var body: some View {
        DotMatrixWaveStatusGlyph(isAnimating: false)
    }
}

private struct BlueBreathingStatusGlyph: NSViewRepresentable {
    let isAnimating: Bool

    func makeNSView(context: Context) -> BlueBreathingStatusNSView {
        let view = BlueBreathingStatusNSView()
        view.setAnimating(isAnimating)
        return view
    }

    func updateNSView(_ nsView: BlueBreathingStatusNSView, context: Context) {
        nsView.setAnimating(isAnimating)
    }
}

private final class BlueBreathingStatusNSView: NSView {
    private let baseLayer = CALayer()
    private let coreLayer = CALayer()
    private let ringLayer = CALayer()
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setupLayers()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override func layout() {
        super.layout()
        layoutGlyphLayers()
    }

    func setAnimating(_ shouldAnimate: Bool) {
        guard shouldAnimate != isAnimating else {
            return
        }
        isAnimating = shouldAnimate

        if shouldAnimate {
            startBreathingAnimation()
        } else {
            stopBreathingAnimation()
        }
    }

    private func setupLayers() {
        guard let layer else {
            return
        }

        layer.masksToBounds = false
        baseLayer.backgroundColor = NSColor(
            calibratedRed: 0.03,
            green: 0.22,
            blue: 0.52,
            alpha: 1
        ).cgColor
        coreLayer.backgroundColor = NSColor(
            calibratedRed: 0.0,
            green: 0.62,
            blue: 1.0,
            alpha: 1
        ).cgColor
        ringLayer.borderColor = NSColor(
            calibratedRed: 0.42,
            green: 0.86,
            blue: 1.0,
            alpha: 0.85
        ).cgColor
        ringLayer.borderWidth = 1

        [baseLayer, coreLayer, ringLayer].forEach {
            $0.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer.addSublayer($0)
        }

        stopBreathingAnimation()
    }

    private func layoutGlyphLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        setCircleFrame(baseLayer, side: 12, center: center)
        setCircleFrame(coreLayer, side: 9.5, center: center)
        setCircleFrame(ringLayer, side: 14, center: center)

        CATransaction.commit()
    }

    private func setCircleFrame(_ layer: CALayer, side: CGFloat, center: CGPoint) {
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.position = center
        layer.cornerRadius = side / 2
    }

    private func startBreathingAnimation() {
        coreLayer.removeAllAnimations()
        ringLayer.removeAllAnimations()

        coreLayer.opacity = 0.95
        ringLayer.opacity = 0.48
        coreLayer.transform = CATransform3DIdentity
        ringLayer.transform = CATransform3DIdentity

        coreLayer.add(basicAnimation(keyPath: "opacity", from: 0.42, to: 0.95), forKey: "opacity")
        coreLayer.add(basicAnimation(keyPath: "transform.scale", from: 0.72, to: 1.08), forKey: "scale")
        ringLayer.add(basicAnimation(keyPath: "opacity", from: 0.12, to: 0.48), forKey: "opacity")
        ringLayer.add(basicAnimation(keyPath: "transform.scale", from: 0.84, to: 1.14), forKey: "scale")
    }

    private func stopBreathingAnimation() {
        coreLayer.removeAllAnimations()
        ringLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coreLayer.opacity = 0.42
        ringLayer.opacity = 0.12
        coreLayer.transform = CATransform3DMakeScale(0.72, 0.72, 1)
        ringLayer.transform = CATransform3DMakeScale(0.84, 0.84, 1)
        CATransaction.commit()
    }

    private func basicAnimation(keyPath: String, from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 1.05
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

private struct SuccessStatusGlyph: View {
    var body: some View {
        SolidStatusGlyph(
            fill: Color(.sRGB, red: 0.0, green: 0.72, blue: 0.28, opacity: 1),
            symbol: "checkmark"
        )
    }
}

private struct TerminalStatusGlyph: View {
    let state: IslandCodexActivityState
    @State private var isAnimating = true

    var body: some View {
        Group {
            switch state {
            case .success:
                SuccessStatusGlyph()
            case .failure:
                DotMatrixFailureStatusGlyph(isAnimating: isAnimating)
            case .idle:
                IdleStatusGlyph()
            case .running:
                StaticRunningStatusGlyph()
            }
        }
        .task(id: state) {
            isAnimating = true
            try? await Task.sleep(nanoseconds: UInt64(1.25 * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            isAnimating = false
        }
    }
}

private final class BrandLogoImageCache: ObservableObject {
    private var imageByKey: [String: NSImage] = [:]

    func image(for logo: IslandBrandLogo, customLogoPath: String?) -> NSImage? {
        if logo == .custom, let customLogoPath {
            return cachedImage(key: "custom:\(customLogoPath)") {
                NSImage(contentsOfFile: customLogoPath)
            }
        }

        let resourceName = logo == .custom ? IslandBrandLogo.clawd.resourceName : logo.resourceName
        return cachedImage(key: "bundle:\(resourceName)") {
            guard let imageURL = Bundle.main.url(forResource: resourceName, withExtension: "png") else {
                return nil
            }
            return NSImage(contentsOf: imageURL)
        }
    }

    private func cachedImage(key: String, loader: () -> NSImage?) -> NSImage? {
        if let image = imageByKey[key] {
            return image
        }
        guard let image = loader() else {
            return nil
        }
        imageByKey[key] = image
        return image
    }
}

private struct SolidStatusGlyph: View {
    let fill: Color
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)

            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .black))
                .foregroundStyle(.white)
        }
        .frame(width: 15, height: 15)
    }
}
