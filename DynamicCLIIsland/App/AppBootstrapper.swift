//
//  AppBootstrapper.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Temporary startup facade for the refactor.
///
/// Phase 2 still delegates runtime launch to the legacy startup path while
/// `AppDelegate` remains responsible for window and menu setup. Future phases
/// will move broader startup orchestration here once the new composition is ready.
@MainActor
final class AppBootstrapper {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func bootstrap() {
        environment.progressStore.handleLaunch()
    }
}
