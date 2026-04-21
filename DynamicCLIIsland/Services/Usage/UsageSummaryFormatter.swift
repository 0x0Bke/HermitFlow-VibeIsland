//
//  UsageSummaryFormatter.swift
//  HermitFlow
//
//  Phase 6 local-first usage formatting helpers.
//

import Foundation

enum UsageSummaryFormatter {
    static func percentText(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    static func claudeSummaryText(_ snapshot: ClaudeUsageSnapshot?, displayType: UsageDisplayType) -> String? {
        guard let snapshot, !snapshot.isEmpty else {
            return nil
        }

        var parts: [String] = []
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            parts.append(providerDisplayName)
        }
        for entry in snapshot.displayWindows.prefix(2) {
            parts.append(displayType.summaryPart(label: entry.label, used: entry.window.roundedUsedPercentage, remaining: entry.window.roundedLeftPercentage))
        }
        if let updatedText = updatedText(snapshot.cachedAt) {
            parts.append("updated \(updatedText)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func codexSummaryText(_ snapshot: CodexUsageSnapshot?, displayType: UsageDisplayType) -> String? {
        guard let snapshot, !snapshot.isEmpty else {
            return nil
        }

        var parts = snapshot.windows
            .sorted { $0.windowMinutes < $1.windowMinutes }
            .prefix(2)
            .map { displayType.summaryPart(label: $0.label, used: $0.roundedUsedPercentage, remaining: $0.roundedLeftPercentage) }

        if let planType = snapshot.planType, !planType.isEmpty {
            parts.append("plan \(planType)")
        }

        if let updatedText = updatedText(snapshot.capturedAt) {
            parts.append("updated \(updatedText)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func openCodeSummaryText(_ snapshot: OpenCodeUsageSnapshot?, displayType: UsageDisplayType) -> String? {
        guard let snapshot, !snapshot.isEmpty else {
            return nil
        }

        var parts: [String] = []
        if let providerDisplayName = snapshot.providerDisplayName, !providerDisplayName.isEmpty {
            parts.append(providerDisplayName)
        }
        for entry in snapshot.displayWindows.prefix(2) {
            parts.append(displayType.summaryPart(label: entry.label, used: entry.window.roundedUsedPercentage, remaining: entry.window.roundedLeftPercentage))
        }
        if let updatedText = updatedText(snapshot.capturedAt) {
            parts.append("updated \(updatedText)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func updatedText(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension UsageDisplayType {
    func summaryPart(label: String, used: Int, remaining: Int) -> String {
        switch self {
        case .remaining:
            return "\(label) \(remaining)%"
        case .used:
            return "\(label) \(used)%"
        }
    }
}
