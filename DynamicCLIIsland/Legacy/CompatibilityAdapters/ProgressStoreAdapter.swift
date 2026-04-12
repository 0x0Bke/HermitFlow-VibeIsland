//
//  ProgressStoreAdapter.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation
import SwiftUI

/// Temporary compatibility seam around the new `AppStore`.
///
/// UI migration is still incomplete in Phase 3, so this adapter continues to
/// expose a narrow bridge while `ProgressStore` remains as a legacy façade.
@MainActor
final class ProgressStoreAdapter: ObservableObject {
    // TODO: Forward `objectWillChange` when new runtime consumers need live bridging.
    let store: AppStore

    init(store: AppStore = AppStore()) {
        self.store = store
    }

    var displayMode: IslandDisplayMode { store.displayMode }
    var windowSize: CGSize { store.windowSize }

    func handleLaunch() {
        store.handleLaunch()
    }

    func showPanel() {
        store.showPanel()
    }

    func showIsland() {
        store.showIsland()
    }

    func showHidden() {
        store.showHidden()
    }

    func resyncClaudeHooks() {
        store.resyncClaudeHooks()
    }
}
