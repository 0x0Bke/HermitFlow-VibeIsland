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
    struct FrameAnimation {
        let duration: TimeInterval
        let timingFunctionName: CAMediaTimingFunctionName

        static let panelTransition = FrameAnimation(
            duration: 0.24,
            timingFunctionName: .easeInEaseOut
        )
    }

    func applySize(
        _ size: CGSize,
        to window: NSWindow,
        display: Bool = true,
        animation: FrameAnimation? = nil
    ) {
        var frame = window.frame
        frame.size = size
        applyFrame(frame, to: window, display: display, animation: animation)
    }

    func applyFrame(
        _ frame: NSRect,
        to window: NSWindow,
        display: Bool = true,
        animation: FrameAnimation? = nil
    ) {
        if let animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animation.duration
                context.timingFunction = CAMediaTimingFunction(name: animation.timingFunctionName)
                window.animator().setFrame(frame, display: display)
            }
        } else {
            window.setFrame(frame, display: display)
        }
    }
}
