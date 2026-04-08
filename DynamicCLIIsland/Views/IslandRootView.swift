import SwiftUI

struct IslandRootView: View {
    @ObservedObject var store: ProgressStore

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                islandShape
                    .fill(backgroundFill)
                    .overlay(
                        islandShape
                            .strokeBorder(borderColor, lineWidth: 1)
                    )

                Group {
                    if store.displayMode == .panel {
                        expandedBody
                    } else if store.hasInlineApprovalIsland, let approvalRequest = store.approvalRequest {
                        inlineApprovalBody(approvalRequest)
                    } else if store.displayMode == .island {
                        compactBody
                    } else {
                        EmptyView()
                    }
                }
                .animation(nil, value: store.displayMode)
                .animation(nil, value: store.hasInlineApprovalIsland)
                .animation(nil, value: store.approvalRequest?.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if store.displayMode != .panel && !store.hasInlineApprovalIsland {
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
        store.isHiddenMode ? Color.black.opacity(0.001) : .black
    }

    private var borderColor: Color {
        if store.isHiddenMode || store.isExpanded {
            return .clear
        }

        return Color.white.opacity(0.04)
    }

    private var compactBody: some View {
        islandHeader
            .frame(width: store.windowSize.width, height: store.windowSize.height, alignment: .center)
    }

    private var compactHorizontalPadding: CGFloat { 36 }

    private var railWidth: CGFloat {
        max((store.windowSize.width - store.cameraGapWidth - compactHorizontalPadding * 2) / 2, 0)
    }


    private func inlineApprovalBody(_ request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            islandHeader

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Approval Needed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    pendingApprovalBadge

                    Spacer(minLength: 8)

                    Button(action: store.collapseInlineApproval) {
                        Text("收起")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }

                Text(request.commandSummary.isEmpty ? "Waiting for command detail" : request.commandSummary)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let rationale = request.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let approvalDiagnosticMessage = store.approvalDiagnosticMessage {
                    approvalDiagnosticCallout(approvalDiagnosticMessage, compact: true)
                }

                HStack(spacing: 10) {
                    approvalActionButton(title: "Reject", fill: Color(red: 0.84, green: 0.24, blue: 0.22)) {
                        store.rejectApproval()
                    }

                    approvalActionButton(title: "Accept", fill: Color(red: 0.17, green: 0.70, blue: 0.33)) {
                        store.acceptApproval()
                    }
                }

                approvalActionButton(title: "Accept All", fill: Color.white.opacity(0.14), isFullWidth: true) {
                    store.acceptAllApprovals()
                }
            }
            .padding(.horizontal, 36)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

                if !store.sessions.isEmpty {
                    usageSection
                    sessionsSectionDivider
                    sessionsSectionHeader
                }

                if let accessibilityPermissionMessage = store.accessibilityPermissionMessage {
                    accessibilityPermissionCard(message: accessibilityPermissionMessage)
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
            bottomRadius: store.isExpanded ? 24 : 20
        )
    }

    @ViewBuilder
    private var compactBrandIcon: some View {
        brandLogoImage(size: 18)
    }

    @ViewBuilder
    private var compactStatusIcon: some View {
        switch store.codexStatus {
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

}

private extension IslandRootView {
    var panelTopBar: some View {
        ZStack {
            HStack(spacing: 0) {
                compactBrandIcon
                    .frame(width: 18, height: 18)

                Spacer(minLength: 0)

                compactStatusIcon
                    .frame(width: 18, height: 18)
            }
        }
        .frame(height: 38)
    }

    var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(providerUsageRows) { row in
                usageRow(row)
            }
        }
        .padding(.bottom, 0)
    }

    var sessionsSectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
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

    func approvalCard(_ request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Approval Request")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                pendingApprovalBadge

                Spacer(minLength: 8)

                Text(relativeTimestamp(for: request.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            Text(request.commandSummary.isEmpty ? "Waiting for command detail" : request.commandSummary)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(3)

            if let rationale = request.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(3)
            }

            if let approvalDiagnosticMessage = store.approvalDiagnosticMessage {
                approvalDiagnosticCallout(approvalDiagnosticMessage, compact: false)
            }

            if let focusTarget = request.focusTarget {
                HStack {
                    Text("Target: \(focusTarget.displayName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))

                    Spacer(minLength: 8)

                    panelActionButton(title: "Bring Forward") {
                        store.bringForward(focusTarget)
                    }
                }
            }

            Text("Awaiting action in the active CLI session. Return to Claude Code or Codex to allow, deny, or allow all.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.15, green: 0.19, blue: 0.26).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.33, green: 0.78, blue: 0.95).opacity(0.24), lineWidth: 1)
        )
    }

    var pendingApprovalBadge: some View {
        Text("Pending")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(red: 0.33, green: 0.78, blue: 0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.33, green: 0.78, blue: 0.95).opacity(0.14))
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
                    focusArrowButton {
                        store.bringForward(focusTarget)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
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
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
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

    func panelActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    func focusArrowButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }

    func approvalActionButton(
        title: String,
        fill: Color,
        isFullWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: isFullWidth ? .infinity : nil)
    }

    func approvalDiagnosticCallout(_ message: String, compact: Bool) -> some View {
        Text(message)
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundStyle(Color(red: 0.57, green: 0.83, blue: 1.0))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.20, blue: 0.33).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .stroke(Color(red: 0.57, green: 0.83, blue: 1.0).opacity(0.24), lineWidth: 1)
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
                        .fill(Color.white.opacity(0.12))
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

    var providerUsageRows: [ProviderUsageRow] {
        let grouped = Dictionary(grouping: store.sessions, by: \.origin)
        let preferredOrder: [SessionOrigin] = [.claude, .codex, .generic]

        return preferredOrder.compactMap { origin in
            guard let sessions = grouped[origin], !sessions.isEmpty else {
                return nil
            }

            return ProviderUsageRow(
                origin: origin,
                shortWindow: activityShare(for: sessions, recentInterval: 5 * 60 * 60),
                longWindow: activityShare(for: sessions, recentInterval: 7 * 24 * 60 * 60)
            )
        }
    }

    func activityShare(for sessions: [AgentSessionSnapshot], recentInterval: TimeInterval) -> Double {
        let now = Date()
        let recentCount = sessions.filter { now.timeIntervalSince($0.updatedAt) <= recentInterval }.count
        guard !sessions.isEmpty else {
            return 0
        }

        return Double(recentCount) / Double(sessions.count)
    }

    func usageRow(_ row: ProviderUsageRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(row.origin.provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 52, alignment: .leading)

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {
                usageMetric(label: "5h", value: row.shortWindow)
                    .frame(width: 82, alignment: .leading)

                Text("·")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.3))

                usageMetric(label: "wk", value: row.longWindow)
                    .frame(width: 82, alignment: .leading)
            }
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func usageMetric(label: String, value: Double) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.44))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.07))

                    Capsule(style: .continuous)
                        .fill(Color(red: 0.13, green: 0.77, blue: 0.37))
                        .frame(width: max(proxy.size.width * value, value > 0 ? 4 : 0))
                }
            }
            .frame(width: 48, height: 4)

            Text(percentText(value))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
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
                return Color.white.opacity(0.07)
            case .stale:
                return Color(red: 0.98, green: 0.79, blue: 0.43).opacity(0.14)
            }
        }
    }

    struct ProviderUsageRow: Identifiable {
        let origin: SessionOrigin
        let shortWindow: Double
        let longWindow: Double

        var id: SessionOrigin { origin }

        init(origin: SessionOrigin, shortWindow: Double, longWindow: Double) {
            self.origin = origin
            self.shortWindow = shortWindow
            self.longWindow = longWindow
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
    @State private var isAnimating = false
    private let accentColor = Color(red: 50 / 255, green: 150 / 255, blue: 1.0)

    var body: some View {
        ZStack {
            Circle()
                .stroke(accentColor.opacity(0.24), lineWidth: 2.2)

            Circle()
                .trim(from: 0.12, to: 0.72)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
        }
        .frame(width: 15, height: 15)
        .animation(.linear(duration: 0.95).repeatForever(autoreverses: false), value: isAnimating)
        .onAppear {
            isAnimating = true
        }
    }
}

private struct StaticRunningStatusGlyph: View {
    private let accentColor = Color(red: 50 / 255, green: 150 / 255, blue: 1.0)

    var body: some View {
        ZStack {
            Circle()
                .stroke(accentColor.opacity(0.24), lineWidth: 2.2)

            Circle()
                .trim(from: 0.12, to: 0.72)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
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
