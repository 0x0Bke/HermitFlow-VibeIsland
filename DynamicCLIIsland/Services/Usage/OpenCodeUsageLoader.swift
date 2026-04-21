//
//  OpenCodeUsageLoader.swift
//  HermitFlow
//
//  OpenCode third-party provider usage loader.
//

import Foundation

enum OpenCodeUsageLoader {
    private static let requestTimeout: TimeInterval = 5
    private static let defaultCommandTimeout: TimeInterval = 5

    static func load() throws -> OpenCodeUsageSnapshot? {
        try ensureProviderConfigFileExists()
        let config = try loadProviderConfig()
        let context = loadLatestContext()
        let mergedOpenCodeConfig = try loadMergedOpenCodeConfig(cwd: context?.cwd)
        let provider = resolveProvider(context: context, openCodeConfig: mergedOpenCodeConfig, usageConfig: config)

        if let usageCommand = config.usageCommand,
           let command = usageCommand.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return loadCommandUsageSnapshot(definition: usageCommand, provider: provider)
        }

        guard let provider else {
            return nil
        }

        guard let remoteSnapshot = try loadRemoteUsageSnapshot(for: provider) else {
            return nil
        }

        return applyingProviderMetadata(provider, to: remoteSnapshot)
    }

    private static func loadRemoteUsageSnapshot(for provider: ResolvedOpenCodeProvider) throws -> OpenCodeUsageSnapshot? {
        let responseObject = try fetchUsageResponse(for: provider)
        guard let responseObject else {
            return nil
        }

        if let specializedSnapshot = parseSpecializedUsageSnapshot(from: responseObject, provider: provider) {
            return specializedSnapshot
        }

        let windows = parseMappedWindows(from: responseObject, provider: provider)
        let snapshot = OpenCodeUsageSnapshot(
            customWindows: windows,
            capturedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            modelID: provider.modelID,
            sourceKind: .remoteProvider
        )

        if snapshot.isEmpty {
            Logger.log("OpenCode provider usage mapping produced no usable windows for provider \(provider.id).", category: .source)
            return nil
        }

        return snapshot
    }

    private static func parseSpecializedUsageSnapshot(
        from jsonObject: Any,
        provider: ResolvedOpenCodeProvider
    ) -> OpenCodeUsageSnapshot? {
        switch provider.definition.id {
        case "minmax":
            return parseMinMaxUsageSnapshot(from: jsonObject, provider: provider)
        case "kimi":
            return parseKimiUsageSnapshot(from: jsonObject, provider: provider)
        case "zhipu-cn", "zhipu-en":
            return parseZhipuUsageSnapshot(from: jsonObject, provider: provider)
        default:
            return nil
        }
    }

    private static func parseMinMaxUsageSnapshot(from jsonObject: Any, provider: ResolvedOpenCodeProvider) -> OpenCodeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any],
              let entries = root["model_remains"] as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }

        let selectedEntry = selectMinMaxEntry(from: entries, provider: provider)
        guard let selectedEntry else {
            Logger.log("OpenCode provider minmax did not contain a model_remains entry matching model \(provider.modelID ?? "unknown").", category: .source)
            return nil
        }

        var windows: [OpenCodeLabeledUsageWindow] = []
        if let fiveHour = minMaxWindow(
            usageKey: "current_interval_usage_count",
            totalKey: "current_interval_total_count",
            resetKey: "end_time",
            in: selectedEntry,
            usageValueRepresentsRemaining: true
        ) {
            windows.append(OpenCodeLabeledUsageWindow(id: "five_hour", label: "5h", window: fiveHour))
        }
        if let sevenDay = minMaxWindow(
            usageKey: "current_weekly_usage_count",
            totalKey: "current_weekly_total_count",
            resetKey: "weekly_end_time",
            in: selectedEntry,
            usageValueRepresentsRemaining: true
        ) {
            windows.append(OpenCodeLabeledUsageWindow(id: "seven_day", label: "wk", window: sevenDay))
        }

        let snapshot = OpenCodeUsageSnapshot(
            customWindows: windows,
            capturedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            modelID: provider.modelID,
            sourceKind: .remoteProvider
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func parseKimiUsageSnapshot(from jsonObject: Any, provider: ResolvedOpenCodeProvider) -> OpenCodeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any] else {
            return nil
        }

        var windows: [OpenCodeLabeledUsageWindow] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limitItem in limits {
                guard let detail = limitItem["detail"] as? [String: Any] else {
                    continue
                }

                let limit = numericValue(detail["limit"]) ?? 0
                let remaining = numericValue(detail["remaining"]) ?? 0
                guard limit > 0 else {
                    continue
                }

                let usedPercentage = min(max((limit - remaining) / limit, 0), 1)
                windows.append(
                    OpenCodeLabeledUsageWindow(
                        id: "five_hour",
                        label: "5h",
                        window: OpenCodeUsageWindow(usedPercentage: usedPercentage, resetsAt: parseDate(detail["resetTime"]))
                    )
                )
                break
            }
        }

        if let usage = root["usage"] as? [String: Any] {
            let limit = numericValue(usage["limit"]) ?? 0
            let remaining = numericValue(usage["remaining"]) ?? 0
            if limit > 0 {
                let usedPercentage = min(max((limit - remaining) / limit, 0), 1)
                windows.append(
                    OpenCodeLabeledUsageWindow(
                        id: "seven_day",
                        label: "wk",
                        window: OpenCodeUsageWindow(usedPercentage: usedPercentage, resetsAt: parseDate(usage["resetTime"]))
                    )
                )
            }
        }

        let snapshot = OpenCodeUsageSnapshot(
            customWindows: windows,
            capturedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            modelID: provider.modelID,
            sourceKind: .remoteProvider
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func parseZhipuUsageSnapshot(from jsonObject: Any, provider: ResolvedOpenCodeProvider) -> OpenCodeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any],
              let success = root["success"] as? Bool,
              success,
              let data = root["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else {
            return nil
        }

        for limitItem in limits {
            let limitType = (limitItem["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard limitType == "TOKENS_LIMIT" else {
                continue
            }

            let percentageValue = numericValue(limitItem["percentage"]) ?? 0
            let usedPercentage = percentageValue > 1 ? min(max(percentageValue / 100, 0), 1) : min(max(percentageValue, 0), 1)
            let window = OpenCodeUsageWindow(usedPercentage: usedPercentage, resetsAt: parseDate(limitItem["nextResetTime"]))
            return OpenCodeUsageSnapshot(
                customWindows: [OpenCodeLabeledUsageWindow(id: "day", label: "day", window: window)],
                capturedAt: Date(),
                providerID: provider.id,
                providerDisplayName: provider.displayName,
                modelID: provider.modelID,
                sourceKind: .remoteProvider
            )
        }

        return nil
    }

    private static func parseMappedWindows(from jsonObject: Any, provider: ResolvedOpenCodeProvider) -> [OpenCodeLabeledUsageWindow] {
        var windows: [OpenCodeLabeledUsageWindow] = []

        if let fiveHour = parseWindow(mapping: provider.definition.responseMapping.fiveHour, from: jsonObject) {
            windows.append(OpenCodeLabeledUsageWindow(id: "five_hour", label: "5h", window: fiveHour))
        }
        if let sevenDay = parseWindow(mapping: provider.definition.responseMapping.sevenDay, from: jsonObject) {
            windows.append(OpenCodeLabeledUsageWindow(id: "seven_day", label: "wk", window: sevenDay))
        }
        if windows.isEmpty,
           let fallback = parseWindow(mapping: provider.definition.responseMapping.fallbackWindow, from: jsonObject) {
            windows.append(OpenCodeLabeledUsageWindow(id: "day", label: "day", window: fallback))
        }

        return windows
    }

    private static func selectMinMaxEntry(
        from entries: [[String: Any]],
        provider: ResolvedOpenCodeProvider
    ) -> [String: Any]? {
        let normalizedModelID = normalizeModelID(provider.modelID)

        if let normalizedModelID,
           let exactMatch = entries.first(where: { normalizeModelID($0["model_name"] as? String) == normalizedModelID }) {
            return exactMatch
        }

        if let normalizedModelID,
           let wildcardMatch = entries.first(where: {
               guard let modelName = $0["model_name"] as? String else { return false }
               return wildcardMatches(pattern: modelName, modelID: normalizedModelID)
           }) {
            return wildcardMatch
        }

        if let modelFamilyMatch = entries.first(where: {
            guard let modelName = ($0["model_name"] as? String)?.lowercased() else { return false }
            return modelName.contains("minimax-m")
        }) {
            return modelFamilyMatch
        }

        return entries.first
    }

    private static func minMaxWindow(
        usageKey: String,
        totalKey: String,
        resetKey: String,
        in entry: [String: Any],
        usageValueRepresentsRemaining: Bool
    ) -> OpenCodeUsageWindow? {
        guard let usage = numericValue(entry[usageKey]),
              let total = numericValue(entry[totalKey]),
              total > 0 else {
            return nil
        }

        let normalizedUsage = usageValueRepresentsRemaining ? (total - usage) : usage
        return OpenCodeUsageWindow(
            usedPercentage: min(max(normalizedUsage / total, 0), 1),
            resetsAt: parseDate(entry[resetKey])
        )
    }

    private static func applyingProviderMetadata(
        _ provider: ResolvedOpenCodeProvider,
        to snapshot: OpenCodeUsageSnapshot
    ) -> OpenCodeUsageSnapshot {
        OpenCodeUsageSnapshot(
            customWindows: snapshot.customWindows,
            capturedAt: snapshot.capturedAt,
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            modelID: provider.modelID,
            sourceKind: .remoteProvider
        )
    }

    private static func loadCommandUsageSnapshot(
        definition usageCommand: OpenCodeProviderUsageCommand,
        provider: ResolvedOpenCodeProvider?
    ) -> OpenCodeUsageSnapshot? {
        guard let commandOutput = runUsageCommand(usageCommand),
              let percentageValue = normalizedPercentageString(commandOutput),
              let usedPercentage = usedPercentage(from: percentageValue, valueKind: usageCommand.valueKind) else {
            Logger.log("OpenCode usage command returned no usable percentage.", category: .source)
            return nil
        }

        let window = OpenCodeUsageWindow(usedPercentage: usedPercentage, resetsAt: nil)
        let labeledWindow = OpenCodeLabeledUsageWindow(
            id: usageCommand.window.rawValue,
            label: usageCommand.displayLabel ?? usageCommand.window.defaultLabel,
            window: window
        )

        return OpenCodeUsageSnapshot(
            customWindows: [labeledWindow],
            capturedAt: Date(),
            providerID: provider?.id,
            providerDisplayName: provider?.displayName,
            modelID: provider?.modelID,
            sourceKind: .remoteProvider
        )
    }

    private static func usedPercentage(
        from percentageValue: Double,
        valueKind: OpenCodeProviderUsageCommandValueKind
    ) -> Double? {
        switch valueKind {
        case .usedPercentage:
            return percentageValue
        case .remainingPercentage:
            return max(0, 1 - percentageValue)
        }
    }

    private static func fetchUsageResponse(for provider: ResolvedOpenCodeProvider) throws -> Any? {
        var components = URLComponents(string: provider.definition.usageRequest.url)
        if let query = provider.definition.usageRequest.query, !query.isEmpty {
            var items = components?.queryItems ?? []
            items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: provider.replacingTemplateTokens(in: $0.value)) })
            components?.queryItems = items
        }

        guard let url = components?.url else {
            Logger.log("OpenCode provider \(provider.id) has invalid usage URL.", category: .source)
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = provider.definition.usageRequest.method
        request.timeoutInterval = requestTimeout

        if let headers = provider.definition.usageRequest.headers {
            for (key, value) in headers {
                request.setValue(provider.replacingTemplateTokens(in: value), forHTTPHeaderField: key)
            }
        }

        if let authEnvKey = provider.definition.usageRequest.authEnvKey {
            guard let token = provider.resolveAuthorizationToken(from: authEnvKey) else {
                Logger.log("OpenCode provider \(provider.id) is missing auth token.", category: .source)
                return nil
            }
            let authHeaderName = provider.definition.usageRequest.authHeaderName ?? "Authorization"
            let authPrefix = provider.definition.usageRequest.authPrefix ?? "Bearer "
            request.setValue("\(authPrefix)\(token)", forHTTPHeaderField: authHeaderName)
        }

        if let body = provider.definition.usageRequest.body, !body.isEmpty {
            let resolvedBody = body.mapValues { provider.replacingTemplateTokens(in: $0) }
            request.httpBody = try JSONSerialization.data(withJSONObject: resolvedBody, options: [])
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = OpenCodeUsageResponseBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            responseBox.data = data
            responseBox.error = error
            responseBox.statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let responseError = responseBox.error {
            Logger.log("OpenCode provider \(provider.id) usage request failed: \(responseError.localizedDescription)", category: .source)
            return nil
        }

        guard let statusCode = responseBox.statusCode,
              (200 ..< 300).contains(statusCode),
              let responseData = responseBox.data else {
            Logger.log("OpenCode provider \(provider.id) usage request returned invalid status \(responseBox.statusCode.map(String.init) ?? "nil").", category: .source)
            return nil
        }

        do {
            return try JSONSerialization.jsonObject(with: responseData)
        } catch {
            Logger.log("OpenCode provider \(provider.id) usage response is not valid JSON: \(error.localizedDescription)", category: .source)
            return nil
        }
    }

    private static func resolveProvider(
        context: OpenCodeUsageContext?,
        openCodeConfig: [String: Any],
        usageConfig: OpenCodeProviderUsageConfig
    ) -> ResolvedOpenCodeProvider? {
        let configProviderHint = configuredProviderHint(from: openCodeConfig)
        let providerID = context?.providerID ?? configProviderHint.providerID
        let modelID = context?.modelID ?? configProviderHint.modelID
        let providerConfig = providerID.flatMap { value(at: "provider.\($0)", in: openCodeConfig) as? [String: Any] }
        let providerName = normalizedString(providerConfig?["name"]) ?? providerID
        let options = providerConfig?["options"] as? [String: Any] ?? [:]
        let baseURL = normalizedString(options["baseURL"] ?? options["baseUrl"])
        let rawAPIKey = normalizedString(options["apiKey"])
        let apiKey = rawAPIKey.flatMap { resolveOpenCodeTemplateTokens($0, cwd: context?.cwd) }

        for definition in usageConfig.providers {
            guard matches(definition.match, providerID: providerID, modelID: modelID, baseURL: baseURL) else {
                continue
            }

            return ResolvedOpenCodeProvider(
                id: providerID ?? definition.id,
                displayName: providerName ?? definition.displayName,
                baseURL: baseURL,
                modelID: modelID,
                apiKey: apiKey,
                definition: definition
            )
        }

        return nil
    }

    private static func configuredProviderHint(from openCodeConfig: [String: Any]) -> (providerID: String?, modelID: String?) {
        guard let model = normalizedString(openCodeConfig["model"]) else {
            return (nil, nil)
        }

        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return (nil, model)
        }

        return (parts[0], parts[1])
    }

    private static func matches(
        _ rule: OpenCodeProviderMatchRule,
        providerID: String?,
        modelID: String?,
        baseURL: String?
    ) -> Bool {
        if let providerID = providerID?.lowercased(),
           rule.providerIDs.contains(where: { providerID == $0.lowercased() }) {
            return true
        }

        if let baseURL = baseURL?.lowercased() {
            if let host = URL(string: baseURL)?.host?.lowercased(),
               rule.baseURLHosts.contains(where: { host.contains($0.lowercased()) }) {
                return true
            }

            if rule.baseURLPrefixes.contains(where: { baseURL.hasPrefix($0.lowercased()) }) {
                return true
            }
        }

        guard let modelID = modelID?.lowercased() else {
            return false
        }

        return rule.modelPrefixes.contains { modelID.hasPrefix($0.lowercased()) || modelID.contains($0.lowercased()) }
    }

    private static func loadLatestContext() -> OpenCodeUsageContext? {
        guard FileManager.default.fileExists(atPath: FilePaths.openCodeDatabase.path) else {
            return nil
        }

        let sql = """
        select json_object(
          'sessionID', message.session_id,
          'messageData', message.data,
          'directory', session.directory,
          'timeUpdated', message.time_updated
        )
        from message
        join session on session.id = message.session_id
        where json_extract(message.data, '$.providerID') is not null
           or json_extract(message.data, '$.model.providerID') is not null
        order by message.time_updated desc
        limit 1;
        """

        guard let row = runSQLiteRows(sql: sql)?.first,
              let data = row.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageData = jsonDictionaryString(raw["messageData"]) else {
            return nil
        }

        return OpenCodeUsageContext(
            sessionID: normalizedString(raw["sessionID"]),
            providerID: normalizedString(messageData["providerID"]) ?? normalizedString(value(at: ["model", "providerID"], in: messageData)),
            modelID: normalizedString(messageData["modelID"]) ?? normalizedString(value(at: ["model", "modelID"], in: messageData)),
            cwd: normalizedString(raw["directory"])
        )
    }

    private static func loadMergedOpenCodeConfig(cwd: String?) throws -> [String: Any] {
        var merged: [String: Any] = [:]
        for url in openCodeConfigURLs(cwd: cwd) {
            guard let object = try loadJSONObjectIfPresent(at: url) else {
                continue
            }
            merged = merge(merged, object)
        }
        return merged
    }

    private static func openCodeConfigURLs(cwd: String?) -> [URL] {
        var urls: [URL] = [
            FilePaths.openCodeConfigFile,
            FilePaths.openCodeConfigDirectory.appendingPathComponent("opencode.jsonc", isDirectory: false)
        ]

        if let customPath = ProcessInfo.processInfo.environment["OPENCODE_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            urls.append(FilePaths.expandingTilde(customPath))
        }

        urls.append(contentsOf: projectConfigURLs(cwd: cwd))

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private static func projectConfigURLs(cwd: String?) -> [URL] {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var directories: [URL] = []
        var current = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while true {
            directories.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return directories.reversed().flatMap { directory in
            [
                directory.appendingPathComponent("opencode.json", isDirectory: false),
                directory.appendingPathComponent("opencode.jsonc", isDirectory: false)
            ]
        }
    }

    private static func merge(_ lhs: [String: Any], _ rhs: [String: Any]) -> [String: Any] {
        var result = lhs
        for (key, value) in rhs {
            if let existing = result[key] as? [String: Any],
               let incoming = value as? [String: Any] {
                result[key] = merge(existing, incoming)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func loadProviderConfig() throws -> OpenCodeProviderUsageConfig {
        let fileURL = FilePaths.claudeProviderUsageConfig
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return OpenCodeProviderUsageConfig.defaultConfig
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(OpenCodeProviderUsageConfig.self, from: data)
        } catch {
            Logger.log("Shared provider usage config at \(fileURL.path) is invalid for OpenCode, falling back to defaults: \(error.localizedDescription)", category: .source)
            return OpenCodeProviderUsageConfig.defaultConfig
        }
    }

    private static func ensureProviderConfigFileExists() throws {
        let fileManager = FileManager.default
        let fileURL = FilePaths.claudeProviderUsageConfig
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        try fileManager.createDirectory(at: FilePaths.hermitFlowHome, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ClaudeProviderUsageConfig.defaultConfig)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadJSONObjectIfPresent(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return [:]
        }

        let object = try parseRelaxedJSONObjectData(data, sourcePath: url.path)
        return object as? [String: Any]
    }

    private static func parseRelaxedJSONObjectData(_ data: Data, sourcePath: String) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenCodeUsageLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: sourcePath])
        }

        let commentFree = stripJSONComments(text)
        let relaxedText = commentFree.replacingOccurrences(
            of: ",(\\s*[\\]\\}])",
            with: "$1",
            options: .regularExpression
        )

        guard let relaxedData = relaxedText.data(using: .utf8) else {
            throw NSError(domain: "OpenCodeUsageLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: sourcePath])
        }

        return try JSONSerialization.jsonObject(with: relaxedData)
    }

    private static func stripJSONComments(_ text: String) -> String {
        var output = ""
        var isInString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let nextCharacter = nextIndex < text.endIndex ? text[nextIndex] : nil

            if isInString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                isInString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                index = nextIndex
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }

            if character == "/", nextCharacter == "*" {
                index = text.index(after: nextIndex)
                while index < text.endIndex {
                    let after = text.index(after: index)
                    if text[index] == "*", after < text.endIndex, text[after] == "/" {
                        index = text.index(after: after)
                        break
                    }
                    index = after
                }
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func resolveOpenCodeTemplateTokens(_ value: String, cwd: String?) -> String? {
        var resolved = value
        resolved = replacingTemplateMatches(in: resolved, pattern: "\\{env:([^}]+)\\}") { token in
            ProcessInfo.processInfo.environment[token] ?? ""
        }
        resolved = replacingTemplateMatches(in: resolved, pattern: "\\{file:([^}]+)\\}") { path in
            readTemplateFile(path, cwd: cwd) ?? ""
        }

        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func replacingTemplateMatches(
        in value: String,
        pattern: String,
        replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        for match in matches {
            guard match.numberOfRanges == 2,
                  let wholeRange = Range(match.range(at: 0), in: result),
                  let tokenRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let token = String(result[tokenRange])
            result.replaceSubrange(wholeRange, with: replacement(token))
        }
        return result
    }

    private static func readTemplateFile(_ rawPath: String, cwd: String?) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidates: [URL]
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            candidates = [FilePaths.expandingTilde(trimmed)]
        } else {
            var relativeBases: [URL] = [FilePaths.openCodeConfigDirectory]
            if let cwd, !cwd.isEmpty {
                relativeBases.insert(URL(fileURLWithPath: cwd, isDirectory: true), at: 0)
            }
            candidates = relativeBases.map { $0.appendingPathComponent(trimmed, isDirectory: false) }
        }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                return trimmedText
            }
        }
        return nil
    }

    private static func parseWindow(mapping: OpenCodeProviderWindowMapping?, from jsonObject: Any) -> OpenCodeUsageWindow? {
        guard let mapping else {
            return nil
        }

        if let object = mapping.objectPaths.lazy.compactMap({ value(at: $0, in: jsonObject) }).first {
            return window(from: object)
        }

        let usedPercentage = firstNormalizedPercentage(at: mapping.usedPercentagePaths, in: jsonObject)
        let remainingPercentage = firstNormalizedPercentage(at: mapping.remainingPercentagePaths, in: jsonObject)
        let resetsAt = firstDate(at: mapping.resetAtPaths, in: jsonObject)

        if let usedPercentage {
            return OpenCodeUsageWindow(usedPercentage: usedPercentage, resetsAt: resetsAt)
        }

        if let remainingPercentage {
            return OpenCodeUsageWindow(usedPercentage: max(0, 1 - remainingPercentage), resetsAt: resetsAt)
        }

        return heuristicWindow(from: jsonObject, labels: mapping.labelHints)
    }

    private static func heuristicWindow(from jsonObject: Any, labels: [String]) -> OpenCodeUsageWindow? {
        let loweredLabels = labels.map { $0.lowercased() }
        guard let object = findDictionary(matchingAnyOf: loweredLabels, in: jsonObject) else {
            return nil
        }
        return window(from: object)
    }

    private static func window(from value: Any) -> OpenCodeUsageWindow? {
        if let container = value as? [String: Any] {
            if let usedPercentage = normalizedPercentage(
                container["used_percentage"] ?? container["usage_percentage"] ?? container["utilization"] ?? container["used"]
            ) {
                return OpenCodeUsageWindow(
                    usedPercentage: usedPercentage,
                    resetsAt: parseDate(container["resets_at"] ?? container["reset_at"] ?? container["resetAt"])
                )
            }

            if let remainingPercentage = normalizedPercentage(
                container["remaining_percentage"] ?? container["remaining"] ?? container["remains"] ?? container["left_percentage"]
            ) {
                return OpenCodeUsageWindow(
                    usedPercentage: max(0, 1 - remainingPercentage),
                    resetsAt: parseDate(container["resets_at"] ?? container["reset_at"] ?? container["resetAt"])
                )
            }
        }

        if let number = normalizedPercentage(value) {
            return OpenCodeUsageWindow(usedPercentage: max(0, 1 - number), resetsAt: nil)
        }

        return nil
    }

    private static func firstNormalizedPercentage(at paths: [String], in jsonObject: Any) -> Double? {
        for path in paths {
            if let percentage = normalizedPercentage(value(at: path, in: jsonObject)) {
                return percentage
            }
        }
        return nil
    }

    private static func firstDate(at paths: [String], in jsonObject: Any) -> Date? {
        for path in paths {
            if let date = parseDate(value(at: path, in: jsonObject)) {
                return date
            }
        }
        return nil
    }

    private static func findDictionary(matchingAnyOf labels: [String], in jsonObject: Any) -> [String: Any]? {
        if let dictionary = jsonObject as? [String: Any] {
            for (key, value) in dictionary {
                if labels.contains(where: { key.lowercased().contains($0) }),
                   let nested = value as? [String: Any] {
                    return nested
                }
            }

            for value in dictionary.values {
                if let nested = findDictionary(matchingAnyOf: labels, in: value) {
                    return nested
                }
            }
        }

        if let array = jsonObject as? [Any] {
            for value in array {
                if let nested = findDictionary(matchingAnyOf: labels, in: value) {
                    return nested
                }
            }
        }

        return nil
    }

    private static func value(at path: String, in jsonObject: Any) -> Any? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return trimmedPath
            .split(separator: ".")
            .reduce(Optional(jsonObject)) { partial, component in
                guard let partial else {
                    return nil
                }

                if let dictionary = partial as? [String: Any] {
                    return dictionary[String(component)]
                }

                if let array = partial as? [Any], let index = Int(component), array.indices.contains(index) {
                    return array[index]
                }

                return nil
            }
    }

    private static func value(at path: [String], in payload: [String: Any]) -> Any? {
        var current: Any = payload
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
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

    private static func normalizedPercentageString(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let hadPercentSuffix = trimmed.hasSuffix("%")
        let normalizedInput = hadPercentSuffix
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed

        guard let rawValue = Double(normalizedInput) else {
            return nil
        }

        if hadPercentSuffix || rawValue > 1 {
            return min(max(rawValue / 100, 0), 1)
        }

        return min(max(rawValue, 0), 1)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let rawValue = number.doubleValue
            if rawValue > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: rawValue / 1000)
            }
            return Date(timeIntervalSince1970: rawValue)
        case let string as String:
            if let timestamp = Double(string) {
                if timestamp > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: timestamp / 1000)
                }
                return Date(timeIntervalSince1970: timestamp)
            }
            if let date = ISO8601DateFormatter().date(from: string) {
                return date
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: string)
        default:
            return nil
        }
    }

    private static func normalizeModelID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func wildcardMatches(pattern: String, modelID: String) -> Bool {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPattern.isEmpty else {
            return false
        }

        if normalizedPattern.contains("*") {
            let prefix = normalizedPattern.replacingOccurrences(of: "*", with: "")
            return modelID.hasPrefix(prefix)
        }

        return modelID == normalizedPattern
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonDictionaryString(_ value: Any?) -> [String: Any]? {
        guard let string = normalizedString(value),
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func runSQLiteRows(sql: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", FilePaths.openCodeDatabase.path, sql]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = output?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        return rows.isEmpty ? nil : rows
    }

    private static func runUsageCommand(_ definition: OpenCodeProviderUsageCommand) -> String? {
        guard let command = definition.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            Logger.log("OpenCode usage command is empty.", category: .source)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Logger.log("OpenCode usage command failed to launch: \(error.localizedDescription)", category: .source)
            return nil
        }

        let timeout = definition.timeoutSeconds ?? defaultCommandTimeout
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
            Logger.log("OpenCode usage command timed out after \(timeout)s.", category: .source)
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Logger.log("OpenCode usage command exited with status \(process.terminationStatus). \(stderrText)", category: .source)
            return nil
        }

        guard let stdoutText = String(data: stdoutData, encoding: .utf8) else {
            Logger.log("OpenCode usage command output is not UTF-8.", category: .source)
            return nil
        }

        return stdoutText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

private struct OpenCodeUsageContext {
    let sessionID: String?
    let providerID: String?
    let modelID: String?
    let cwd: String?
}

private final class OpenCodeUsageResponseBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
    var statusCode: Int?
}

private struct ResolvedOpenCodeProvider: Hashable {
    let id: String
    let displayName: String
    let baseURL: String?
    let modelID: String?
    let apiKey: String?
    let definition: OpenCodeProviderDefinition

    func replacingTemplateTokens(in value: String) -> String {
        var resolved = value
        if let baseURL {
            resolved = resolved.replacingOccurrences(of: "{{baseURL}}", with: baseURL)
        }
        if let modelID {
            resolved = resolved.replacingOccurrences(of: "{{modelID}}", with: modelID)
        }
        return resolved
    }

    func resolveAuthorizationToken(from authEnvKey: String) -> String? {
        let trimmed = authEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return apiKey
        }

        if trimmed == "apiKey" || trimmed.hasPrefix("ANTHROPIC_") {
            return apiKey
        }

        if trimmed.hasPrefix("sk-") {
            return trimmed
        }

        if let envValue = ProcessInfo.processInfo.environment[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }

        return apiKey
    }
}

struct OpenCodeProviderUsageConfig: Codable, Hashable {
    var usageCommand: OpenCodeProviderUsageCommand?
    var providers: [OpenCodeProviderDefinition]

    static let defaultConfig = OpenCodeProviderUsageConfig(
        usageCommand: OpenCodeProviderUsageCommand(
            command: nil,
            window: .day,
            valueKind: .usedPercentage,
            timeoutSeconds: 5,
            displayLabel: "day"
        ),
        providers: [
            OpenCodeProviderDefinition(
                id: "kimi",
                displayName: "Kimi",
                match: OpenCodeProviderMatchRule(
                    providerIDs: ["kimi", "moonshot"],
                    baseURLHosts: ["api.kimi.com"],
                    baseURLPrefixes: ["https://api.kimi.com/coding"],
                    modelPrefixes: ["kimi", "moonshot"]
                ),
                usageRequest: OpenCodeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.kimi.com/coding/v1/usages",
                    authEnvKey: "apiKey",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: ["Accept": "application/json"],
                    query: nil,
                    body: nil
                ),
                responseMapping: OpenCodeProviderResponseMapping(fiveHour: nil, sevenDay: nil, fallbackWindow: nil)
            ),
            OpenCodeProviderDefinition(
                id: "zhipu-cn",
                displayName: "Zhipu",
                match: OpenCodeProviderMatchRule(
                    providerIDs: ["zhipu", "zhipu-cn"],
                    baseURLHosts: ["open.bigmodel.cn", "bigmodel.cn"],
                    baseURLPrefixes: ["https://open.bigmodel.cn", "https://bigmodel.cn"],
                    modelPrefixes: ["glm", "zhipu"]
                ),
                usageRequest: OpenCodeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.z.ai/api/monitor/usage/quota/limit",
                    authEnvKey: "apiKey",
                    authHeaderName: "Authorization",
                    authPrefix: "",
                    headers: [
                        "Content-Type": "application/json",
                        "Accept-Language": "en-US,en"
                    ],
                    query: nil,
                    body: nil
                ),
                responseMapping: OpenCodeProviderResponseMapping(fiveHour: nil, sevenDay: nil, fallbackWindow: nil)
            ),
            OpenCodeProviderDefinition(
                id: "zhipu-en",
                displayName: "Zhipu",
                match: OpenCodeProviderMatchRule(
                    providerIDs: ["zhipu-en"],
                    baseURLHosts: ["api.z.ai"],
                    baseURLPrefixes: ["https://api.z.ai"],
                    modelPrefixes: ["glm", "zhipu"]
                ),
                usageRequest: OpenCodeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.z.ai/api/monitor/usage/quota/limit",
                    authEnvKey: "apiKey",
                    authHeaderName: "Authorization",
                    authPrefix: "",
                    headers: [
                        "Content-Type": "application/json",
                        "Accept-Language": "en-US,en"
                    ],
                    query: nil,
                    body: nil
                ),
                responseMapping: OpenCodeProviderResponseMapping(fiveHour: nil, sevenDay: nil, fallbackWindow: nil)
            ),
            OpenCodeProviderDefinition(
                id: "zenmux",
                displayName: "ZenMux",
                match: OpenCodeProviderMatchRule(
                    providerIDs: ["zenmux"],
                    baseURLHosts: ["zenmux.ai"],
                    baseURLPrefixes: ["https://zenmux.ai/"],
                    modelPrefixes: ["zenmux", "anthropic/claude"]
                ),
                usageRequest: OpenCodeProviderUsageRequest(
                    method: "GET",
                    url: "https://zenmux.ai/api/v1/management/subscription/detail",
                    authEnvKey: "apiKey",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: [:],
                    query: nil,
                    body: nil
                ),
                responseMapping: OpenCodeProviderResponseMapping(
                    fiveHour: OpenCodeProviderWindowMapping(
                        objectPaths: ["data.quota_5_hour"],
                        usedPercentagePaths: ["data.quota_5_hour.usage_percentage"],
                        remainingPercentagePaths: [],
                        resetAtPaths: ["data.quota_5_hour.resets_at"],
                        labelHints: ["quota_5_hour", "5_hour", "5h"]
                    ),
                    sevenDay: OpenCodeProviderWindowMapping(
                        objectPaths: ["data.quota_7_day"],
                        usedPercentagePaths: ["data.quota_7_day.usage_percentage"],
                        remainingPercentagePaths: [],
                        resetAtPaths: ["data.quota_7_day.resets_at"],
                        labelHints: ["quota_7_day", "7_day", "7d"]
                    ),
                    fallbackWindow: nil
                )
            ),
            OpenCodeProviderDefinition(
                id: "minmax",
                displayName: "MinMax",
                match: OpenCodeProviderMatchRule(
                    providerIDs: ["minmax"],
                    baseURLHosts: ["minimaxi.com", "minmax"],
                    baseURLPrefixes: ["https://www.minimaxi.com/", "https://api.minimax.chat/", "https://api.minimaxi.com/"],
                    modelPrefixes: ["minmax", "minimax", "MiniMax"]
                ),
                usageRequest: OpenCodeProviderUsageRequest(
                    method: "GET",
                    url: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
                    authEnvKey: "apiKey",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: [:],
                    query: nil,
                    body: nil
                ),
                responseMapping: OpenCodeProviderResponseMapping(
                    fiveHour: nil,
                    sevenDay: nil,
                    fallbackWindow: nil
                )
            )
        ]
    )
}

struct OpenCodeProviderDefinition: Codable, Hashable {
    var id: String
    var displayName: String
    var match: OpenCodeProviderMatchRule
    var usageRequest: OpenCodeProviderUsageRequest
    var responseMapping: OpenCodeProviderResponseMapping
}

struct OpenCodeProviderMatchRule: Codable, Hashable {
    var providerIDs: [String]
    var baseURLHosts: [String]
    var baseURLPrefixes: [String]
    var modelPrefixes: [String]

    enum CodingKeys: String, CodingKey {
        case providerIDs
        case baseURLHosts
        case baseURLPrefixes
        case modelPrefixes
    }

    init(
        providerIDs: [String],
        baseURLHosts: [String],
        baseURLPrefixes: [String],
        modelPrefixes: [String]
    ) {
        self.providerIDs = providerIDs
        self.baseURLHosts = baseURLHosts
        self.baseURLPrefixes = baseURLPrefixes
        self.modelPrefixes = modelPrefixes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerIDs = try container.decodeIfPresent([String].self, forKey: .providerIDs) ?? []
        baseURLHosts = try container.decodeIfPresent([String].self, forKey: .baseURLHosts) ?? []
        baseURLPrefixes = try container.decodeIfPresent([String].self, forKey: .baseURLPrefixes) ?? []
        modelPrefixes = try container.decodeIfPresent([String].self, forKey: .modelPrefixes) ?? []
    }
}

struct OpenCodeProviderUsageRequest: Codable, Hashable {
    var method: String
    var url: String
    var authEnvKey: String?
    var authHeaderName: String?
    var authPrefix: String?
    var headers: [String: String]?
    var query: [String: String]?
    var body: [String: String]?
}

enum OpenCodeProviderUsageCommandWindow: String, Codable, Hashable {
    case day

    var defaultLabel: String {
        switch self {
        case .day:
            return "day"
        }
    }
}

enum OpenCodeProviderUsageCommandValueKind: String, Codable, Hashable {
    case usedPercentage
    case remainingPercentage
}

struct OpenCodeProviderUsageCommand: Codable, Hashable {
    var command: String?
    var window: OpenCodeProviderUsageCommandWindow
    var valueKind: OpenCodeProviderUsageCommandValueKind
    var timeoutSeconds: TimeInterval?
    var displayLabel: String?
}

struct OpenCodeProviderResponseMapping: Codable, Hashable {
    var fiveHour: OpenCodeProviderWindowMapping?
    var sevenDay: OpenCodeProviderWindowMapping?
    var fallbackWindow: OpenCodeProviderWindowMapping?
}

struct OpenCodeProviderWindowMapping: Codable, Hashable {
    var objectPaths: [String]
    var usedPercentagePaths: [String]
    var remainingPercentagePaths: [String]
    var resetAtPaths: [String]
    var labelHints: [String]
}
