import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

private final class IslandKeyboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            settingsTile(title: "Sound") {
                Toggle("", isOn: soundMutedBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.76)
            }

            settingsTile(title: "Screen") {
                Menu {
                    ForEach(screenOptions()) { option in
                        Button(option.title) {
                            option.action()
                        }
                    }
                } label: {
                    pickerCapsule(title: currentScreenTitle(), width: 148)
                }
                .menuStyle(.borderlessButton)
            }

            settingsTile(title: "Logo") {
                Menu {
                    ForEach(availableLogos, id: \.rawValue) { logo in
                        Button(logo.menuTitle) {
                            store.selectLogo(logo)
                        }
                    }
                } label: {
                    pickerCapsule(title: store.selectedLogo.menuTitle, width: 118)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .frame(width: 640, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.13),
                    Color(red: 0.05, green: 0.06, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func settingsTile<Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            accessory()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func pickerCapsule(title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
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
    private var approvalPreviewMenuItem: NSMenuItem?
    private let screenPlacementModeDefaultsKey = "HermitFlow.screenPlacementMode"
    private let fixedScreenIDDefaultsKey = "HermitFlow.fixedScreenID"
    private let debugLogURL = URL(fileURLWithPath: "/tmp/hermitflow-approval-debug.log")
    private var mainWindowWasVisibleBeforeSettings = false

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

        if let settingsPanel {
            if settingsPanel.isMiniaturized {
                settingsPanel.deminiaturize(nil)
            }
            settingsPanel.makeKeyAndOrderFront(nil)
            keepIslandVisibleForSettings()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 224),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Settings"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .normal
        panel.collectionBehavior = []
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let rootView = SettingsPanelView(
            store: store,
            currentScreenTitle: { [weak self] in
                self?.currentScreenSelectionTitle ?? "Auto"
            },
            screenOptions: { [weak self] in
                self?.settingsScreenOptions ?? []
            }
        )
        panel.contentView = NSHostingView(rootView: rootView)
        positionSettingsPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        keepIslandVisibleForSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }

    private func closeSettingsPanel() {
        settingsPanel?.close()
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
        let isExternalDisplay = displayID.map { !isBuiltInDisplay($0) } ?? false
        let hasCameraHousing = !leftAuxArea.isEmpty || !rightAuxArea.isEmpty
        let cameraHousingWidth = hasCameraHousing
            ? max(screen.frame.width - leftAuxArea.width - rightAuxArea.width, 0)
            : 0
        let cameraHousingHeight = max(leftAuxArea.height, rightAuxArea.height, screen.safeAreaInsets.top)
        store.updateDisplayLayout(isExternal: isExternalDisplay)
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
