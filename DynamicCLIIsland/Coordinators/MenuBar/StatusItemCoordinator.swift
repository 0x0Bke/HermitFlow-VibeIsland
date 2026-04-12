//
//  StatusItemCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import AppKit

/// Temporary seam for future status item and menu extraction.
///
/// `AppDelegate` still owns menu construction and behavior in Phase 1.
@MainActor
final class StatusItemCoordinator {
    private(set) var statusItem: NSStatusItem?

    func attach(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func setMenu(_ menu: NSMenu) {
        statusItem?.menu = menu
    }

    func setImage(_ image: NSImage?) {
        statusItem?.button?.image = image
    }

    func setToolTip(_ toolTip: String?) {
        statusItem?.button?.toolTip = toolTip
    }
}
