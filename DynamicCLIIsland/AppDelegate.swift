import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let environment = AppEnvironment()
    private var store: ProgressStore { environment.progressStore }
    private var window: NSWindow?
    private var isPositioningWindow = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let settingsWindowCoordinator = SettingsWindowCoordinator()
    private let providerConfigStore = ClaudeProviderConfigStore()
    private let providerConfigWatcher = ProviderConfigWatcher()
    private let loginItemController = LoginItemController()
    private var providerConfigRefreshToken = 0
    private let screenPlacementModeDefaultsKey = "HermitFlow.screenPlacementMode"
    private let fixedScreenIDDefaultsKey = "HermitFlow.fixedScreenID"
    private let debugLogURL = FilePaths.approvalDebugLog
    private let updateChecker = GitHubReleaseUpdateChecker()
    private let updateDownloader = GitHubReleaseAssetDownloader()
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
        settingsWindowCoordinator.handleReopen()
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
        window.hasShadow = false
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
        store.showIsland()
        NSApp.setActivationPolicy(.regular)

        settingsWindowCoordinator.present(
            rootView: makeSettingsPanelView(),
            referenceWindow: window,
            keepIslandVisible: { [weak self] in
                self?.keepIslandVisibleForSettings()
            },
            onClose: { [weak self] in
                self?.stopProviderConfigSync()
                NSApp.setActivationPolicy(.accessory)
            }
        )
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
            askUserQuestionHandlingMode: { [weak self] in
                self?.store.askUserQuestionHandlingMode ?? .takeOver
            },
            onAskUserQuestionHandlingModeSelected: { [weak self] mode in
                self?.store.setAskUserQuestionHandlingMode(mode)
            },
            usageDisplayType: { [weak self] in
                self?.store.usageDisplayType ?? .remaining
            },
            onUsageDisplayTypeSelected: { [weak self] option in
                self?.store.setUsageDisplayType(option)
            },
            dotMatrixAnimationEnabled: { [weak self] in
                self?.store.dotMatrixAnimationEnabled ?? false
            },
            onDotMatrixAnimationEnabledChange: { [weak self] isEnabled in
                self?.store.setDotMatrixAnimationEnabled(isEnabled)
            },
            launchAtLoginEnabled: { [weak self] in
                self?.loginItemController.isEnabled ?? false
            },
            onLaunchAtLoginChange: { [weak self] isEnabled in
                self?.setLaunchAtLoginEnabled(isEnabled)
            },
            currentCustomLogoPath: { [weak self] in
                self?.store.customLogoPath
            },
            onChooseCustomLogo: { [weak self] in
                self?.chooseCustomLeftLogo()
            },
            onClearCustomLogo: { [weak self] in
                self?.clearCustomLeftLogo()
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
        settingsWindowCoordinator.close()
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

    private func chooseCustomLeftLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.image]
        panel.title = "选择左侧 Logo"
        panel.message = "选择一个本地图片作为左侧 Logo。"

        if panel.runModal() == .OK, let url = panel.url {
            importCustomLeftLogo(from: url)
        }
    }

    private func importCustomLeftLogo(from sourceURL: URL) {
        guard let image = NSImage(contentsOf: sourceURL) else {
            debugLog("Failed to import custom left logo: unable to decode image at \(sourceURL.path)")
            return
        }

        guard let pngData = pngData(for: image) else {
            debugLog("Failed to import custom left logo: unable to convert image to PNG at \(sourceURL.path)")
            return
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: FilePaths.customLogosDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            try pngData.write(to: FilePaths.customLeftLogo, options: .atomic)
            store.setCustomLogoPath(FilePaths.customLeftLogo.path)
            store.selectLogo(.custom)
            updateMenuState()
        } catch {
            debugLog("Failed to import custom left logo: \(error.localizedDescription)")
            #if DEBUG
            print("Failed to import custom left logo: \(error)")
            #endif
        }
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func clearCustomLeftLogo() {
        store.clearCustomLogo()
        updateMenuState()
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

    private func keepIslandVisibleForSettings() {
        guard let window else {
            return
        }

        position(window: window, size: store.windowSize, animation: nil)
        windowCoordinator.orderFront()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.settingsWindowCoordinator.currentWindow != nil || NSApp.activationPolicy() == .regular else {
                return
            }

            self.position(window: window, size: self.store.windowSize, animation: nil)
            self.windowCoordinator.orderFront()
        }
    }

    private func createStatusItem() {
        statusItemCoordinator.createStatusItem(
            menuDelegate: self,
            target: self,
            selectors: StatusItemCoordinator.Selectors(
                toggleWindowVisibility: #selector(toggleWindowVisibility),
                selectAutomaticScreenPlacement: #selector(selectAutomaticScreenPlacement),
                selectFixedScreenPlacement: #selector(selectFixedScreenPlacement(_:)),
                selectHermitLogo: #selector(selectHermitLogo),
                selectClawdLogo: #selector(selectClawdLogo),
                selectZenMuxLogo: #selector(selectZenMuxLogo),
                selectClaudeCodeLogo: #selector(selectClaudeCodeLogo),
                selectCodexColorLogo: #selector(selectCodexColorLogo),
                selectCodexMonoLogo: #selector(selectCodexMonoLogo),
                selectOpenAILogo: #selector(selectOpenAILogo),
                selectCustomLogo: #selector(selectCustomLogo),
                resyncClaudeHooks: #selector(resyncClaudeHooks),
                checkForUpdates: #selector(checkForUpdates),
                quitFromMenu: #selector(quitFromMenu)
            ),
            image: makeStatusBarImage()
        )
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

        guard let screen = screenPlacementCoordinator.placementScreen(
            for: window,
            mode: screenPlacementMode,
            preferMouseScreen: preferMouseScreen
        ) else {
            return
        }

        syncCompactMetrics(for: screen)
        let resolvedSize = store.windowSize
        let metrics = screenPlacementCoordinator.compactMetrics(for: screen)
        let topInset = screenPlacementCoordinator.topInset(
            isExpanded: store.isExpanded,
            hasCameraHousing: metrics.hasCameraHousing
        )
        let targetFrame = screenPlacementCoordinator.centeredFrame(
            for: screen,
            windowSize: resolvedSize,
            topInset: topInset
        )
        updatePanelHoverArming(for: targetFrame)
        window.hasShadow = store.displayMode == .panel

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

    private func syncCompactMetrics(for screen: NSScreen) {
        let metrics = screenPlacementCoordinator.compactMetrics(for: screen)
        store.updateDisplayLayout(
            isExternal: metrics.isExternalDisplay,
            screenWidth: metrics.renderedScreenWidth
        )
        store.syncCameraHousingMetrics(
            width: metrics.cameraHousingWidth,
            height: metrics.cameraHousingHeight
        )
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
        statusItemCoordinator.updateMenuState(
            isCheckingForUpdates: isCheckingForUpdates,
            isDownloadingUpdate: isDownloadingUpdate,
            isAutomaticScreenSelected: screenPlacementMode == .automatic,
            isSelectedFixedScreen: isSelectedFixedScreen(_:),
            selectedLogo: store.selectedLogo,
            customLogoPath: store.customLogoPath,
            approvalPreviewEnabled: store.approvalPreviewEnabled
        )
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
        statusItemCoordinator.rebuildScreenMenu { [screenPlacementCoordinator] screen, displayID in
            screenPlacementCoordinator.titleForScreen(screen, displayID: displayID)
        }
    }

    private func isSelectedFixedScreen(_ displayID: CGDirectDisplayID) -> Bool {
        guard case let .fixed(selectedID) = screenPlacementMode else {
            return false
        }

        return selectedID == displayID
    }

    private var currentScreenSelectionTitle: String {
        switch screenPlacementMode {
        case .automatic:
            return "Auto"
        case let .fixed(displayID):
            guard let screen = screenPlacementCoordinator.screen(for: displayID) else {
                return "Auto"
            }

            return screenPlacementCoordinator.titleForScreen(screen, displayID: displayID)
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
                title: screenPlacementCoordinator.titleForScreen(screen, displayID: displayID)
            ) { [weak self] in
                self?.setScreenPlacementMode(.fixed(displayID))
            }
        })

        return options
    }

    private var claudeSettingsJSONText: String {
        providerConfigStore.loadClaudeSettingsJSONText()
    }

    private var claudeUsageCommandJSONText: String {
        providerConfigStore.loadClaudeUsageCommandJSONText()
    }

    private var claudeProviderAuthRows: [ProviderAuthEnvKeyRow] {
        providerConfigStore.providerAuthRows()
    }

    private func updateClaudeSettingsJSON(from rawInput: String) {
        do {
            try providerConfigStore.updateClaudeSettingsJSON(from: rawInput)
            store.objectWillChange.send()
            store.resyncClaudeHooks()
        } catch {
            debugLog("Failed to write Claude settings JSON: \(error.localizedDescription)")
        }
    }

    private func updateClaudeUsageCommandJSON(from rawInput: String) {
        do {
            try providerConfigStore.updateClaudeUsageCommandJSON(from: rawInput)
            providerConfigWatcher.restartMonitor()
            refreshProviderConfigState()
        } catch {
            debugLog("Failed to write Claude usage command JSON: \(error.localizedDescription)")
        }
    }

    private func updateClaudeProviderUsageAuthEnvKey(providerID: String, value: String) {
        do {
            try providerConfigStore.updateClaudeProviderUsageAuthEnvKey(providerID: providerID, value: value)
            providerConfigWatcher.restartMonitor()
            refreshProviderConfigState()
        } catch {
            debugLog("Failed to write Claude provider usage config: \(error.localizedDescription)")
        }
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try loginItemController.setEnabled(isEnabled)
        } catch {
            debugLog("Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    private func startProviderConfigSync() {
        refreshProviderConfigState()
        providerConfigWatcher.start { [weak self] in
            self?.refreshProviderConfigState()
        }
    }

    private func stopProviderConfigSync() {
        providerConfigWatcher.stop()
    }

    private func refreshProviderConfigState() {
        providerConfigRefreshToken &+= 1
        store.objectWillChange.send()
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
    private func selectCustomLogo() {
        guard store.customLogoPath != nil else {
            return
        }

        store.selectLogo(.custom)
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
        guard settingsWindowCoordinator.isVisible != true else { return }

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
