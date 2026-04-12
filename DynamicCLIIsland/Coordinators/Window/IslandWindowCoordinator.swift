//
//  IslandWindowCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import AppKit

/// Temporary seam for future window creation and visibility extraction.
///
/// Phase 1 keeps all sizing and positioning behavior in `AppDelegate`.
@MainActor
final class IslandWindowCoordinator {
    private(set) weak var window: NSWindow?

    func configure(window: NSWindow, with rootView: NSView) {
        window.contentView = rootView
        attach(window: window)
    }

    func attach(window: NSWindow) {
        self.window = window
    }

    func orderFront() {
        window?.orderFrontRegardless()
    }

    func makeKeyAndOrderFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    func showWindow() {
        makeKeyAndOrderFront()
        orderFront()
    }

    func hideWindow() {
        window?.orderOut(nil)
    }

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }
}
