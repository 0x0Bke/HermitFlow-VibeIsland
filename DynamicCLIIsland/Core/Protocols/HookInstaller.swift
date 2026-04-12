//
//  HookInstaller.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Shared install lifecycle contract for future hook management workflows.
///
/// Legacy implementations remain in the existing source and service types for now.
protocol HookInstaller {
    func install() throws
    func uninstall() throws
    func resync() throws
    func healthReport() -> SourceHealthReport
}
