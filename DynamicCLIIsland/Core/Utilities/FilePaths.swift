//
//  FilePaths.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

enum FilePaths {
    static let hermitFlowHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermitflow", isDirectory: true)
    static let zshrc = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zshrc", isDirectory: false)
    static let bashrc = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".bashrc", isDirectory: false)
    static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json", isDirectory: false)
    static let claudeSettingsPaths = hermitFlowHome
        .appendingPathComponent("claude-settings-paths.json", isDirectory: false)
    static let claudeProviderUsageConfig = hermitFlowHome
        .appendingPathComponent("claude-provider-usage.json", isDirectory: false)
    static let customLogosDirectory = hermitFlowHome
        .appendingPathComponent("logos", isDirectory: true)
    static let customLeftLogo = customLogosDirectory
        .appendingPathComponent("custom-left-logo.png", isDirectory: false)
    static let notificationSoundsDirectory = hermitFlowHome
        .appendingPathComponent("notification-sounds", isDirectory: true)
    static let customApprovalNotificationSound = notificationSoundsDirectory
        .appendingPathComponent("Approval", isDirectory: false)
    static let customCompletionNotificationSound = notificationSoundsDirectory
        .appendingPathComponent("Completion", isDirectory: false)
    static let claudeUsageCache = URL(fileURLWithPath: "/tmp/hermitflow-rl.json")
    static let claudeStatusLineDebug = URL(fileURLWithPath: "/tmp/hermitflow-claude-statusline-debug.json")
    static let codexHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    static let openCodeConfigDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode", isDirectory: true)
    static let openCodeConfigFile = openCodeConfigDirectory
        .appendingPathComponent("opencode.json", isDirectory: false)
    static let openCodePluginsDirectory = openCodeConfigDirectory
        .appendingPathComponent("plugins", isDirectory: true)
    static let openCodeDataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode", isDirectory: true)
    static let openCodeDatabase = openCodeDataDirectory
        .appendingPathComponent("opencode.db", isDirectory: false)
    static let debugLog = URL(fileURLWithPath: "/tmp/hermitflow-debug.log")

    static func expandingTilde(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath, isDirectory: false)
        }

        return URL(fileURLWithPath: path)
    }
}
