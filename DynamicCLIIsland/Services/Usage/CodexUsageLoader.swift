//
//  CodexUsageLoader.swift
//  HermitFlow
//
//  Local-first Codex rollout usage loader.
//

import Foundation

enum CodexUsageLoader {
    private static let maxTailBytes = 262_144
    private static let maxFilesToScan = 200

    static func load() throws -> CodexUsageSnapshot? {
        let fileURLs = try candidateRolloutFiles()

        for fileURL in fileURLs.prefix(maxFilesToScan) {
            if let snapshot = try loadSnapshot(from: fileURL), !snapshot.isEmpty {
                return snapshot
            }
        }

        return nil
    }

    private static func candidateRolloutFiles(fileManager: FileManager = .default) throws -> [URL] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(url: URL, modificationDate: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl" else {
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            results.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return results
            .sorted { $0.modificationDate > $1.modificationDate }
            .map(\.url)
    }

    private static func loadSnapshot(from fileURL: URL) throws -> CodexUsageSnapshot? {
        let data = try Data(contentsOf: fileURL)
        let tailData = data.count > maxTailBytes ? data.suffix(maxTailBytes) : data[...]
        let content = String(decoding: tailData, as: UTF8.self)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usagePayload = extractUsagePayload(from: record) else {
                continue
            }

            let windows = parseWindows(from: usagePayload.rateLimits)
            guard !windows.isEmpty else {
                continue
            }

            return CodexUsageSnapshot(
                sourceFilePath: fileURL.path,
                capturedAt: usagePayload.timestamp,
                planType: usagePayload.rateLimits["plan_type"] as? String,
                limitID: usagePayload.rateLimits["limit_id"] as? String,
                windows: windows.sorted { $0.windowMinutes < $1.windowMinutes }
            )
        }

        return nil
    }

    private static func extractUsagePayload(from record: [String: Any]) -> (timestamp: Date?, rateLimits: [String: Any])? {
        let timestamp = parseDate(record["timestamp"])

        if let type = record["type"] as? String,
           type == "event_msg",
           let payload = record["payload"] as? [String: Any],
           let payloadType = payload["type"] as? String,
           payloadType == "token_count",
           let rateLimits = payload["rate_limits"] as? [String: Any] {
            return (timestamp, rateLimits)
        }

        // TODO: Remove this compatibility branch once all local Codex rollout producers emit the envelope above.
        if let type = record["type"] as? String,
           type == "token_count" {
            if let payload = record["payload"] as? [String: Any],
               let rateLimits = payload["rate_limits"] as? [String: Any] {
                return (timestamp, rateLimits)
            }

            if let rateLimits = record["rate_limits"] as? [String: Any] {
                return (timestamp, rateLimits)
            }
        }

        return nil
    }

    private static func parseWindows(from rateLimits: [String: Any]) -> [CodexUsageWindow] {
        var windows: [CodexUsageWindow] = []

        if let primaryWindow = parseWindow(key: "primary", value: rateLimits["primary"]) {
            windows.append(primaryWindow)
        }

        if let secondaryWindow = parseWindow(key: "secondary", value: rateLimits["secondary"]) {
            windows.append(secondaryWindow)
        }

        return windows
    }

    private static func parseWindow(key: String, value: Any?) -> CodexUsageWindow? {
        guard let dictionary = value as? [String: Any],
              let usedPercentage = normalizedPercentage(dictionary["used_percent"] ?? dictionary["used_percentage"]),
              let windowMinutes = parseInt(dictionary["window_minutes"]) else {
            return nil
        }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(for: key, minutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 1 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: parseDate(dictionary["resets_at"])
        )
    }

    private static func windowLabel(for key: String, minutes: Int) -> String {
        switch minutes {
        case 60:
            return "1h"
        case 300:
            return "5h"
        case 1_440:
            return "1d"
        case 10_080:
            return "7d"
        default:
            return key.capitalized
        }
    }

    private static func normalizedPercentage(_ value: Any?) -> Double? {
        guard let value else {
            return nil
        }

        let rawValue: Double?
        switch value {
        case let number as NSNumber:
            rawValue = number.doubleValue
        case let string as String:
            rawValue = Double(string)
        default:
            rawValue = nil
        }

        guard let rawValue else {
            return nil
        }

        if rawValue > 1 {
            return min(max(rawValue / 100, 0), 1)
        }

        return min(max(rawValue, 0), 1)
    }

    private static func parseInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            if let timestamp = Double(string) {
                return Date(timeIntervalSince1970: timestamp)
            }
            return ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }
}
