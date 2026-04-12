//
//  ScreenPlacementCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import AppKit

/// Temporary seam for future screen-follow and placement logic.
///
/// Active-screen detection and camera housing rules remain in `AppDelegate` for Phase 1.
@MainActor
final class ScreenPlacementCoordinator {
    func centeredOrigin(for screen: NSScreen, windowSize: CGSize, topInset: CGFloat = 0) -> CGPoint {
        centeredFrame(for: screen, windowSize: windowSize, topInset: topInset).origin
    }

    func centeredFrame(for screen: NSScreen, windowSize: CGSize, topInset: CGFloat = 0) -> NSRect {
        let frame = screen.frame
        let origin = CGPoint(
            x: frame.midX - (windowSize.width / 2),
            y: frame.maxY - windowSize.height - topInset
        )
        return NSRect(origin: origin, size: windowSize)
    }
}
