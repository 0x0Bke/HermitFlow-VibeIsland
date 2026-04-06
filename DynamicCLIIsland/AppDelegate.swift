import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum ScreenPlacementMode: Equatable {
        case automatic
        case fixed(CGDirectDisplayID)
    }

    private let store = ProgressStore()
    private var window: NSWindow?
    private var isPositioningWindow = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var statusItem: NSStatusItem?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createWindow()
        createStatusItem()
        registerScreenObservers()
        registerOutsideClickMonitors()
        store.handleLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        let window = NSWindow(
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
        window.contentView = NSHostingView(rootView: rootView)
        position(window: window, size: size, animated: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        position(window: window, size: size, animated: false)

        store.onWindowSizeChange = { [weak self] newSize in
            guard let self, !self.isPositioningWindow else {
                return
            }

            self.position(window: window, size: newSize, animated: true)
        }

        self.window = window
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

        if let button = statusItem.button {
            button.image = makeStatusBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Dynamic CLI Island"
        }

        statusItem.menu = menu
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

    private func position(window: NSWindow, size: CGSize, animated: Bool, preferMouseScreen: Bool = false) {
        isPositioningWindow = true
        defer { isPositioningWindow = false }

        guard let screen = placementScreen(for: window, preferMouseScreen: preferMouseScreen) else {
            return
        }

        syncCompactMetrics(for: screen)
        let resolvedSize = store.windowSize
        let frame = screen.frame
        let leftAuxArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightAuxArea = screen.auxiliaryTopRightArea ?? .zero
        let hasCameraHousing = !leftAuxArea.isEmpty || !rightAuxArea.isEmpty
        let topInset = topInsetForWindow(size: resolvedSize, hasCameraHousing: hasCameraHousing)
        let origin = CGPoint(
            x: frame.midX - resolvedSize.width / 2,
            y: frame.maxY - resolvedSize.height - topInset
        )
        let targetFrame = NSRect(origin: origin, size: resolvedSize)
        updatePanelHoverArming(for: targetFrame)

        if animated {
            let isExpanding = targetFrame.height > window.frame.height
            guard isExpanding else {
                window.setFrame(targetFrame, display: true)
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
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

        if preferMouseScreen {
            let mouseLocation = NSEvent.mouseLocation
            if let hoveredScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
                return hoveredScreen
            }
        }

        if let screen = window.screen {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return hoveredScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
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

        store.collapsePanel()
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

        position(window: window, size: store.windowSize, animated: false)
        window.orderFrontRegardless()
        rebuildScreenMenu()
        updateMenuState()
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

    private var isWindowVisible: Bool {
        window?.isVisible == true
    }

    @objc
    private func toggleWindowVisibility() {
        guard let window else { return }

        if isWindowVisible {
            window.orderOut(nil)
        } else {
            position(window: window, size: store.windowSize, animated: false)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
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
        position(window: window, size: store.windowSize, animated: false)
    }

    @objc
    private func handleWindowScreenChange(_ notification: Notification) {
        guard
            let changedWindow = notification.object as? NSWindow,
            changedWindow == window
        else { return }

        position(window: changedWindow, size: store.windowSize, animated: false)
    }

    @objc
    private func handleActiveSpaceDidChange(_ notification: Notification) {
        guard let window else { return }

        let shouldKeepPanelExpanded = store.isExpanded
        if shouldKeepPanelExpanded {
            store.suppressPanelAutoCollapse(for: 2.0)
        }

        position(window: window, size: store.windowSize, animated: false, preferMouseScreen: true)
        window.orderFrontRegardless()

        // AppKit can briefly report the previous screen during a trackpad space
        // transition, so re-anchor once more on the next run loop.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animated: false, preferMouseScreen: true)
            window.orderFrontRegardless()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animated: false, preferMouseScreen: true)
            window.orderFrontRegardless()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak window] in
            guard let self, let window else { return }

            if shouldKeepPanelExpanded, !self.store.isExpanded {
                self.store.showPanel()
            }
            self.position(window: window, size: self.store.windowSize, animated: false, preferMouseScreen: true)
            window.orderFrontRegardless()
        }
    }

    @objc
    private func handleAppDidBecomeActive(_ notification: Notification) {
        store.handleAppDidBecomeActive()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildScreenMenu()
        updateMenuState()
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
