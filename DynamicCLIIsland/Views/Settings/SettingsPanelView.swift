import AppKit
import SwiftUI

private struct PlainJSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView, textView.string != text else {
            return
        }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }
    }
}

struct ProviderAuthEnvKeyRow: Identifiable, Equatable {
    let id: String
    let authEnvKey: String
}

private struct ProviderAuthEnvKeyFieldRow: View {
    let row: ProviderAuthEnvKeyRow
    let refreshToken: Int
    let onSubmit: (String, String) -> Void

    @State private var input = ""
    @State private var lastSubmitted = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(row.id)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 112, alignment: .leading)

            TextField(
                "",
                text: $input,
                prompt: Text("ANTHROPIC_AUTH_TOKEN")
                    .foregroundColor(.white.opacity(0.24))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .onAppear {
            syncFromRow(force: true)
        }
        .onChange(of: input) { _ in
            scheduleSubmit()
        }
        .onChange(of: row.authEnvKey) { _ in
            syncFromRow(force: false)
        }
        .onChange(of: refreshToken) { _ in
            syncFromRow(force: false)
        }
        .onDisappear {
            submit()
        }
    }

    private func syncFromRow(force: Bool) {
        let normalizedValue = normalized(row.authEnvKey)
        if force || normalized(input) == lastSubmitted {
            input = normalizedValue
            lastSubmitted = normalizedValue
        }
    }

    private func scheduleSubmit() {
        let snapshot = input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard snapshot == input else {
                return
            }
            submit()
        }
    }

    private func submit() {
        let normalizedInput = normalized(input)
        guard normalizedInput != lastSubmitted else {
            return
        }
        lastSubmitted = normalizedInput
        onSubmit(row.id, normalizedInput)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SettingsPanelView: View {
    struct ScreenOption: Identifiable {
        let id: String
        let title: String
        let action: () -> Void
    }

    @ObservedObject var store: ProgressStore
    let currentScreenTitle: () -> String
    let screenOptions: () -> [ScreenOption]
    let claudeUsageCommandJSONText: () -> String
    let onClaudeUsageCommandJSONSubmit: (String) -> Void
    let claudeSettingsJSONText: () -> String
    let onClaudeSettingsJSONSubmit: (String) -> Void
    let approvalDefaultFocus: () -> ApprovalDefaultFocusOption
    let onApprovalDefaultFocusSelected: (ApprovalDefaultFocusOption) -> Void
    let askUserQuestionHandlingMode: () -> AskUserQuestionHandlingMode
    let onAskUserQuestionHandlingModeSelected: (AskUserQuestionHandlingMode) -> Void
    let usageDisplayType: () -> UsageDisplayType
    let onUsageDisplayTypeSelected: (UsageDisplayType) -> Void
    let dotMatrixAnimationEnabled: () -> Bool
    let onDotMatrixAnimationEnabledChange: (Bool) -> Void
    let launchAtLoginEnabled: () -> Bool
    let onLaunchAtLoginChange: (Bool) -> Void
    let currentCustomLogoPath: () -> String?
    let onChooseCustomLogo: () -> Void
    let onClearCustomLogo: () -> Void
    let currentNotificationSoundTitle: (NotificationSoundKind) -> String
    let currentNotificationSoundPath: (NotificationSoundKind) -> String?
    let onChooseNotificationSound: (NotificationSoundKind) -> Void
    let onClearNotificationSound: (NotificationSoundKind) -> Void
    let onPreviewNotificationSound: (NotificationSoundKind) -> Void
    let providerAuthRows: () -> [ProviderAuthEnvKeyRow]
    let providerAuthRefreshToken: () -> Int
    let onProviderAuthEnvKeySubmit: (String, String) -> Void
    @State private var claudeUsageCommandInput = ""
    @State private var claudeUsageCommandLastSubmitted = ""
    @State private var claudeSettingsInput = ""
    @State private var claudeSettingsLastSubmitted = ""
    private let panelContentWidth: CGFloat = 780
    private let sectionCornerRadius: CGFloat = 18

    var body: some View {
        let authRows = providerAuthRows()

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                quickSettingsSection

                settingsSection(title: "usage-auth", systemImage: "key.horizontal") {
                    insetSurface(minHeight: 148, maxHeight: 188) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(authRows) { row in
                                    ProviderAuthEnvKeyFieldRow(
                                        row: row,
                                        refreshToken: providerAuthRefreshToken(),
                                        onSubmit: onProviderAuthEnvKeySubmit
                                    )
                                }
                            }
                            .padding(12)
                        }
                    }
                }

                settingsSection(title: "usage-cmd", systemImage: "terminal") {
                    jsonEditorSurface(
                        text: $claudeUsageCommandInput,
                        placeholder: "{\n  \"command\": null,\n  \"window\": \"day\",\n  \"valueKind\": \"usedPercentage\",\n  \"displayLabel\": \"day\",\n  \"timeoutSeconds\": 5\n}",
                        onChange: scheduleClaudeUsageCommandSubmit
                    )
                }

                settingsSection(title: "cc-paths", systemImage: "folder") {
                    jsonEditorSurface(
                        text: $claudeSettingsInput,
                        placeholder: "{\n  \"paths\": []\n}",
                        onChange: scheduleClaudeSettingsSubmit
                    )
                }
            }
            .padding(16)
            .frame(width: panelContentWidth, alignment: .leading)
        }
        .onAppear {
            claudeUsageCommandInput = claudeUsageCommandJSONText()
            claudeUsageCommandLastSubmitted = claudeUsageCommandInput.trimmingCharacters(in: .whitespacesAndNewlines)
            claudeSettingsInput = claudeSettingsJSONText()
            claudeSettingsLastSubmitted = claudeSettingsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: providerAuthRefreshToken()) { _ in
            let latestUsageCommand = claudeUsageCommandJSONText()
            let normalizedLatestUsageCommand = latestUsageCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if claudeUsageCommandInput.trimmingCharacters(in: .whitespacesAndNewlines) == claudeUsageCommandLastSubmitted {
                claudeUsageCommandInput = latestUsageCommand
                claudeUsageCommandLastSubmitted = normalizedLatestUsageCommand
            }

            let latestClaudeSettings = claudeSettingsJSONText()
            let normalizedLatestClaudeSettings = latestClaudeSettings.trimmingCharacters(in: .whitespacesAndNewlines)
            if claudeSettingsInput.trimmingCharacters(in: .whitespacesAndNewlines) == claudeSettingsLastSubmitted {
                claudeSettingsInput = latestClaudeSettings
                claudeSettingsLastSubmitted = normalizedLatestClaudeSettings
            }
        }
        .onDisappear {
            submitClaudeUsageCommand()
            submitClaudeSettings()
        }
        .frame(width: panelContentWidth, alignment: .leading)
        .background(
            ZStack {
                Color.black
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.035),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }

    private var quickSettingsSection: some View {
        VStack(spacing: 0) {
            fullWidthQuickSettingCell(title: "Sound", systemImage: "speaker.wave.2") {
                HStack(alignment: .center, spacing: 0) {
                    Toggle("", isOn: soundMutedBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(settingsAccent)
                        .scaleEffect(0.68)

                    Spacer(minLength: 72)
                    soundSettingControl(for: .approval, label: "Approval", width: 136)
                    Spacer(minLength: 20)
                    soundSettingControl(for: .completion, label: "Success", width: 136)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            sectionDivider

            quickSettingsRow(
                leading: {
                    quickSettingCell(title: "Screen", systemImage: "display") {
                        Menu {
                            ForEach(screenOptions()) { option in
                                Button(option.title) {
                                    option.action()
                                }
                            }
                        } label: {
                            pickerCapsule(title: currentScreenTitle(), width: 124)
                        }
                        .menuStyle(.borderlessButton)
                    }
                },
                trailing: {
                    quickSettingCell(title: "Logo", systemImage: "seal") {
                        Menu {
                            ForEach(availableLogos, id: \.rawValue) { logo in
                                Button(logo.menuTitle) {
                                    store.selectLogo(logo)
                                }
                            }

                            Divider()

                            Button("选择本地图片…") {
                                onChooseCustomLogo()
                            }

                            if currentCustomLogoPath() != nil {
                                Button(IslandBrandLogo.custom.menuTitle) {
                                    store.selectLogo(.custom)
                                }

                                Button("恢复内置 Logo") {
                                    store.selectLogo(.clawd)
                                }

                                Button("移除自定义 Logo") {
                                    onClearCustomLogo()
                                }
                            }
                        } label: {
                            pickerCapsule(title: store.selectedLogo.menuTitle, width: 116)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            )

            sectionDivider

            quickSettingsRow(
                leading: {
                    quickSettingCell(title: "approval-focus", systemImage: "command.circle") {
                        Menu {
                            ForEach(ApprovalDefaultFocusOption.allCases, id: \.rawValue) { option in
                                Button(option.menuTitle) {
                                    onApprovalDefaultFocusSelected(option)
                                }
                            }
                        } label: {
                            pickerCapsule(title: approvalDefaultFocus().menuTitle, width: 124)
                        }
                        .menuStyle(.borderlessButton)
                    }
                },
                trailing: {
                    quickSettingCell(title: "ask-user", systemImage: "text.bubble") {
                        Menu {
                            ForEach(AskUserQuestionHandlingMode.allCases, id: \.rawValue) { option in
                                Button(option.menuTitle) {
                                    onAskUserQuestionHandlingModeSelected(option)
                                }
                            }
                        } label: {
                            pickerCapsule(title: askUserQuestionHandlingMode().menuTitle, width: 148)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            )

            sectionDivider

            quickSettingsRow(
                leading: {
                    quickSettingCell(title: "usage-type", systemImage: "chart.bar") {
                        Menu {
                            ForEach(UsageDisplayType.allCases, id: \.rawValue) { option in
                                Button(option.menuTitle) {
                                    onUsageDisplayTypeSelected(option)
                                }
                            }
                        } label: {
                            pickerCapsule(title: usageDisplayType().menuTitle, width: 116)
                        }
                        .menuStyle(.borderlessButton)
                    }
                },
                trailing: {
                    quickSettingCell(title: "Launch", systemImage: "power") {
                        Toggle("", isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(settingsAccent)
                            .scaleEffect(0.68)
                    }
                }
            )

            sectionDivider

            fullWidthQuickSettingCell(title: "Animation", systemImage: "circle.grid.3x3") {
                Toggle("", isOn: dotMatrixAnimationBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(settingsAccent)
                    .scaleEffect(0.68)
            }
        }
        .background(sectionSurfaceBackground(cornerRadius: sectionCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    private func soundSettingControl(for kind: NotificationSoundKind, label: String, width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: soundIconName(for: kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(settingsAccent)

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))

            soundMenu(for: kind, width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func soundMenu(for kind: NotificationSoundKind, width: CGFloat = 168) -> some View {
        Menu {
            Button("选择本地 mp3…") {
                onChooseNotificationSound(kind)
            }

            Button("试听") {
                onPreviewNotificationSound(kind)
            }

            if currentNotificationSoundPath(kind) != nil {
                Divider()

                Button("恢复默认提示音") {
                    onClearNotificationSound(kind)
                }
            }
        } label: {
            pickerCapsule(title: currentNotificationSoundTitle(kind), width: width)
        }
        .menuStyle(.borderlessButton)
    }

    private func soundIconName(for kind: NotificationSoundKind) -> String {
        switch kind {
        case .approval:
            return "bell.badge"
        case .completion:
            return "checkmark.circle"
        }
    }

    private func quickSettingsRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1)

            trailing()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quickSettingCell<Accessory: View>(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            quickSettingLabel(title: title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)

            accessory()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func fullWidthQuickSettingCell<Accessory: View>(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            quickSettingLabel(title: title, systemImage: systemImage)
                .frame(width: 96, alignment: .leading)

            accessory()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func settingsSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsLabel(title: title, systemImage: systemImage)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sectionSurfaceBackground(cornerRadius: sectionCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    private func settingsLabel(title: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settingsAccent)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    private func quickSettingLabel(title: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(settingsAccent)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func insetSurface<Content: View>(
        minHeight: CGFloat,
        maxHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(insetSurfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(insetSurfaceBorder, lineWidth: 1)
            )
    }

    private func jsonEditorSurface(
        text: Binding<String>,
        placeholder: String,
        onChange: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.22))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            PlainJSONEditor(text: text)
                .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
                .onChange(of: text.wrappedValue) { _ in
                    onChange()
                }
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(insetSurfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(insetSurfaceBorder, lineWidth: 1)
        )
    }

    private func pickerCapsule(title: String, width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(controlFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(controlStroke, lineWidth: 1)
        )
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
    }

    private func sectionSurfaceBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.085, green: 0.09, blue: 0.10).opacity(0.98),
                        Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var settingsAccent: Color {
        Color(red: 0.32, green: 0.96, blue: 0.38)
    }

    private var sectionBorder: Color {
        Color.white.opacity(0.06)
    }

    private var dividerColor: Color {
        Color.white.opacity(0.055)
    }

    private var insetSurfaceFill: Color {
        Color.white.opacity(0.04)
    }

    private var insetSurfaceBorder: Color {
        Color.white.opacity(0.07)
    }

    private var controlFill: Color {
        Color.white.opacity(0.06)
    }

    private var controlStroke: Color {
        Color.white.opacity(0.075)
    }

    private var soundMutedBinding: Binding<Bool> {
        Binding(
            get: { !store.isSoundMuted },
            set: { isEnabled in
                if store.isSoundMuted == isEnabled {
                    store.toggleSoundMuted()
                }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled() },
            set: { isEnabled in
                onLaunchAtLoginChange(isEnabled)
            }
        )
    }

    private var dotMatrixAnimationBinding: Binding<Bool> {
        Binding(
            get: { dotMatrixAnimationEnabled() },
            set: { isEnabled in
                onDotMatrixAnimationEnabledChange(isEnabled)
            }
        )
    }

    private var availableLogos: [IslandBrandLogo] {
        [.hermit, .clawd, .zenmux, .claudeCodeColor, .codexColor, .codexMono, .openAI]
    }

    private func submitClaudeSettings() {
        let normalizedInput = claudeSettingsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedInput != claudeSettingsLastSubmitted else {
            return
        }
        claudeSettingsLastSubmitted = normalizedInput
        if normalizedInput != claudeSettingsJSONText().trimmingCharacters(in: .whitespacesAndNewlines) {
            onClaudeSettingsJSONSubmit(normalizedInput)
        }
    }

    private func submitClaudeUsageCommand() {
        let normalizedInput = claudeUsageCommandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedInput != claudeUsageCommandLastSubmitted else {
            return
        }
        claudeUsageCommandLastSubmitted = normalizedInput
        if normalizedInput != claudeUsageCommandJSONText().trimmingCharacters(in: .whitespacesAndNewlines) {
            onClaudeUsageCommandJSONSubmit(normalizedInput)
        }
    }

    private func scheduleClaudeSettingsSubmit() {
        let snapshot = claudeSettingsInput
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard snapshot == claudeSettingsInput else {
                return
            }
            submitClaudeSettings()
        }
    }

    private func scheduleClaudeUsageCommandSubmit() {
        let snapshot = claudeUsageCommandInput
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard snapshot == claudeUsageCommandInput else {
                return
            }
            submitClaudeUsageCommand()
        }
    }
}
