import SwiftUI

struct IslandRootView: View {
    @ObservedObject var store: ProgressStore
    @State private var activePanelTransition: PanelTransition?
    @State private var panelTransitionCleanupTask: Task<Void, Never>?

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
            .shadow(color: .black.opacity(0), radius: 18, y: 8)
            .contentShape(islandShape)
            .onHover { isHovering in
                store.handlePanelHover(isHovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            activePanelTransition = nil
        }
        .onChange(of: store.displayMode) { oldValue, newValue in
            handleDisplayModeChange(from: oldValue, to: newValue)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if shouldHoldPanelBody {
            expandedBody
                .allowsHitTesting(store.displayMode == .panel)
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
        store.displayMode == .panel || store.hasInlineApprovalIsland || activePanelTransition != nil
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
            diagnosticMessage: store.approvalDiagnosticMessage
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

                if let approvalRequest = store.approvalRequest {
                    approvalCard(approvalRequest)
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
        .scrollClipDisabled()
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
        statusGlyph(for: store.codexStatus)
            .id(statusGlyphIdentity)
            .transition(.identity)
            .animation(nil, value: store.codexStatus)
            .animation(nil, value: store.runningGlyphAnimationSuppressed)
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
        if let imageURL = Bundle.main.url(forResource: store.selectedLogo.resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: imageURL) {
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
    private func statusGlyph(for state: IslandCodexActivityState) -> some View {
        switch state {
        case .idle:
            IdleStatusGlyph()
        case .running:
            if store.runningGlyphAnimationSuppressed {
                StaticRunningStatusGlyph()
            } else {
                RunningStatusGlyph()
            }
        case .success:
            SolidStatusGlyph(fill: Color(red: 96 / 255, green: 214 / 255, blue: 55 / 255), symbol: "checkmark")
        case .failure:
            SolidStatusGlyph(fill: Color(red: 220 / 255, green: 68 / 255, blue: 70 / 255), symbol: "xmark")
        }
    }

    private var statusGlyphIdentity: String {
        "\(store.codexStatus.rawValue)-\(store.runningGlyphAnimationSuppressed)"
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
                    shortValue: codexWindow(minutes: 300, in: codexUsageSnapshot)?.leftPercentage,
                    longLabel: "wk",
                    longValue: codexWindow(minutes: 10_080, in: codexUsageSnapshot)?.leftPercentage
                )
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
                .frame(width: 108, alignment: .leading)

            ForEach(windows, id: \.id) { item in
                usageMetricChip(label: item.label, value: item.window.leftPercentage)
            }
        }
    }

    func claudeUsageTitle(for snapshot: ClaudeUsageSnapshot) -> String {
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            return "Claude · \(providerDisplayName)"
        }

        return "Claude"
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

    func sessionCard(_ session: AgentSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                providerBadge(for: session.origin)

                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

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
        if let rationale = request.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rationale.isEmpty {
            return rationale
        }

        if request.commandSummary.isEmpty {
            return approvalConversationTitle(for: request) ?? "Waiting for command detail"
        }

        return request.commandSummary
    }

    func approvalConversationTitle(for request: ApprovalRequest) -> String? {
        if let sessionID = request.focusTarget?.sessionID {
            if let matchedSession = store.sessions.first(where: {
                $0.id == sessionID || $0.focusTarget?.sessionID == sessionID
            }) {
                return matchedSession.title
            }
        }

        if let displayName = request.focusTarget?.displayName,
           let matchedSession = store.sessions.first(where: {
               $0.focusTarget?.displayName == displayName
           }) {
            return matchedSession.title
        }

        if let matchedSession = store.sessions.first(where: { $0.origin == request.source }) {
            return matchedSession.title
        }

        return nil
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
    private let accentColor = Color(red: 42 / 255, green: 134 / 255, blue: 244 / 255)
    private let highlightColor = Color(red: 88 / 255, green: 196 / 255, blue: 1.0)
    private let coreColor = Color(red: 214 / 255, green: 238 / 255, blue: 1.0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let phase = pulsePhase(at: timeline.date)
            let secondaryPhase = pulsePhase(at: timeline.date.addingTimeInterval(-0.42))
            let coreGlow = 1.0 - phase
            let trailingGlow = 1.0 - secondaryPhase

            ZStack {
                pulseRing(progress: secondaryPhase, lineWidth: 1.15, baseOpacity: 0.30)
                pulseRing(progress: phase, lineWidth: 1.9, baseOpacity: 0.48)

                Circle()
                    .fill(highlightColor.opacity(0.10 + coreGlow * 0.08 + trailingGlow * 0.04))
                    .frame(width: 10.8, height: 10.8)
                    .blur(radius: 0.55)

                Circle()
                    .fill(accentColor)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: accentColor.opacity(0.44 + coreGlow * 0.18), radius: 5.4 + coreGlow * 0.8)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                coreColor.opacity(0.92),
                                highlightColor.opacity(0.70),
                                accentColor.opacity(0.14)
                            ],
                            center: .center,
                            startRadius: 0.1,
                            endRadius: 3.6
                        )
                    )
                    .frame(width: 4.3 + coreGlow * 0.45, height: 4.3 + coreGlow * 0.45)

                Circle()
                    .fill(.white.opacity(0.22 + coreGlow * 0.10))
                    .frame(width: 2.2, height: 2.2)
                    .blur(radius: 0.12)
                    .offset(x: -0.8, y: -0.8)
            }
            .frame(width: 15, height: 15)
        }
    }

    private func pulseRing(progress: Double, lineWidth: CGFloat, baseOpacity: Double) -> some View {
        return Circle()
            .stroke(highlightColor.opacity(baseOpacity * (1 - progress)), lineWidth: lineWidth)
            .frame(width: 6.5, height: 6.5)
            .scaleEffect(0.9 + progress * 1.55)
            .blur(radius: 0.08 + progress * 0.4)
    }

    private func pulsePhase(at date: Date) -> Double {
        let cycleDuration = 1.28
        let elapsed = date.timeIntervalSinceReferenceDate
        let normalized = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        return normalized
    }
}

private struct StaticRunningStatusGlyph: View {
    private let accentColor = Color(red: 42 / 255, green: 134 / 255, blue: 244 / 255)
    private let highlightColor = Color(red: 88 / 255, green: 196 / 255, blue: 1.0)

    var body: some View {
        ZStack {
            Circle()
                .stroke(highlightColor.opacity(0.18), lineWidth: 1.4)
                .frame(width: 10.5, height: 10.5)

            Circle()
                .fill(highlightColor.opacity(0.14))
                .frame(width: 8.5, height: 8.5)

            Circle()
                .fill(accentColor)
                .frame(width: 6.5, height: 6.5)
                .shadow(color: accentColor.opacity(0.30), radius: 2.8)
        }
        .frame(width: 15, height: 15)
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
