//
//  AppEnvironment.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Temporary composition root for upcoming refactor phases.
///
/// Phase 3 prefers `AppStore` as the primary root dependency while keeping a
/// legacy `ProgressStore` wrapper alive so the existing UI can remain unchanged.
@MainActor
final class AppEnvironment {
    let appStore: AppStore
    let progressStore: ProgressStore
    let sessionStore: SessionStore
    lazy var appBootstrapper = AppBootstrapper(environment: self)
    lazy var windowCoordinator = IslandWindowCoordinator()
    lazy var windowSizingCoordinator = WindowSizingCoordinator()
    lazy var screenPlacementCoordinator = ScreenPlacementCoordinator()
    lazy var statusItemCoordinator = StatusItemCoordinator()

    init(
        appStore: AppStore = AppStore(),
        sessionStore: SessionStore = SessionStore()
    ) {
        self.appStore = appStore
        self.progressStore = ProgressStore(appStore: appStore)
        self.sessionStore = sessionStore
    }
}
