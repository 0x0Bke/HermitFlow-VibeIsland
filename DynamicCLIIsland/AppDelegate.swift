import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private final class IslandKeyboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

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

private struct ProviderAuthEnvKeyRow: Identifiable, Equatable {
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
                    .foregroundStyle(.white.opacity(0.24))
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
        .onChange(of: input) { _, _ in
            scheduleSubmit()
        }
        .onChange(of: row.authEnvKey) { _, _ in
            syncFromRow(force: false)
        }
        .onChange(of: refreshToken) { _, _ in
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

private struct SettingsPanelView: View {
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
    let usageDisplayType: () -> UsageDisplayType
    let onUsageDisplayTypeSelected: (UsageDisplayType) -> Void
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
        .onChange(of: providerAuthRefreshToken()) { _, _ in
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
                }
            )
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
                .onChange(of: text.wrappedValue) { _, _ in
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum ScreenPlacementMode: Equatable {
        case automatic
        case fixed(CGDirectDisplayID)
    }

    private let environment = AppEnvironment()
    private var store: ProgressStore { environment.progressStore }
    private var window: NSWindow?
    private var isPositioningWindow = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var settingsPanel: NSWindow?
    private var providerConfigMonitor: DispatchSourceFileSystemObject?
    private var providerConfigMonitorFileDescriptor: CInt = -1
    private var providerConfigPollTimer: Timer?
    private var providerConfigLastKnownModificationDate: Date?
    private var providerConfigRefreshToken = 0
    private var visibilityMenuItem: NSMenuItem?
    private var screenMenuItem: NSMenuItem?
    private var automaticScreenMenuItem: NSMenuItem?
    private var fixedScreenMenuItems: [NSMenuItem] = []
    private var hermitLogoMenuItem: NSMenuItem?
    private var clawdLogoMenuItem: NSMenuItem?
    private var zenMuxLogoMenuItem: NSMenuItem?
    private var claudeCodeLogoMenuItem: NSMenuItem?
    private var codexColorLogoMenuItem: NSMenuItem?
    private var codexMonoLogoMenuItem: NSMenuItem?
    private var openAILogoMenuItem: NSMenuItem?
    private var resyncClaudeHooksMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var approvalPreviewMenuItem: NSMenuItem?
    private let screenPlacementModeDefaultsKey = "HermitFlow.screenPlacementMode"
    private let fixedScreenIDDefaultsKey = "HermitFlow.fixedScreenID"
    private let debugLogURL = URL(fileURLWithPath: "/tmp/hermitflow-approval-debug.log")
    private let updateChecker = GitHubReleaseUpdateChecker()
    private let updateDownloader = GitHubReleaseAssetDownloader()
    private var mainWindowWasVisibleBeforeSettings = false
    private var isCheckingForUpdates = false
    private var isDownloadingUpdate = false

    private var windowCoordinator: IslandWindowCoordinator { environment.windowCoordinator }
    private var windowSizingCoordinator: WindowSizingCoordinator { environment.windowSizingCoordinator }
    private var screenPlacementCoordinator: ScreenPlacementCoordinator { environment.screenPlacementCoordinator }
    private var statusItemCoordinator: StatusItemCoordinator { environment.statusItemCoordinator }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createWindow()
        wireStoreActions()
        createStatusItem()
        registerScreenObservers()
        registerOutsideClickMonitors()
        environment.appBootstrapper.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let settingsPanel else {
            return false
        }

        if settingsPanel.isMiniaturized {
            settingsPanel.deminiaturize(nil)
        }

        settingsPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func createWindow() {
        let size = store.windowSize
        let window = IslandKeyboardWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.ignoresMouseEvents = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        let rootView = IslandRootView(store: store)
        let hostingView = IslandHostingView(rootView: rootView)
        windowCoordinator.configure(window: window, with: hostingView)
        position(window: window, size: size, animation: nil)
        windowCoordinator.makeKeyAndOrderFront()
        windowCoordinator.orderFront()
        position(window: window, size: size, animation: nil)

        store.onWindowSizeChange = { [weak self] newSize in
            guard let self, !self.isPositioningWindow else {
                return
            }

            self.position(
                window: window,
                size: newSize,
                animation: self.windowAnimation(for: self.store.windowResizeAnimation)
            )
        }

        self.window = window
    }

    private func wireStoreActions() {
        store.onOpenSettingsPanel = { [weak self] in
            self?.presentSettingsPanel()
        }
    }

    private func presentSettingsPanel() {
        mainWindowWasVisibleBeforeSettings = false
        store.showIsland()
        NSApp.setActivationPolicy(.regular)
        keepIslandVisibleForSettings()

        let rootView = makeSettingsPanelView()

        if let settingsPanel {
            if settingsPanel.isMiniaturized {
                settingsPanel.deminiaturize(nil)
            }
            settingsPanel.contentView = NSHostingView(rootView: rootView)
            settingsPanel.makeKeyAndOrderFront(nil)
            keepIslandVisibleForSettings()
            NSApp.activate(ignoringOtherApps: true)
            startProviderConfigSync()
            return
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 812, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Settings"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = true
        panel.level = .normal
        panel.collectionBehavior = []
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: rootView)
        positionSettingsPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        keepIslandVisibleForSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
        startProviderConfigSync()
    }

    private func makeSettingsPanelView() -> SettingsPanelView {
        SettingsPanelView(
            store: store,
            currentScreenTitle: { [weak self] in
                self?.currentScreenSelectionTitle ?? "Auto"
            },
            screenOptions: { [weak self] in
                self?.settingsScreenOptions ?? []
            },
            claudeUsageCommandJSONText: { [weak self] in
                self?.claudeUsageCommandJSONText ?? ""
            },
            onClaudeUsageCommandJSONSubmit: { [weak self] value in
                self?.updateClaudeUsageCommandJSON(from: value)
            },
            claudeSettingsJSONText: { [weak self] in
                self?.claudeSettingsJSONText ?? ""
            },
            onClaudeSettingsJSONSubmit: { [weak self] value in
                self?.updateClaudeSettingsJSON(from: value)
            },
            approvalDefaultFocus: { [weak self] in
                self?.store.approvalDefaultFocus ?? .accept
            },
            onApprovalDefaultFocusSelected: { [weak self] option in
                self?.store.setApprovalDefaultFocus(option)
            },
            usageDisplayType: { [weak self] in
                self?.store.usageDisplayType ?? .remaining
            },
            onUsageDisplayTypeSelected: { [weak self] option in
                self?.store.setUsageDisplayType(option)
            },
            currentNotificationSoundTitle: { [weak self] kind in
                self?.currentNotificationSoundTitle(for: kind) ?? "默认提示音"
            },
            currentNotificationSoundPath: { [weak self] kind in
                self?.notificationSoundPath(for: kind)
            },
            onChooseNotificationSound: { [weak self] kind in
                self?.chooseCustomNotificationSound(for: kind)
            },
            onClearNotificationSound: { [weak self] kind in
                self?.store.setCustomNotificationSoundPath(nil, for: kind)
            },
            onPreviewNotificationSound: { [weak self] kind in
                switch kind {
                case .approval:
                    self?.environment.appStore.runtimeStore.notificationSoundPlayer.playApprovalSound()
                case .completion:
                    self?.environment.appStore.runtimeStore.notificationSoundPlayer.playCompletionSound()
                }
            },
            providerAuthRows: { [weak self] in
                self?.claudeProviderAuthRows ?? []
            },
            providerAuthRefreshToken: { [weak self] in
                self?.providerConfigRefreshToken ?? 0
            },
            onProviderAuthEnvKeySubmit: { [weak self] providerID, value in
                self?.updateClaudeProviderUsageAuthEnvKey(providerID: providerID, value: value)
            }
        )
    }

    private func closeSettingsPanel() {
        settingsPanel?.close()
    }

    private func currentNotificationSoundTitle(for kind: NotificationSoundKind) -> String {
        guard let path = notificationSoundPath(for: kind), !path.isEmpty else {
            return "默认提示音"
        }

        return "Custom"
    }

    private func notificationSoundPath(for kind: NotificationSoundKind) -> String? {
        switch kind {
        case .approval:
            return store.customApprovalNotificationSoundPath
        case .completion:
            return store.customCompletionNotificationSoundPath
        }
    }

    private func chooseCustomNotificationSound(for kind: NotificationSoundKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.mp3]
        panel.title = kind == .approval ? "选择审批提示音" : "选择完成提示音"
        panel.message = kind == .approval
            ? "选择一个本地 mp3 文件作为审批提示音。"
            : "选择一个本地 mp3 文件作为完成提示音。"

        if panel.runModal() == .OK, let url = panel.url {
            importCustomNotificationSound(from: url, for: kind)
        }
    }

    private func importCustomNotificationSound(from sourceURL: URL, for kind: NotificationSoundKind) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: FilePaths.notificationSoundsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let destinationURL = kind.customFileURL
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            UserDefaults.standard.removeObject(forKey: kind.customSoundBookmarkDefaultsKey)
            store.setCustomNotificationSoundPath(destinationURL.path, for: kind)
        } catch {
            #if DEBUG
            print("Failed to import notification sound: \(error)")
            #endif
        }
    }

    private func positionSettingsPanel(_ panel: NSWindow) {
        let panelSize = panel.frame.size
        let referenceFrame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let visibleFrame = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let originX = referenceFrame.midX - panelSize.width / 2
        let preferredGap: CGFloat = 72
        let minimumBottomMargin: CGFloat = 12
        let preferredY = referenceFrame.minY - panelSize.height - preferredGap
        let minimumY = visibleFrame.minY + minimumBottomMargin
        let originY = max(preferredY, minimumY)
        panel.setFrameOrigin(NSPoint(x: originX.rounded(), y: originY.rounded()))
    }

    private func keepIslandVisibleForSettings() {
        guard let window else {
            return
        }

        position(window: window, size: store.windowSize, animation: nil)
        windowCoordinator.orderFront()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.settingsPanel != nil || NSApp.activationPolicy() == .regular else {
                return
            }

            self.position(window: window, size: self.store.windowSize, animation: nil)
            self.windowCoordinator.orderFront()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === settingsPanel else {
            return
        }

        stopProviderConfigSync()
        mainWindowWasVisibleBeforeSettings = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func createStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self

        let visibilityMenuItem = NSMenuItem(
            title: "Show/Hide Island",
            action: #selector(toggleWindowVisibility),
            keyEquivalent: ""
        )
        visibilityMenuItem.target = self
        menu.addItem(visibilityMenuItem)

        menu.addItem(.separator())

        let screenMenuItem = NSMenuItem(title: "Screen", action: nil, keyEquivalent: "")
        let screenSubmenu = NSMenu(title: "Screen")

        let automaticScreenMenuItem = NSMenuItem(
            title: "Auto Follow Active Screen",
            action: #selector(selectAutomaticScreenPlacement),
            keyEquivalent: ""
        )
        automaticScreenMenuItem.target = self
        screenSubmenu.addItem(automaticScreenMenuItem)
        menu.setSubmenu(screenSubmenu, for: screenMenuItem)
        menu.addItem(screenMenuItem)

        menu.addItem(.separator())

        let logoMenuItem = NSMenuItem(title: "Left Logo", action: nil, keyEquivalent: "")
        let logoSubmenu = NSMenu(title: "Left Logo")

        let hermitLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.hermit.menuTitle,
            action: #selector(selectHermitLogo),
            keyEquivalent: ""
        )
        hermitLogoMenuItem.target = self
        logoSubmenu.addItem(hermitLogoMenuItem)

        let clawdLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.clawd.menuTitle,
            action: #selector(selectClawdLogo),
            keyEquivalent: ""
        )
        clawdLogoMenuItem.target = self
        logoSubmenu.addItem(clawdLogoMenuItem)

        let claudeCodeLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.claudeCodeColor.menuTitle,
            action: #selector(selectClaudeCodeLogo),
            keyEquivalent: ""
        )
        claudeCodeLogoMenuItem.target = self
        logoSubmenu.addItem(claudeCodeLogoMenuItem)

        let codexColorLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.codexColor.menuTitle,
            action: #selector(selectCodexColorLogo),
            keyEquivalent: ""
        )
        codexColorLogoMenuItem.target = self
        logoSubmenu.addItem(codexColorLogoMenuItem)

        let codexMonoLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.codexMono.menuTitle,
            action: #selector(selectCodexMonoLogo),
            keyEquivalent: ""
        )
        codexMonoLogoMenuItem.target = self
        logoSubmenu.addItem(codexMonoLogoMenuItem)

        let openAILogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.openAI.menuTitle,
            action: #selector(selectOpenAILogo),
            keyEquivalent: ""
        )
        openAILogoMenuItem.target = self
        logoSubmenu.addItem(openAILogoMenuItem)

        let zenMuxLogoMenuItem = NSMenuItem(
            title: ProgressStore.BrandLogo.zenmux.menuTitle,
            action: #selector(selectZenMuxLogo),
            keyEquivalent: ""
        )
        zenMuxLogoMenuItem.target = self
        logoSubmenu.addItem(zenMuxLogoMenuItem)

        menu.setSubmenu(logoSubmenu, for: logoMenuItem)
        menu.addItem(logoMenuItem)

        menu.addItem(.separator())

        let resyncClaudeHooksMenuItem = NSMenuItem(
            title: "Resync Claude Hooks",
            action: #selector(resyncClaudeHooks),
            keyEquivalent: ""
        )
        resyncClaudeHooksMenuItem.target = self
        menu.addItem(resyncClaudeHooksMenuItem)

        menu.addItem(.separator())

        let checkForUpdatesMenuItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesMenuItem.target = self
        menu.addItem(checkForUpdatesMenuItem)

        menu.addItem(.separator())

//        审批状态测试入口
//        let approvalPreviewMenuItem = NSMenuItem(
//            title: "Preview Approval UI",
//            action: #selector(toggleApprovalPreview),
//            keyEquivalent: ""
//        )
//        approvalPreviewMenuItem.target = self
//        menu.addItem(approvalPreviewMenuItem)
//
//        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItemCoordinator.attach(statusItem: statusItem)
        if let button = statusItem.button {
            statusItemCoordinator.setImage(makeStatusBarImage())
            button.imagePosition = .imageOnly
            statusItemCoordinator.setToolTip("Dynamic CLI Island")
        }

        statusItemCoordinator.setMenu(menu)
        self.statusItem = statusItem
        self.visibilityMenuItem = visibilityMenuItem
        self.screenMenuItem = screenMenuItem
        self.automaticScreenMenuItem = automaticScreenMenuItem
        self.hermitLogoMenuItem = hermitLogoMenuItem
        self.clawdLogoMenuItem = clawdLogoMenuItem
        self.zenMuxLogoMenuItem = zenMuxLogoMenuItem
        self.claudeCodeLogoMenuItem = claudeCodeLogoMenuItem
        self.codexColorLogoMenuItem = codexColorLogoMenuItem
        self.codexMonoLogoMenuItem = codexMonoLogoMenuItem
        self.openAILogoMenuItem = openAILogoMenuItem
        self.resyncClaudeHooksMenuItem = resyncClaudeHooksMenuItem
        self.checkForUpdatesMenuItem = checkForUpdatesMenuItem
//        审批状态测试入口
//        self.approvalPreviewMenuItem = approvalPreviewMenuItem
        rebuildScreenMenu()
        updateMenuState()
    }

    private func makeStatusBarImage() -> NSImage? {
        if let imageURL = Bundle.main.url(forResource: "claudecode-bar", withExtension: "png"),
           let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Dynamic CLI Island")
    }

    private func position(
        window: NSWindow,
        size: CGSize,
        animation: WindowSizingCoordinator.FrameAnimation?,
        preferMouseScreen: Bool = false
    ) {
        isPositioningWindow = true
        defer { isPositioningWindow = false }

        guard let screen = placementScreen(for: window, preferMouseScreen: preferMouseScreen) else {
            return
        }

        syncCompactMetrics(for: screen)
        let resolvedSize = store.windowSize
        let leftAuxArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightAuxArea = screen.auxiliaryTopRightArea ?? .zero
        let hasCameraHousing = !leftAuxArea.isEmpty || !rightAuxArea.isEmpty
        let topInset = topInsetForWindow(size: resolvedSize, hasCameraHousing: hasCameraHousing)
        let targetFrame = screenPlacementCoordinator.centeredFrame(
            for: screen,
            windowSize: resolvedSize,
            topInset: topInset
        )
        updatePanelHoverArming(for: targetFrame)

        windowSizingCoordinator.applyFrame(targetFrame, to: window, display: true, animation: animation)
    }

    private func windowAnimation(
        for resizeAnimation: PresentationStore.WindowResizeAnimation
    ) -> WindowSizingCoordinator.FrameAnimation? {
        switch resizeAnimation {
        case .none:
            return nil
        case .panelTransition:
            return WindowSizingCoordinator.FrameAnimation(
                duration: store.panelTransition.windowDuration,
                timingFunctionName: .easeInEaseOut
            )
        }
    }

    private func updatePanelHoverArming(for targetFrame: NSRect) {
        guard store.isExpanded else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if targetFrame.contains(mouseLocation) {
            store.armPanelHoverMonitoring()
        }
    }

    private func topInsetForWindow(size: CGSize, hasCameraHousing: Bool) -> CGFloat {
        if !store.isExpanded {
            return hasCameraHousing ? -2 : 0
        }

        return hasCameraHousing ? -1 : 0
    }

    private func syncCompactMetrics(for screen: NSScreen) {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let leftAuxArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightAuxArea = screen.auxiliaryTopRightArea ?? .zero
        let displayID = screen.displayID
        let backingScaleFactor = max(screen.backingScaleFactor, 1)
        let renderedScreenWidth = screen.frame.width * backingScaleFactor
        let isExternalDisplay = displayID.map { !isBuiltInDisplay($0) } ?? false
        let hasCameraHousing = !leftAuxArea.isEmpty || !rightAuxArea.isEmpty
        let cameraHousingWidth = hasCameraHousing
            ? max(screen.frame.width - leftAuxArea.width - rightAuxArea.width, 0)
            : 0
        let cameraHousingHeight = max(leftAuxArea.height, rightAuxArea.height, screen.safeAreaInsets.top)
        store.updateDisplayLayout(isExternal: isExternalDisplay, screenWidth: renderedScreenWidth)
        store.syncCameraHousingMetrics(
            width: cameraHousingWidth,
            height: cameraHousingHeight > 0 ? cameraHousingHeight : menuBarHeight
        )
    }

    private func placementScreen(for window: NSWindow, preferMouseScreen: Bool = false) -> NSScreen? {
        if case let .fixed(displayID) = screenPlacementMode,
           let fixedScreen = screen(for: displayID) {
            return fixedScreen
        }

        if let automaticScreen = automaticPlacementScreen(preferMouseScreen: preferMouseScreen) {
            return automaticScreen
        }

        if let screen = window.screen {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func automaticPlacementScreen(preferMouseScreen: Bool) -> NSScreen? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           let focusedScreen = focusedScreen(for: frontmostApplication) {
            return focusedScreen
        }

        if preferMouseScreen, let hoveredScreen = screenContainingMouse() {
            return hoveredScreen
        }

        if let hoveredScreen = screenContainingMouse() {
            return hoveredScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private func focusedScreen(for application: NSRunningApplication) -> NSScreen? {
        guard application.processIdentifier > 0 else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windowAttributes: [CFString] = [
            kAXFocusedWindowAttribute as CFString,
            kAXMainWindowAttribute as CFString
        ]

        for attribute in windowAttributes {
            guard let windowElement = accessibilityElementAttribute(attribute, on: appElement) else {
                continue
            }

            if let frame = accessibilityFrame(for: windowElement),
               let screen = screen(matching: frame) {
                return screen
            }
        }

        return nil
    }

    private func accessibilityElementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        guard
            let positionValue = accessibilityValueAttribute(kAXPositionAttribute as CFString, on: element, type: .cgPoint),
            let sizeValue = accessibilityValueAttribute(kAXSizeAttribute as CFString, on: element, type: .cgSize)
        else {
            return nil
        }

        let origin = CGPoint(x: positionValue.point.x, y: positionValue.point.y)
        let size = CGSize(width: sizeValue.size.width, height: sizeValue.size.height)
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func accessibilityValueAttribute(
        _ attribute: CFString,
        on element: AXUIElement,
        type: AXValueType
    ) -> AccessibilityValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        switch type {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else {
                return nil
            }
            return .point(point)
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else {
                return nil
            }
            return .size(size)
        default:
            return nil
        }
    }

    private func screen(matching frame: CGRect) -> NSScreen? {
        let normalizedFrame = frame.standardized
        guard !normalizedFrame.isNull, !normalizedFrame.isEmpty else {
            return nil
        }

        let bestScreen = NSScreen.screens.max { lhs, rhs in
            let leftIntersection = lhs.frame.intersection(normalizedFrame)
            let rightIntersection = rhs.frame.intersection(normalizedFrame)
            return (leftIntersection.width * leftIntersection.height) < (rightIntersection.width * rightIntersection.height)
        }

        if let bestScreen, bestScreen.frame.intersects(normalizedFrame) {
            return bestScreen
        }

        let frameCenter = CGPoint(x: normalizedFrame.midX, y: normalizedFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(frameCenter) })
    }

    private func registerScreenObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(handleScreenParametersChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleWindowScreenChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        workspaceCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        workspaceCenter.addObserver(
            self,
            selector: #selector(handleDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func registerOutsideClickMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.collapsePanelIfNeeded(for: event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.collapsePanelIfNeeded(for: event)
        }
    }

    private func collapsePanelIfNeeded(for event: NSEvent) {
        guard store.isExpanded, let window else {
            return
        }

        let clickLocation = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        guard !window.frame.contains(clickLocation) else {
            return
        }

        debugLog("collapsePanelIfNeeded collapsing panel from outside click")
        store.collapsePanel()
    }

    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [AppDelegate] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogURL.path),
               let handle = try? FileHandle(forWritingTo: debugLogURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: debugLogURL, options: .atomic)
            }
        }
    }

    private func updateMenuState() {
        visibilityMenuItem?.title = "Show/Hide Island"
        if isDownloadingUpdate {
            checkForUpdatesMenuItem?.title = "Downloading Update…"
        } else if isCheckingForUpdates {
            checkForUpdatesMenuItem?.title = "Checking for Updates…"
        } else {
            checkForUpdatesMenuItem?.title = "Check for Updates…"
        }
        checkForUpdatesMenuItem?.isEnabled = !isCheckingForUpdates && !isDownloadingUpdate
        automaticScreenMenuItem?.state = screenPlacementMode == .automatic ? .on : .off
        for item in fixedScreenMenuItems {
            guard let representedDisplayID = item.representedObject as? NSNumber else {
                item.state = .off
                continue
            }
            item.state = isSelectedFixedScreen(CGDirectDisplayID(representedDisplayID.uint32Value)) ? .on : .off
        }
        hermitLogoMenuItem?.state = store.selectedLogo == .hermit ? .on : .off
        clawdLogoMenuItem?.state = store.selectedLogo == .clawd ? .on : .off
        zenMuxLogoMenuItem?.state = store.selectedLogo == .zenmux ? .on : .off
        claudeCodeLogoMenuItem?.state = store.selectedLogo == .claudeCodeColor ? .on : .off
        codexColorLogoMenuItem?.state = store.selectedLogo == .codexColor ? .on : .off
        codexMonoLogoMenuItem?.state = store.selectedLogo == .codexMono ? .on : .off
        openAILogoMenuItem?.state = store.selectedLogo == .openAI ? .on : .off
        approvalPreviewMenuItem?.state = store.approvalPreviewEnabled ? .on : .off
    }

    private var screenPlacementMode: ScreenPlacementMode {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: screenPlacementModeDefaultsKey) ?? "automatic"
        guard mode == "fixed" else {
            return .automatic
        }

        let fixedID = defaults.integer(forKey: fixedScreenIDDefaultsKey)
        guard fixedID > 0 else {
            return .automatic
        }

        return .fixed(CGDirectDisplayID(fixedID))
    }

    private func setScreenPlacementMode(_ mode: ScreenPlacementMode) {
        let defaults = UserDefaults.standard

        switch mode {
        case .automatic:
            defaults.set("automatic", forKey: screenPlacementModeDefaultsKey)
            defaults.removeObject(forKey: fixedScreenIDDefaultsKey)
        case let .fixed(displayID):
            defaults.set("fixed", forKey: screenPlacementModeDefaultsKey)
            defaults.set(Int(displayID), forKey: fixedScreenIDDefaultsKey)
        }

        guard let window else {
            rebuildScreenMenu()
            updateMenuState()
            return
        }

        position(window: window, size: store.windowSize, animation: nil)
        window.orderFrontRegardless()
        rebuildScreenMenu()
        updateMenuState()
        store.objectWillChange.send()
    }

    private func rebuildScreenMenu() {
        guard let screenSubmenu = screenMenuItem?.submenu else {
            return
        }

        while screenSubmenu.items.count > 1 {
            screenSubmenu.removeItem(at: 1)
        }
        fixedScreenMenuItems.removeAll()

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return
        }

        screenSubmenu.addItem(.separator())

        for screen in screens {
            guard let displayID = screen.displayID else {
                continue
            }

            let item = NSMenuItem(
                title: titleForScreen(screen, displayID: displayID),
                action: #selector(selectFixedScreenPlacement(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: displayID)
            screenSubmenu.addItem(item)
            fixedScreenMenuItems.append(item)
        }
    }

    private func titleForScreen(_ screen: NSScreen, displayID: CGDirectDisplayID) -> String {
        let typeLabel = isBuiltInDisplay(displayID) ? "Built-in" : "External"
        let sizeLabel = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        return "\(screen.localizedName) (\(typeLabel), \(sizeLabel))"
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { $0.displayID == displayID })
    }

    private func isSelectedFixedScreen(_ displayID: CGDirectDisplayID) -> Bool {
        guard case let .fixed(selectedID) = screenPlacementMode else {
            return false
        }

        return selectedID == displayID
    }

    private func isBuiltInDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    private var currentScreenSelectionTitle: String {
        switch screenPlacementMode {
        case .automatic:
            return "Auto"
        case let .fixed(displayID):
            guard let screen = screen(for: displayID) else {
                return "Auto"
            }

            return titleForScreen(screen, displayID: displayID)
        }
    }

    private var settingsScreenOptions: [SettingsPanelView.ScreenOption] {
        var options: [SettingsPanelView.ScreenOption] = [
            .init(id: "auto", title: "Auto") { [weak self] in
                self?.setScreenPlacementMode(.automatic)
            }
        ]

        options.append(contentsOf: NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else {
                return nil
            }

            return SettingsPanelView.ScreenOption(
                id: String(displayID),
                title: titleForScreen(screen, displayID: displayID)
            ) { [weak self] in
                self?.setScreenPlacementMode(.fixed(displayID))
            }
        })

        return options
    }

    private var claudeSettingsJSONText: String {
        loadClaudeSettingsJSONText()
    }

    private var claudeUsageCommandJSONText: String {
        loadClaudeUsageCommandJSONText()
    }

    private var claudeProviderAuthRows: [ProviderAuthEnvKeyRow] {
        loadClaudeProviderUsageConfigForSettings().providers.map { provider in
            ProviderAuthEnvKeyRow(
                id: provider.id,
                authEnvKey: provider.usageRequest.authEnvKey ?? ""
            )
        }
    }

    private func updateClaudeSettingsJSON(from rawInput: String) {
        do {
            try FileManager.default.createDirectory(
                at: FilePaths.hermitFlowHome,
                withIntermediateDirectories: true
            )
            let normalizedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = normalizedInput.isEmpty ? "{\n  \"paths\": []\n}\n" : normalizedInput + "\n"
            let data = Data(text.utf8)
            try data.write(to: FilePaths.claudeSettingsPaths, options: .atomic)
            store.objectWillChange.send()
            store.resyncClaudeHooks()
        } catch {
            debugLog("Failed to write Claude settings JSON: \(error.localizedDescription)")
        }
    }

    private func updateClaudeUsageCommandJSON(from rawInput: String) {
        do {
            try FileManager.default.createDirectory(
                at: FilePaths.hermitFlowHome,
                withIntermediateDirectories: true
            )

            var config = loadClaudeProviderUsageConfigForSettings()
            let normalizedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = try decodeClaudeUsageCommand(from: normalizedInput)
            config.usageCommand = command

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: FilePaths.claudeProviderUsageConfig, options: .atomic)

            restartProviderConfigMonitor()
            refreshProviderConfigState()
        } catch {
            debugLog("Failed to write Claude usage command JSON: \(error.localizedDescription)")
        }
    }

    private func loadClaudeSettingsJSONText() -> String {
        guard FileManager.default.fileExists(atPath: FilePaths.claudeSettingsPaths.path) else {
            return "{\n  \"paths\": []\n}"
        }

        do {
            let data = try Data(contentsOf: FilePaths.claudeSettingsPaths)
            return String(decoding: data, as: UTF8.self)
        } catch {
            debugLog("Failed to load Claude settings JSON: \(error.localizedDescription)")
            return "{\n  \"paths\": []\n}"
        }
    }

    private func loadClaudeUsageCommandJSONText() -> String {
        let config = loadClaudeProviderUsageConfigForSettings()
        let usageCommand = config.usageCommand ?? ClaudeProviderUsageConfig.defaultConfig.usageCommand

        guard let usageCommand else {
            return "{\n  \"command\": null,\n  \"window\": \"day\",\n  \"valueKind\": \"usedPercentage\",\n  \"displayLabel\": \"day\",\n  \"timeoutSeconds\": 5\n}"
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(usageCommand)
            return String(decoding: data, as: UTF8.self)
        } catch {
            debugLog("Failed to encode Claude usage command JSON: \(error.localizedDescription)")
            return "{\n  \"command\": null,\n  \"window\": \"day\",\n  \"valueKind\": \"usedPercentage\",\n  \"displayLabel\": \"day\",\n  \"timeoutSeconds\": 5\n}"
        }
    }

    private func loadClaudeProviderUsageConfigForSettings() -> ClaudeProviderUsageConfig {
        let decoder = JSONDecoder()

        guard FileManager.default.fileExists(atPath: FilePaths.claudeProviderUsageConfig.path) else {
            return ClaudeProviderUsageConfig.defaultConfig
        }

        do {
            let data = try Data(contentsOf: FilePaths.claudeProviderUsageConfig)
            return try decoder.decode(ClaudeProviderUsageConfig.self, from: data)
        } catch {
            debugLog("Failed to load Claude provider usage config, falling back to defaults: \(error.localizedDescription)")
            return ClaudeProviderUsageConfig.defaultConfig
        }
    }

    private func decodeClaudeUsageCommand(from rawInput: String) throws -> ClaudeProviderUsageCommand {
        let normalizedInput = rawInput.isEmpty
            ? "{\n  \"command\": null,\n  \"window\": \"day\",\n  \"valueKind\": \"usedPercentage\",\n  \"displayLabel\": \"day\",\n  \"timeoutSeconds\": 5\n}"
            : rawInput

        let data = Data(normalizedInput.utf8)
        return try JSONDecoder().decode(ClaudeProviderUsageCommand.self, from: data)
    }

    private func updateClaudeProviderUsageAuthEnvKey(providerID: String, value: String) {
        do {
            try FileManager.default.createDirectory(
                at: FilePaths.hermitFlowHome,
                withIntermediateDirectories: true
            )

            var config = loadClaudeProviderUsageConfigForSettings()
            guard let index = config.providers.firstIndex(where: { $0.id == providerID }) else {
                return
            }

            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            config.providers[index].usageRequest.authEnvKey = normalizedValue.isEmpty ? nil : normalizedValue

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: FilePaths.claudeProviderUsageConfig, options: .atomic)

            restartProviderConfigMonitor()
            refreshProviderConfigState()
        } catch {
            debugLog("Failed to write Claude provider usage config: \(error.localizedDescription)")
        }
    }

    private func startProviderConfigSync() {
        refreshProviderConfigState()
        startProviderConfigPollTimer()
        restartProviderConfigMonitor()
    }

    private func stopProviderConfigSync() {
        providerConfigMonitor?.cancel()
        providerConfigMonitor = nil

        if providerConfigMonitorFileDescriptor >= 0 {
            close(providerConfigMonitorFileDescriptor)
            providerConfigMonitorFileDescriptor = -1
        }

        providerConfigPollTimer?.invalidate()
        providerConfigPollTimer = nil
        providerConfigLastKnownModificationDate = nil
    }

    private func startProviderConfigPollTimer() {
        providerConfigPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollProviderConfigChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        providerConfigPollTimer = timer
    }

    private func pollProviderConfigChanges() {
        let currentModificationDate = providerConfigModificationDate()
        if currentModificationDate != providerConfigLastKnownModificationDate {
            refreshProviderConfigState()
            restartProviderConfigMonitor()
        } else if providerConfigMonitor == nil && FileManager.default.fileExists(atPath: FilePaths.claudeProviderUsageConfig.path) {
            restartProviderConfigMonitor()
        }
    }

    private func restartProviderConfigMonitor() {
        providerConfigMonitor?.cancel()
        providerConfigMonitor = nil

        if providerConfigMonitorFileDescriptor >= 0 {
            close(providerConfigMonitorFileDescriptor)
            providerConfigMonitorFileDescriptor = -1
        }

        let path = FilePaths.claudeProviderUsageConfig.path
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        providerConfigMonitorFileDescriptor = fileDescriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleProviderConfigFilesystemEvent()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.providerConfigMonitorFileDescriptor >= 0 {
                close(self.providerConfigMonitorFileDescriptor)
                self.providerConfigMonitorFileDescriptor = -1
            }
        }
        providerConfigMonitor = source
        source.resume()
    }

    private func handleProviderConfigFilesystemEvent() {
        refreshProviderConfigState()
        restartProviderConfigMonitor()
    }

    private func refreshProviderConfigState() {
        providerConfigLastKnownModificationDate = providerConfigModificationDate()
        providerConfigRefreshToken &+= 1
        store.objectWillChange.send()
    }

    private func providerConfigModificationDate() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: FilePaths.claudeProviderUsageConfig.path
        ) else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }

    private var isWindowVisible: Bool {
        windowCoordinator.isWindowVisible
    }

    @objc
    private func toggleWindowVisibility() {
        guard let window else { return }

        if isWindowVisible {
            windowCoordinator.hideWindow()
        } else {
            position(window: window, size: store.windowSize, animation: nil)
            windowCoordinator.showWindow()
        }

        updateMenuState()
    }

    @objc
    private func selectAutomaticScreenPlacement() {
        setScreenPlacementMode(.automatic)
    }

    @objc
    private func selectFixedScreenPlacement(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else {
            return
        }

        setScreenPlacementMode(.fixed(CGDirectDisplayID(value.uint32Value)))
    }

    @objc
    private func selectHermitLogo() {
        store.selectLogo(.hermit)
        updateMenuState()
    }

    @objc
    private func selectClawdLogo() {
        store.selectLogo(.clawd)
        updateMenuState()
    }

    @objc
    private func selectZenMuxLogo() {
        store.selectLogo(.zenmux)
        updateMenuState()
    }

    @objc
    private func selectClaudeCodeLogo() {
        store.selectLogo(.claudeCodeColor)
        updateMenuState()
    }

    @objc
    private func selectCodexColorLogo() {
        store.selectLogo(.codexColor)
        updateMenuState()
    }

    @objc
    private func selectCodexMonoLogo() {
        store.selectLogo(.codexMono)
        updateMenuState()
    }

    @objc
    private func selectOpenAILogo() {
        store.selectLogo(.openAI)
        updateMenuState()
    }

    @objc
    private func resyncClaudeHooks() {
        store.resyncClaudeHooks()
    }

    @objc
    private func checkForUpdates() {
        guard !isCheckingForUpdates, !isDownloadingUpdate else {
            return
        }

        isCheckingForUpdates = true
        updateMenuState()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                isCheckingForUpdates = false
                updateMenuState()
            }

            do {
                let result = try await updateChecker.checkForUpdates()
                presentUpdateCheckAlert(for: result)
            } catch {
                presentUpdateCheckFailureAlert(error: error)
            }
        }
    }

    @objc
    private func quitFromMenu() {
        store.quitApp()
    }

    @objc
    private func toggleApprovalPreview() {
        store.toggleApprovalPreview()
        updateMenuState()
    }

    @objc
    private func handleScreenParametersChange(_ notification: Notification) {
        rebuildScreenMenu()
        guard let window else { return }
        position(window: window, size: store.windowSize, animation: nil)
    }

    @objc
    private func handleWindowScreenChange(_ notification: Notification) {
        guard
            let changedWindow = notification.object as? NSWindow,
            changedWindow == window
        else { return }

        position(window: changedWindow, size: store.windowSize, animation: nil)
    }

    @objc
    private func handleActiveSpaceDidChange(_ notification: Notification) {
        guard let window else { return }
        guard settingsPanel?.isVisible != true else { return }

        let shouldKeepPanelExpanded = store.isExpanded
        if shouldKeepPanelExpanded {
            store.suppressPanelAutoCollapse(for: 2.0)
        }

        position(window: window, size: store.windowSize, animation: nil, preferMouseScreen: true)
        windowCoordinator.orderFront()

        // AppKit can briefly report the previous screen during a trackpad space
        // transition, so re-anchor once more on the next run loop.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animation: nil, preferMouseScreen: true)
            self.windowCoordinator.orderFront()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animation: nil, preferMouseScreen: true)
            self.windowCoordinator.orderFront()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animation: nil, preferMouseScreen: true)
            self.windowCoordinator.orderFront()
        }
    }

    @objc
    private func handleAppDidBecomeActive(_ notification: Notification) {
        store.handleAppDidBecomeActive()
    }

    @objc
    private func handleDidActivateApplication(_ notification: Notification) {
        guard screenPlacementMode == .automatic, let window else {
            return
        }

        position(window: window, size: store.windowSize, animation: nil)
        windowCoordinator.orderFront()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildScreenMenu()
        updateMenuState()
    }

    private func presentUpdateCheckAlert(for result: GitHubReleaseUpdateChecker.Result) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        if result.isUpdateAvailable {
            alert.messageText = "Update Available"
            alert.informativeText = "Version \(result.latestVersion) is available. You are currently on \(result.currentVersion)."

            if result.preferredAssetURL != nil {
                alert.addButton(withTitle: "Download and Install")
            }
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "HermitFlow Is Up To Date"
            alert.informativeText = "Current version: \(result.currentVersion)\nLatest version: \(result.latestVersion)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "View Release")
        }

        let response = alert.runModal()
        if result.isUpdateAvailable {
            if result.preferredAssetURL != nil, response == .alertFirstButtonReturn {
                if let preferredAssetURL = result.preferredAssetURL {
                    downloadAndInstallUpdate(from: preferredAssetURL)
                }
                return
            }

            let releaseButtonReturn: NSApplication.ModalResponse = result.preferredAssetURL != nil
                ? .alertSecondButtonReturn
                : .alertFirstButtonReturn
            if response == releaseButtonReturn {
                NSWorkspace.shared.open(result.releasePageURL)
            }
            return
        }

        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.releasePageURL)
        }
    }

    private func presentUpdateCheckFailureAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Failed to Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func downloadAndInstallUpdate(from remoteURL: URL) {
        guard !isDownloadingUpdate else {
            return
        }

        isDownloadingUpdate = true
        updateMenuState()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                isDownloadingUpdate = false
                updateMenuState()
            }

            do {
                let localURL = try await updateDownloader.downloadAsset(from: remoteURL)
                updateDownloader.openDownloadedAsset(at: localURL)
                presentDownloadStartedAlert(localURL: localURL)
            } catch {
                presentDownloadFailureAlert(error: error)
            }
        }
    }

    private func presentDownloadStartedAlert(localURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Installer Ready"
        alert.informativeText = "The update package was downloaded and opened.\n\nLocal file: \(localURL.path)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentDownloadFailureAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Failed to Download Update"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum AccessibilityValue {
    case point(CGPoint)
    case size(CGSize)

    var point: CGPoint {
        guard case let .point(value) = self else {
            return .zero
        }

        return value
    }

    var size: CGSize {
        guard case let .size(value) = self else {
            return .zero
        }

        return value
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let value = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(value.uint32Value)
    }
}
