import Foundation

final class ApprovalStore {
    private(set) var currentRequest: ApprovalRequest?
    private var lastObservedAt: Date?
    private let retentionWindow: TimeInterval = 1.25

    func update(with request: ApprovalRequest?) {
        let now = Date()

        if let request {
            currentRequest = request
            lastObservedAt = now
            return
        }

        if currentRequest?.source == .claude {
            clear()
            return
        }

        guard
            currentRequest != nil,
            let lastObservedAt,
            now.timeIntervalSince(lastObservedAt) <= retentionWindow
        else {
            clear()
            return
        }
    }

    func clear() {
        currentRequest = nil
        lastObservedAt = nil
    }
}
