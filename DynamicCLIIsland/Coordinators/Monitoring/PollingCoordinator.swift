//
//  PollingCoordinator.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Temporary home for future polling timer ownership.
///
/// Phase 1 leaves all existing polling behavior where it already lives.
@MainActor
final class PollingCoordinator {
    private var timers: [String: Timer] = [:]

    func startTimer(id: String, interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stopTimer(id: id)

        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }

        timers[id] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopTimer(id: String) {
        timers[id]?.invalidate()
        timers[id] = nil
    }

    func stopAll() {
        for timer in timers.values {
            timer.invalidate()
        }
        timers.removeAll()
    }

    deinit {
        MainActor.assumeIsolated {
            stopAll()
        }
    }
}
