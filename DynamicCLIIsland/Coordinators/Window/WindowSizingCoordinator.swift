//
//  WindowSizingCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import AppKit
import QuartzCore

/// Temporary seam for future window size calculations and resize triggers.
///
/// Phase 1 does not move layout policy or sizing heuristics out of `AppDelegate`.
@MainActor
final class WindowSizingCoordinator {
    func applySize(_ size: CGSize, to window: NSWindow, display: Bool = true) {
        var frame = window.frame
        frame.size = size
        applyFrame(frame, to: window, display: display)
    }

    func applyFrame(_ frame: NSRect, to window: NSWindow, display: Bool = true, animate: Bool = false) {
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: display)
            }
        } else {
            window.setFrame(frame, display: display)
        }
    }
}
