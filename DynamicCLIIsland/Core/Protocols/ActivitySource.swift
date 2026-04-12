//
//  ActivitySource.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Shared abstraction for future runtime activity providers.
///
/// This intentionally mirrors the current legacy snapshot flow so Phase 1 can
/// remain non-breaking while new providers are introduced around it.
protocol ActivitySource {
    func fetchActivity() -> ActivitySourceSnapshot
}
