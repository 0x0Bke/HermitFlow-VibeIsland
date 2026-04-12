//
//  AccessibilityCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Temporary seam for future accessibility permission coordination.
///
/// Permission polling remains owned by `ProgressStore` in Phase 1.
@MainActor
final class AccessibilityCoordinator {
    private let monitor = AccessibilityPermissionMonitor()

    func isTrusted() -> Bool {
        monitor.isTrusted()
    }
}
