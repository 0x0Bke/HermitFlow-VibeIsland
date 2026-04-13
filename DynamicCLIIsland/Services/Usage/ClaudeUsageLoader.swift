//
//  ClaudeUsageLoader.swift
//  HermitFlow
//
//  Local-first Claude usage loader with third-party provider fallback.
//

import Foundation

enum ClaudeUsageLoader {
    private static let customSettingsPathsEnvironmentKey = "HERMITFLOW_CLAUDE_SETTINGS_PATHS"
    private static let requestTimeout: TimeInterval = 5
    private static let defaultCommandTimeout: TimeInterval = 5

    static func load() throws -> ClaudeUsageSnapshot? {
        try ensureProviderConfigFileExists()

        if let cachedSnapshot = try loadCachedUsageSnapshot() {
            let provider = try? resolveProvider()
            return applyingProviderMetadata(provider, to: cachedSnapshot, sourceKind: .localCache)
        }

        let config = try loadProviderConfig()

        if let usageCommand = config.usageCommand,
           let command = usageCommand.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return try loadCommandUsageSnapshot(definition: usageCommand)
        }

        guard let provider = try resolveProvider(config: config) else {
            return nil
        }

        guard let remoteSnapshot = try loadRemoteUsageSnapshot(for: provider) else {
            return nil
        }

        return applyingProviderMetadata(provider, to: remoteSnapshot, sourceKind: .remoteProvider)
    }

    private static func loadCachedUsageSnapshot() throws -> ClaudeUsageSnapshot? {
        let usageFileURL = FilePaths.claudeUsageCache
        guard FileManager.default.fileExists(atPath: usageFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: usageFileURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let cachedAt = try usageFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: parseWindow(named: "five_hour", from: jsonObject),
            sevenDay: parseWindow(named: "seven_day", from: jsonObject),
            customWindows: [],
            cachedAt: cachedAt,
            providerID: nil,
            providerDisplayName: nil,
            sourceKind: .localCache
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func loadRemoteUsageSnapshot(for provider: ResolvedClaudeProvider) throws -> ClaudeUsageSnapshot? {
        let responseObject = try fetchUsageResponse(for: provider)
        guard let responseObject else {
            return nil
        }

        if let specializedSnapshot = parseSpecializedUsageSnapshot(from: responseObject, provider: provider) {
            return specializedSnapshot
        }

        let fiveHour = parseWindow(mapping: provider.definition.responseMapping.fiveHour, from: responseObject)
        let sevenDay = parseWindow(mapping: provider.definition.responseMapping.sevenDay, from: responseObject)
        let fallbackWindow = parseWindow(mapping: provider.definition.responseMapping.fallbackWindow, from: responseObject)

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: fiveHour ?? fallbackWindow,
            sevenDay: sevenDay,
            customWindows: [],
            cachedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            sourceKind: .remoteProvider
        )

        if snapshot.isEmpty {
            Logger.log(
                "Claude third-party usage mapping produced no usable windows for provider \(provider.id).",
                category: .source
            )
            return nil
        }

        return snapshot
    }

    private static func parseSpecializedUsageSnapshot(
        from jsonObject: Any,
        provider: ResolvedClaudeProvider
    ) -> ClaudeUsageSnapshot? {
        switch provider.id {
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

    private static func parseMinMaxUsageSnapshot(from jsonObject: Any, provider: ResolvedClaudeProvider) -> ClaudeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any],
              let entries = root["model_remains"] as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }

        let selectedEntry = selectMinMaxEntry(from: entries, provider: provider)
        guard let selectedEntry else {
            Logger.log(
                "Claude provider minmax did not contain a model_remains entry matching model \(provider.modelID ?? "unknown").",
                category: .source
            )
            return nil
        }

        let fiveHour = minMaxWindow(
            usageKey: "current_interval_usage_count",
            totalKey: "current_interval_total_count",
            resetKey: "end_time",
            in: selectedEntry,
            usageValueRepresentsRemaining: true
        )
        let sevenDay = minMaxWindow(
            usageKey: "current_weekly_usage_count",
            totalKey: "current_weekly_total_count",
            resetKey: "weekly_end_time",
            in: selectedEntry,
            usageValueRepresentsRemaining: true
        )

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            customWindows: [],
            cachedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            sourceKind: .remoteProvider
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func parseKimiUsageSnapshot(from jsonObject: Any, provider: ResolvedClaudeProvider) -> ClaudeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any] else {
            return nil
        }

        var fiveHour: ClaudeUsageWindow?
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
                fiveHour = ClaudeUsageWindow(
                    usedPercentage: usedPercentage,
                    resetsAt: parseDate(detail["resetTime"])
                )
                break
            }
        }

        var sevenDay: ClaudeUsageWindow?
        if let usage = root["usage"] as? [String: Any] {
            let limit = numericValue(usage["limit"]) ?? 0
            let remaining = numericValue(usage["remaining"]) ?? 0
            if limit > 0 {
                let usedPercentage = min(max((limit - remaining) / limit, 0), 1)
                sevenDay = ClaudeUsageWindow(
                    usedPercentage: usedPercentage,
                    resetsAt: parseDate(usage["resetTime"])
                )
            }
        }

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            customWindows: [],
            cachedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            sourceKind: .remoteProvider
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func parseZhipuUsageSnapshot(from jsonObject: Any, provider: ResolvedClaudeProvider) -> ClaudeUsageSnapshot? {
        guard let root = jsonObject as? [String: Any],
              let success = root["success"] as? Bool,
              success,
              let data = root["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else {
            return nil
        }

        var fiveHour: ClaudeUsageWindow?
        for limitItem in limits {
            let limitType = (limitItem["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard limitType == "TOKENS_LIMIT" else {
                continue
            }

            let percentageValue = numericValue(limitItem["percentage"]) ?? 0
            let usedPercentage = percentageValue > 1 ? min(max(percentageValue / 100, 0), 1) : min(max(percentageValue, 0), 1)
            fiveHour = ClaudeUsageWindow(
                usedPercentage: usedPercentage,
                resetsAt: parseDate(limitItem["nextResetTime"])
            )
            break
        }

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: nil,
            customWindows: [],
            cachedAt: Date(),
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            sourceKind: .remoteProvider
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func selectMinMaxEntry(
        from entries: [[String: Any]],
        provider: ResolvedClaudeProvider
    ) -> [String: Any]? {
        let normalizedModelID = normalizeMinMaxModelID(provider.modelID)

        if let normalizedModelID,
           let exactMatch = entries.first(where: { normalizeMinMaxModelID($0["model_name"] as? String) == normalizedModelID }) {
            return exactMatch
        }

        if let normalizedModelID,
           let wildcardMatch = entries.first(where: {
               guard let modelName = $0["model_name"] as? String else { return false }
               return minMaxWildcardMatches(pattern: modelName, modelID: normalizedModelID)
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

    private static func normalizeMinMaxModelID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed.lowercased()
    }

    private static func minMaxWildcardMatches(pattern: String, modelID: String) -> Bool {
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

    private static func minMaxWindow(
        usageKey: String,
        totalKey: String,
        resetKey: String,
        in entry: [String: Any],
        usageValueRepresentsRemaining: Bool = false
    ) -> ClaudeUsageWindow? {
        guard let usage = numericValue(entry[usageKey]),
              let total = numericValue(entry[totalKey]),
              total > 0 else {
            return nil
        }

        let normalizedUsage = usageValueRepresentsRemaining ? (total - usage) : usage
        let usedPercentage = min(max(normalizedUsage / total, 0), 1)
        return ClaudeUsageWindow(
            usedPercentage: usedPercentage,
            resetsAt: parseDate(entry[resetKey])
        )
    }

    private static func applyingProviderMetadata(
        _ provider: ResolvedClaudeProvider?,
        to snapshot: ClaudeUsageSnapshot,
        sourceKind: ClaudeUsageSourceKind
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: snapshot.fiveHour,
            sevenDay: snapshot.sevenDay,
            customWindows: snapshot.customWindows,
            cachedAt: snapshot.cachedAt,
            providerID: provider?.id,
            providerDisplayName: provider?.displayName,
            sourceKind: sourceKind
        )
    }

    private static func loadCommandUsageSnapshot(definition usageCommand: ClaudeProviderUsageCommand) throws -> ClaudeUsageSnapshot? {
        guard let commandOutput = runUsageCommand(usageCommand),
              let percentageValue = normalizedPercentageString(commandOutput),
              let usedPercentage = usedPercentage(from: percentageValue, valueKind: usageCommand.valueKind) else {
            Logger.log(
                "Claude usage command returned no usable percentage.",
                category: .source
            )
            return nil
        }

        let window = ClaudeUsageWindow(usedPercentage: usedPercentage, resetsAt: nil)
        let labeledWindow = ClaudeLabeledUsageWindow(
            id: usageCommand.window.rawValue,
            label: usageCommand.displayLabel ?? usageCommand.window.defaultLabel,
            window: window
        )

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: nil,
            sevenDay: nil,
            customWindows: [labeledWindow],
            cachedAt: Date(),
            providerID: nil,
            providerDisplayName: nil,
            sourceKind: .remoteProvider
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private static func usedPercentage(
        from percentageValue: Double,
        valueKind: ClaudeProviderUsageCommandValueKind
    ) -> Double? {
        switch valueKind {
        case .usedPercentage:
            return percentageValue
        case .remainingPercentage:
            return max(0, 1 - percentageValue)
        }
    }

    private static func fetchUsageResponse(for provider: ResolvedClaudeProvider) throws -> Any? {
        var components = URLComponents(string: provider.definition.usageRequest.url)
        if let query = provider.definition.usageRequest.query, !query.isEmpty {
            var items = components?.queryItems ?? []
            items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: provider.replacingTemplateTokens(in: $0.value)) })
            components?.queryItems = items
        }

        guard let url = components?.url else {
            Logger.log("Claude provider \(provider.id) has invalid usage URL.", category: .source)
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
                Logger.log(
                    "Claude provider \(provider.id) is missing auth token for authEnvKey \(authEnvKey).",
                    category: .source
                )
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
        let responseBox = ClaudeUsageResponseBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseBox.data = data
            responseBox.error = error
            responseBox.statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let responseError = responseBox.error {
            Logger.log(
                "Claude provider \(provider.id) usage request failed: \(responseError.localizedDescription)",
                category: .source
            )
            return nil
        }

        guard let statusCode = responseBox.statusCode,
              (200 ..< 300).contains(statusCode),
              let responseData = responseBox.data else {
            Logger.log(
                "Claude provider \(provider.id) usage request returned invalid status \(responseBox.statusCode.map(String.init) ?? "nil").",
                category: .source
            )
            return nil
        }

        do {
            return try JSONSerialization.jsonObject(with: responseData)
        } catch {
            Logger.log(
                "Claude provider \(provider.id) usage response is not valid JSON: \(error.localizedDescription)",
                category: .source
            )
            return nil
        }
    }

    private static func resolveProvider(config: ClaudeProviderUsageConfig? = nil) throws -> ResolvedClaudeProvider? {
        let config = try config ?? loadProviderConfig()
        let settingsCandidates = try resolvedClaudeSettingsCandidates()
        let statusLine = loadStatusLineDebug()

        for definition in config.providers {
            if let candidate = settingsCandidates.first(where: { matches(definition.match, settings: $0, statusLine: statusLine) }) {
                return ResolvedClaudeProvider(
                    id: definition.id,
                    displayName: definition.displayName,
                    baseURL: candidate.baseURL,
                    modelID: statusLine.modelID ?? candidate.modelID,
                    authEnvKey: definition.usageRequest.authEnvKey,
                    env: candidate.env,
                    definition: definition
                )
            }
        }

        return nil
    }

    private static func loadProviderConfig() throws -> ClaudeProviderUsageConfig {
        let decoder = JSONDecoder()
        let fileURL = FilePaths.claudeProviderUsageConfig

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(ClaudeProviderUsageConfig.self, from: data)
        } catch {
            Logger.log(
                "Claude provider config at \(fileURL.path) is invalid, falling back to defaults: \(error.localizedDescription)",
                category: .source
            )
            return ClaudeProviderUsageConfig.defaultConfig
        }
    }

    private static func ensureProviderConfigFileExists() throws {
        let fileManager = FileManager.default
        let fileURL = FilePaths.claudeProviderUsageConfig
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        try fileManager.createDirectory(
            at: FilePaths.hermitFlowHome,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ClaudeProviderUsageConfig.defaultConfig)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func resolvedClaudeSettingsCandidates() throws -> [ClaudeSettingsCandidate] {
        let urls = try resolvedClaudeSettingsURLs()
        return try urls.compactMap { url in
            let object = try loadJSONObjectIfPresent(at: url) ?? [:]
            let env = object["env"] as? [String: String] ?? [:]
            let baseURL = env["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = env["ANTHROPIC_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard baseURL != nil || modelID != nil || !env.isEmpty else {
                return nil
            }

            return ClaudeSettingsCandidate(url: url, env: env, baseURL: baseURL, modelID: modelID)
        }
    }

    private static func resolvedClaudeSettingsURLs() throws -> [URL] {
        var urls: [URL] = [FilePaths.claudeSettings]
        urls.append(contentsOf: try loadCustomSettingsURLs())
        urls.append(contentsOf: loadEnvironmentSettingsURLs())

        var seenPaths = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, !seenPaths.contains(path) else {
                return false
            }
            seenPaths.insert(path)
            return true
        }
    }

    private static func loadCustomSettingsURLs() throws -> [URL] {
        let fileURL = FilePaths.claudeSettingsPaths
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let object = try parseRelaxedJSONObjectData(data, sourcePath: fileURL.path)

        let rawPaths: [String]
        if let array = object as? [String] {
            rawPaths = array
        } else if let dictionary = object as? [String: Any],
                  let paths = dictionary["paths"] as? [String] {
            rawPaths = paths
        } else {
            return []
        }

        return rawPaths.compactMap(expandedFileURL(from:))
    }

    private static func loadEnvironmentSettingsURLs() -> [URL] {
        guard let rawValue = ProcessInfo.processInfo.environment[customSettingsPathsEnvironmentKey],
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return rawValue
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(expandedFileURL(from:))
    }

    private static func parseRelaxedJSONObjectData(_ data: Data, sourcePath: String) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ClaudeUsageLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: sourcePath])
        }

        let relaxedText = text.replacingOccurrences(
            of: ",(\\s*[\\]\\}])",
            with: "$1",
            options: .regularExpression
        )

        guard let relaxedData = relaxedText.data(using: .utf8) else {
            throw NSError(domain: "ClaudeUsageLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: sourcePath])
        }

        return try JSONSerialization.jsonObject(with: relaxedData)
    }

    private static func expandedFileURL(from rawPath: String) -> URL? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    private static func loadJSONObjectIfPresent(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return [:]
        }

        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    private static func loadStatusLineDebug() -> ClaudeStatusLineSnapshot {
        guard let data = try? Data(contentsOf: FilePaths.claudeStatusLineDebug),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeStatusLineSnapshot(modelID: nil, modelDisplayName: nil)
        }

        let model = object["model"] as? [String: Any]
        return ClaudeStatusLineSnapshot(
            modelID: stringValue(model?["id"]),
            modelDisplayName: stringValue(model?["display_name"])
        )
    }

    private static func matches(
        _ rule: ClaudeProviderMatchRule,
        settings: ClaudeSettingsCandidate,
        statusLine: ClaudeStatusLineSnapshot
    ) -> Bool {
        let baseURL = settings.baseURL?.lowercased()
        let modelCandidates = [
            settings.modelID?.lowercased(),
            statusLine.modelID?.lowercased(),
            statusLine.modelDisplayName?.lowercased()
        ].compactMap { $0 }

        if let baseURL {
            if let host = URL(string: baseURL)?.host?.lowercased(),
               rule.baseURLHosts.contains(where: { host.contains($0.lowercased()) }) {
                return true
            }

            if rule.baseURLPrefixes.contains(where: { baseURL.hasPrefix($0.lowercased()) }) {
                return true
            }
        }

        return modelCandidates.contains { model in
            rule.modelPrefixes.contains(where: { model.hasPrefix($0.lowercased()) || model.contains($0.lowercased()) })
        }
    }

    private static func parseWindow(named name: String, from jsonObject: Any) -> ClaudeUsageWindow? {
        guard let container = findDictionaryValue(forKey: name, in: jsonObject) as? [String: Any],
              let usedPercentage = normalizedPercentage(container["used_percentage"] ?? container["utilization"]) else {
            return nil
        }

        return ClaudeUsageWindow(
            usedPercentage: usedPercentage,
            resetsAt: parseDate(container["resets_at"])
        )
    }

    private static func parseWindow(mapping: ClaudeProviderWindowMapping?, from jsonObject: Any) -> ClaudeUsageWindow? {
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
            return ClaudeUsageWindow(usedPercentage: usedPercentage, resetsAt: resetsAt)
        }

        if let remainingPercentage {
            return ClaudeUsageWindow(usedPercentage: max(0, 1 - remainingPercentage), resetsAt: resetsAt)
        }

        return heuristicWindow(from: jsonObject, labels: mapping.labelHints)
    }

    private static func heuristicWindow(from jsonObject: Any, labels: [String]) -> ClaudeUsageWindow? {
        let loweredLabels = labels.map { $0.lowercased() }
        guard let object = findDictionary(matchingAnyOf: loweredLabels, in: jsonObject) else {
            return nil
        }
        return window(from: object)
    }

    private static func window(from value: Any) -> ClaudeUsageWindow? {
        if let container = value as? [String: Any] {
            if let usedPercentage = normalizedPercentage(
                container["used_percentage"] ?? container["usage_percentage"] ?? container["utilization"] ?? container["used"]
            ) {
                return ClaudeUsageWindow(
                    usedPercentage: usedPercentage,
                    resetsAt: parseDate(container["resets_at"] ?? container["reset_at"] ?? container["resetAt"])
                )
            }

            if let remainingPercentage = normalizedPercentage(
                container["remaining_percentage"] ?? container["remaining"] ?? container["remains"] ?? container["left_percentage"]
            ) {
                return ClaudeUsageWindow(
                    usedPercentage: max(0, 1 - remainingPercentage),
                    resetsAt: parseDate(container["resets_at"] ?? container["reset_at"] ?? container["resetAt"])
                )
            }
        }

        if let number = normalizedPercentage(value) {
            return ClaudeUsageWindow(usedPercentage: max(0, 1 - number), resetsAt: nil)
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

    private static func findDictionaryValue(forKey targetKey: String, in jsonObject: Any) -> Any? {
        if let dictionary = jsonObject as? [String: Any] {
            if let value = dictionary[targetKey] {
                return value
            }

            for value in dictionary.values {
                if let nested = findDictionaryValue(forKey: targetKey, in: value) {
                    return nested
                }
            }
        }

        if let array = jsonObject as? [Any] {
            for value in array {
                if let nested = findDictionaryValue(forKey: targetKey, in: value) {
                    return nested
                }
            }
        }

        return nil
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
        let normalizedInput: String
        if hadPercentSuffix {
            normalizedInput = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalizedInput = trimmed
        }

        guard let rawValue = Double(normalizedInput) else {
            return nil
        }

        if hadPercentSuffix {
            return min(max(rawValue / 100, 0), 1)
        }

        if rawValue > 1 {
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

            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: string) {
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

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runUsageCommand(_ definition: ClaudeProviderUsageCommand) -> String? {
        guard let command = definition.command else {
            Logger.log("Claude usage command is empty.", category: .source)
            return nil
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            Logger.log("Claude usage command is empty.", category: .source)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", trimmedCommand]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Logger.log(
                "Claude usage command failed to launch: \(error.localizedDescription)",
                category: .source
            )
            return nil
        }

        let timeout = definition.timeoutSeconds ?? defaultCommandTimeout
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
            Logger.log(
                "Claude usage command timed out after \(timeout)s.",
                category: .source
            )
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Logger.log(
                "Claude usage command exited with status \(process.terminationStatus). \(stderrText)",
                category: .source
            )
            return nil
        }

        guard let stdoutText = String(data: stdoutData, encoding: .utf8) else {
            Logger.log("Claude usage command output is not UTF-8.", category: .source)
            return nil
        }

        let firstLine = stdoutText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        return firstLine
    }
}

private struct ClaudeStatusLineSnapshot {
    let modelID: String?
    let modelDisplayName: String?
}

private final class ClaudeUsageResponseBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
    var statusCode: Int?
}

private struct ClaudeSettingsCandidate {
    let url: URL
    let env: [String: String]
    let baseURL: String?
    let modelID: String?
}

struct ResolvedClaudeProvider: Hashable {
    let id: String
    let displayName: String
    let baseURL: String?
    let modelID: String?
    let authEnvKey: String?
    let env: [String: String]
    let definition: ClaudeProviderDefinition

    func replacingTemplateTokens(in value: String) -> String {
        var resolved = value

        if let baseURL {
            resolved = resolved.replacingOccurrences(of: "{{baseURL}}", with: baseURL)
        }

        if let modelID {
            resolved = resolved.replacingOccurrences(of: "{{modelID}}", with: modelID)
        }

        for (key, envValue) in env {
            resolved = resolved.replacingOccurrences(of: "{{env:\(key)}}", with: envValue)
        }

        return resolved
    }

    func resolveAuthorizationToken(from authEnvKey: String) -> String? {
        let trimmed = authEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("sk-") {
            return trimmed
        }

        guard let envValue = env[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !envValue.isEmpty else {
            return nil
        }

        return envValue
    }
}

struct ClaudeProviderUsageConfig: Codable, Hashable {
    var usageCommand: ClaudeProviderUsageCommand?
    var providers: [ClaudeProviderDefinition]

    enum CodingKeys: String, CodingKey {
        case usageCommand
        case providers
    }

    init(usageCommand: ClaudeProviderUsageCommand?, providers: [ClaudeProviderDefinition]) {
        self.usageCommand = usageCommand
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usageCommand = try container.decodeIfPresent(ClaudeProviderUsageCommand.self, forKey: .usageCommand)
        providers = try container.decode([ClaudeProviderDefinition].self, forKey: .providers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let usageCommand {
            try container.encode(usageCommand, forKey: .usageCommand)
        } else {
            try container.encodeNil(forKey: .usageCommand)
        }
        try container.encode(providers, forKey: .providers)
    }

    static let defaultConfig = ClaudeProviderUsageConfig(
        usageCommand: ClaudeProviderUsageCommand(
            command: nil,
            window: .day,
            valueKind: .remainingPercentage,
            timeoutSeconds: 5,
            displayLabel: "day"
        ),
        providers: [
            ClaudeProviderDefinition(
                id: "kimi",
                displayName: "Kimi",
                match: ClaudeProviderMatchRule(
                    baseURLHosts: ["api.kimi.com"],
                    baseURLPrefixes: ["https://api.kimi.com/coding"],
                    modelPrefixes: ["kimi", "moonshot"]
                ),
                usageRequest: ClaudeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.kimi.com/coding/v1/usages",
                    authEnvKey: "ANTHROPIC_AUTH_TOKEN",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: [
                        "Accept": "application/json"
                    ],
                    query: nil,
                    body: nil
                ),
                responseMapping: ClaudeProviderResponseMapping(
                    fiveHour: nil,
                    sevenDay: nil,
                    fallbackWindow: nil
                )
            ),
            ClaudeProviderDefinition(
                id: "zhipu-cn",
                displayName: "Zhipu",
                match: ClaudeProviderMatchRule(
                    baseURLHosts: ["open.bigmodel.cn", "bigmodel.cn"],
                    baseURLPrefixes: ["https://open.bigmodel.cn", "https://bigmodel.cn"],
                    modelPrefixes: ["glm", "zhipu"]
                ),
                usageRequest: ClaudeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.z.ai/api/monitor/usage/quota/limit",
                    authEnvKey: "ANTHROPIC_AUTH_TOKEN",
                    authHeaderName: "Authorization",
                    authPrefix: "",
                    headers: [
                        "Content-Type": "application/json",
                        "Accept-Language": "en-US,en"
                    ],
                    query: nil,
                    body: nil
                ),
                responseMapping: ClaudeProviderResponseMapping(
                    fiveHour: nil,
                    sevenDay: nil,
                    fallbackWindow: nil
                )
            ),
            ClaudeProviderDefinition(
                id: "zhipu-en",
                displayName: "Zhipu",
                match: ClaudeProviderMatchRule(
                    baseURLHosts: ["api.z.ai"],
                    baseURLPrefixes: ["https://api.z.ai"],
                    modelPrefixes: ["glm", "zhipu"]
                ),
                usageRequest: ClaudeProviderUsageRequest(
                    method: "GET",
                    url: "https://api.z.ai/api/monitor/usage/quota/limit",
                    authEnvKey: "ANTHROPIC_AUTH_TOKEN",
                    authHeaderName: "Authorization",
                    authPrefix: "",
                    headers: [
                        "Content-Type": "application/json",
                        "Accept-Language": "en-US,en"
                    ],
                    query: nil,
                    body: nil
                ),
                responseMapping: ClaudeProviderResponseMapping(
                    fiveHour: nil,
                    sevenDay: nil,
                    fallbackWindow: nil
                )
            ),
            ClaudeProviderDefinition(
                id: "zenmux",
                displayName: "ZenMux",
                match: ClaudeProviderMatchRule(
                    baseURLHosts: ["zenmux.ai"],
                    baseURLPrefixes: ["https://zenmux.ai/"],
                    modelPrefixes: ["zenmux", "anthropic/claude"]
                ),
                usageRequest: ClaudeProviderUsageRequest(
                    method: "GET",
                    url: "https://zenmux.ai/api/v1/management/subscription/detail",
                    authEnvKey: "ANTHROPIC_AUTH_TOKEN",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: [:],
                    query: nil,
                    body: nil
                ),
                responseMapping: ClaudeProviderResponseMapping(
                    fiveHour: ClaudeProviderWindowMapping(
                        objectPaths: ["data.quota_5_hour"],
                        usedPercentagePaths: ["data.quota_5_hour.usage_percentage"],
                        remainingPercentagePaths: [],
                        resetAtPaths: ["data.quota_5_hour.resets_at"],
                        labelHints: ["quota_5_hour", "5_hour", "5h"]
                    ),
                    sevenDay: ClaudeProviderWindowMapping(
                        objectPaths: ["data.quota_7_day"],
                        usedPercentagePaths: ["data.quota_7_day.usage_percentage"],
                        remainingPercentagePaths: [],
                        resetAtPaths: ["data.quota_7_day.resets_at"],
                        labelHints: ["quota_7_day", "7_day", "7d"]
                    ),
                    fallbackWindow: ClaudeProviderWindowMapping(
                        objectPaths: ["data.quota_5_hour", "data.quota_7_day"],
                        usedPercentagePaths: ["data.quota_5_hour.usage_percentage", "data.quota_7_day.usage_percentage"],
                        remainingPercentagePaths: [],
                        resetAtPaths: ["data.quota_5_hour.resets_at", "data.quota_7_day.resets_at"],
                        labelHints: ["quota", "quota_5_hour", "quota_7_day"]
                    )
                )
            ),
            ClaudeProviderDefinition(
                id: "minmax",
                displayName: "MinMax",
                match: ClaudeProviderMatchRule(
                    baseURLHosts: ["minimaxi.com", "minmax"],
                    baseURLPrefixes: ["https://www.minimaxi.com/", "https://api.minimax.chat/"],
                    modelPrefixes: ["minmax", "minimax"]
                ),
                usageRequest: ClaudeProviderUsageRequest(
                    method: "GET",
                    url: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
                    authEnvKey: "ANTHROPIC_AUTH_TOKEN",
                    authHeaderName: nil,
                    authPrefix: "Bearer ",
                    headers: [:],
                    query: nil,
                    body: nil
                ),
                responseMapping: ClaudeProviderResponseMapping(
                    fiveHour: ClaudeProviderWindowMapping(
                        objectPaths: ["five_hour", "data.five_hour", "remains.five_hour"],
                        usedPercentagePaths: ["five_hour.used_percentage", "data.five_hour.used_percentage", "remains.five_hour.used_percentage"],
                        remainingPercentagePaths: ["five_hour.remaining_percentage", "data.five_hour.remaining_percentage", "remains.five_hour.remaining_percentage"],
                        resetAtPaths: ["five_hour.resets_at", "data.five_hour.resets_at", "remains.five_hour.resets_at"],
                        labelHints: ["five_hour", "5h", "hour"]
                    ),
                    sevenDay: ClaudeProviderWindowMapping(
                        objectPaths: ["seven_day", "data.seven_day", "remains.seven_day"],
                        usedPercentagePaths: ["seven_day.used_percentage", "data.seven_day.used_percentage", "remains.seven_day.used_percentage"],
                        remainingPercentagePaths: ["seven_day.remaining_percentage", "data.seven_day.remaining_percentage", "remains.seven_day.remaining_percentage"],
                        resetAtPaths: ["seven_day.resets_at", "data.seven_day.resets_at", "remains.seven_day.resets_at"],
                        labelHints: ["seven_day", "7d", "week"]
                    ),
                    fallbackWindow: ClaudeProviderWindowMapping(
                        objectPaths: ["remains", "data.remains", "quota", "data.quota"],
                        usedPercentagePaths: ["remains.used_percentage", "data.remains.used_percentage", "quota.used_percentage", "data.quota.used_percentage"],
                        remainingPercentagePaths: ["remains.remaining_percentage", "data.remains.remaining_percentage", "quota.remaining_percentage", "data.quota.remaining_percentage"],
                        resetAtPaths: ["remains.resets_at", "data.remains.resets_at", "quota.resets_at", "data.quota.resets_at"],
                        labelHints: ["remains", "quota", "remain"]
                    )
                )
            )
        ]
    )
}

struct ClaudeProviderDefinition: Codable, Hashable {
    var id: String
    var displayName: String
    var match: ClaudeProviderMatchRule
    var usageRequest: ClaudeProviderUsageRequest
    var responseMapping: ClaudeProviderResponseMapping

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case match
        case usageRequest
        case responseMapping
    }

    init(
        id: String,
        displayName: String,
        match: ClaudeProviderMatchRule,
        usageRequest: ClaudeProviderUsageRequest,
        responseMapping: ClaudeProviderResponseMapping
    ) {
        self.id = id
        self.displayName = displayName
        self.match = match
        self.usageRequest = usageRequest
        self.responseMapping = responseMapping
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        match = try container.decode(ClaudeProviderMatchRule.self, forKey: .match)
        usageRequest = try container.decode(ClaudeProviderUsageRequest.self, forKey: .usageRequest)
        responseMapping = try container.decode(ClaudeProviderResponseMapping.self, forKey: .responseMapping)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(match, forKey: .match)
        try container.encode(usageRequest, forKey: .usageRequest)
        try container.encode(responseMapping, forKey: .responseMapping)
    }
}

struct ClaudeProviderMatchRule: Codable, Hashable {
    var baseURLHosts: [String]
    var baseURLPrefixes: [String]
    var modelPrefixes: [String]
}

struct ClaudeProviderUsageRequest: Codable, Hashable {
    var method: String
    var url: String
    var authEnvKey: String?
    var authHeaderName: String?
    var authPrefix: String?
    var headers: [String: String]?
    var query: [String: String]?
    var body: [String: String]?
}

enum ClaudeProviderUsageCommandWindow: String, Codable, Hashable {
    case day

    var defaultLabel: String {
        switch self {
        case .day:
            return "day"
        }
    }
}

enum ClaudeProviderUsageCommandValueKind: String, Codable, Hashable {
    case usedPercentage
    case remainingPercentage
}

struct ClaudeProviderUsageCommand: Codable, Hashable {
    var command: String?
    var window: ClaudeProviderUsageCommandWindow
    var valueKind: ClaudeProviderUsageCommandValueKind
    var timeoutSeconds: TimeInterval?
    var displayLabel: String?
}

struct ClaudeProviderResponseMapping: Codable, Hashable {
    var fiveHour: ClaudeProviderWindowMapping?
    var sevenDay: ClaudeProviderWindowMapping?
    var fallbackWindow: ClaudeProviderWindowMapping?
}

struct ClaudeProviderWindowMapping: Codable, Hashable {
    var objectPaths: [String]
    var usedPercentagePaths: [String]
    var remainingPercentagePaths: [String]
    var resetAtPaths: [String]
    var labelHints: [String]
}
