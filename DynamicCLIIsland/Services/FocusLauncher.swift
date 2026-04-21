import AppKit
import ApplicationServices
import Foundation

enum ApprovalDecision {
    case reject
    case accept
    case acceptAll

    var buttonTitles: [String] {
        switch self {
        case .reject:
            return ["Reject", "Deny", "Cancel", "拒绝", "取消", "不允许"]
        case .accept:
            return ["Accept", "Allow", "允许", "接受"]
        case .acceptAll:
            return ["Accept All", "Allow All", "全部接受", "全部允许"]
        }
    }

    var progressMessage: String {
        switch self {
        case .reject:
            return "Rejecting approval"
        case .accept:
            return "Accepting approval"
        case .acceptAll:
            return "Allowing all approvals"
        }
    }

    var terminalResponse: String {
        switch self {
        case .reject:
            return "n"
        case .accept:
            return "y"
        case .acceptAll:
            return "a"
        }
    }
}

enum FocusApprovalAutomationResult: Equatable {
    case success
    case routedToWindow
    case applicationNotFound
    case accessibilityElementNotFound
    case accessibilityPressFailed
    case appleScriptButtonNotFound
    case appleScriptFailed(String)
    case terminalKeystrokeFailed(String)

    var diagnosticMessage: String {
        switch self {
        case .success:
            return "自动审批成功"
        case .routedToWindow:
            return "已打开目标窗口，请手动处理审批"
        case .applicationNotFound:
            return "未找到目标应用"
        case .accessibilityElementNotFound:
            return "已找到应用，但未找到可点击的审批控件"
        case .accessibilityPressFailed:
            return "已找到审批控件，但触发点击失败"
        case .appleScriptButtonNotFound:
            return "已回退到脚本扫描，但仍未找到审批按钮"
        case let .appleScriptFailed(message):
            return "脚本点击失败：\(message)"
        case let .terminalKeystrokeFailed(message):
            return "终端按键确认失败：\(message)"
        }
    }
}

@MainActor
final class FocusLauncher {
    @discardableResult
    func openAccessibilitySettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    func bringToFront(_ target: FocusTarget) -> Bool {
        let descriptors = appDescriptors(for: target)

        if let runningApp = findRunningApplication(matching: descriptors) {
            runningApp.unhide()
            if runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                if routeTerminalWindowIfPossible(for: target) {
                    return true
                }
                return true
            }

            if let bundleURL = runningApp.bundleURL {
                let opened = openApplication(at: bundleURL)
                if opened {
                    _ = routeTerminalWindowIfPossible(for: target)
                }
                return opened
            }
        }

        for descriptor in descriptors {
            if let bundleIdentifier = descriptor.bundleIdentifier,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                let opened = openApplication(at: appURL)
                if opened {
                    _ = routeTerminalWindowIfPossible(for: target)
                }
                return opened
            }

            if let appName = descriptor.appName,
               let fullPath = NSWorkspace.shared.fullPath(forApplication: appName) {
                let opened = openApplication(at: URL(fileURLWithPath: fullPath))
                if opened {
                    _ = routeTerminalWindowIfPossible(for: target)
                }
                return opened
            }
        }

        return false
    }

    func performApproval(_ decision: ApprovalDecision, for target: FocusTarget) -> FocusApprovalAutomationResult {
        switch target.clientOrigin {
        case .claudeCLI:
            return performTerminalApproval(decision, for: target)
        case .claudeVSCode:
            return performGraphicalApproval(decision, for: target)
        case .codexDesktop:
            return bringToFront(target) ? .routedToWindow : .applicationNotFound
        case .codexCLI, .openCodeCLI:
            return performTerminalApproval(decision, for: target)
        case .codexVSCode, .unknown:
            return performGraphicalApproval(decision, for: target)
        }
    }

    private func performGraphicalApproval(_ decision: ApprovalDecision, for target: FocusTarget) -> FocusApprovalAutomationResult {
        guard bringToFront(target) else {
            return .applicationNotFound
        }

        let descriptors = appDescriptors(for: target)
        guard let runningApp = findRunningApplication(matching: descriptors) else {
            return .applicationNotFound
        }

        switch clickApprovalElement(in: runningApp, matching: decision.buttonTitles) {
        case .success:
            return .success
        case .elementNotFound, .pressFailed:
            break
        }

        let processNames = descriptors.compactMap(\.appName)
        guard !processNames.isEmpty else {
            return .accessibilityElementNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = approvalScriptArguments(
            processNames: processNames,
            buttonTitles: decision.buttonTitles
        )

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return .appleScriptFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = output?.isEmpty == false ? output! : "unknown"

        if process.terminationStatus != 0 {
            return .appleScriptFailed(message)
        }

        if output == "clicked" {
            return .success
        }

        return output == "not-found" ? .appleScriptButtonNotFound : .appleScriptFailed(message)
    }

    private func performTerminalApproval(_ decision: ApprovalDecision, for target: FocusTarget) -> FocusApprovalAutomationResult {
        guard bringToFront(target) else {
            return .applicationNotFound
        }

        let processNames = appDescriptors(for: target).compactMap(\.appName)
        guard !processNames.isEmpty else {
            return .applicationNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = terminalApprovalScriptArguments(
            processNames: processNames,
            response: decision.terminalResponse
        )

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return .terminalKeystrokeFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = output?.isEmpty == false ? output! : "unknown"

        if process.terminationStatus != 0 {
            return .terminalKeystrokeFailed(message)
        }

        return output == "typed" ? .success : .terminalKeystrokeFailed(message)
    }

    private func openApplication(at url: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }

    private func routeTerminalWindowIfPossible(for target: FocusTarget) -> Bool {
        guard target.clientOrigin == .claudeCLI
            || target.clientOrigin == .codexCLI
            || target.clientOrigin == .openCodeCLI else {
            return false
        }

        switch target.terminalClient {
        case .iTerm:
            return runAppleScript(arguments: iTermRoutingScriptArguments(for: target)) == "matched"
        case .warp:
            return runAppleScript(arguments: warpRoutingScriptArguments(for: target)) == "matched"
        case .terminal:
            return runAppleScript(arguments: terminalRoutingScriptArguments(for: target)) == "matched"
        case .wezTerm:
            if routeWezTermPaneIfPossible(for: target) {
                return true
            }
            return runAppleScript(arguments: accessibilityWindowRoutingScriptArguments(
                processName: "WezTerm",
                workspaceHints: terminalWorkspaceHints(for: target)
            )) == "matched"
        case .ghostty:
            return runAppleScript(arguments: accessibilityWindowRoutingScriptArguments(
                processName: "Ghostty",
                workspaceHints: terminalWorkspaceHints(for: target)
            )) == "matched"
        case .alacritty:
            return runAppleScript(arguments: accessibilityWindowRoutingScriptArguments(
                processName: "Alacritty",
                workspaceHints: terminalWorkspaceHints(for: target)
            )) == "matched"
        default:
            return false
        }
    }

    private func runAppleScript(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findRunningApplication(matching descriptors: [FocusAppDescriptor]) -> NSRunningApplication? {
        let runningApplications = NSWorkspace.shared.runningApplications

        for descriptor in descriptors {
            if let bundleIdentifier = descriptor.bundleIdentifier,
               let app = runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return app
            }

            if let appName = descriptor.appName,
               let app = runningApplications.first(where: {
                   $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
               }) {
                return app
            }
        }

        return nil
    }

    private func appDescriptors(for target: FocusTarget) -> [FocusAppDescriptor] {
        switch target.clientOrigin {
        case .claudeVSCode:
            return [
                FocusAppDescriptor(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code"),
                FocusAppDescriptor(bundleIdentifier: "com.microsoft.VSCodeInsiders", appName: "Visual Studio Code - Insiders"),
                FocusAppDescriptor(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
            ]
        case .claudeCLI:
            let preferredDescriptor: FocusAppDescriptor? = {
                switch target.terminalClient {
                case .warp:
                    return FocusAppDescriptor(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp")
                case .iTerm:
                    return FocusAppDescriptor(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm")
                case .terminal:
                    return FocusAppDescriptor(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
                case .wezTerm:
                    return FocusAppDescriptor(bundleIdentifier: "com.github.wez.wezterm", appName: "WezTerm")
                case .ghostty:
                    return FocusAppDescriptor(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty")
                case .alacritty:
                    return FocusAppDescriptor(bundleIdentifier: "org.alacritty", appName: "Alacritty")
                case .unknown, .none:
                    return nil
                }
            }()

            let fallbackDescriptors = [
                FocusAppDescriptor(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"),
                FocusAppDescriptor(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm"),
                FocusAppDescriptor(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp"),
                FocusAppDescriptor(bundleIdentifier: "com.github.wez.wezterm", appName: "WezTerm"),
                FocusAppDescriptor(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty"),
                FocusAppDescriptor(bundleIdentifier: "org.alacritty", appName: "Alacritty")
            ]

            if let preferredDescriptor {
                return [preferredDescriptor] + fallbackDescriptors.filter { $0 != preferredDescriptor }
            }

            return fallbackDescriptors
        case .codexDesktop:
            return [
                FocusAppDescriptor(bundleIdentifier: "com.openai.codex", appName: "Codex"),
                FocusAppDescriptor(bundleIdentifier: nil, appName: "Codex")
            ]
        case .codexVSCode:
            return [
                FocusAppDescriptor(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor"),
                FocusAppDescriptor(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code"),
                FocusAppDescriptor(bundleIdentifier: "com.microsoft.VSCodeInsiders", appName: "Visual Studio Code - Insiders")
            ]
        case .codexCLI, .openCodeCLI:
            let preferredDescriptor: FocusAppDescriptor? = {
                switch target.terminalClient {
                case .warp:
                    return FocusAppDescriptor(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp")
                case .iTerm:
                    return FocusAppDescriptor(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm")
                case .terminal:
                    return FocusAppDescriptor(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
                case .wezTerm:
                    return FocusAppDescriptor(bundleIdentifier: "com.github.wez.wezterm", appName: "WezTerm")
                case .ghostty:
                    return FocusAppDescriptor(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty")
                case .alacritty:
                    return FocusAppDescriptor(bundleIdentifier: "org.alacritty", appName: "Alacritty")
                case .unknown, .none:
                    return nil
                }
            }()

            let fallbackDescriptors = [
                FocusAppDescriptor(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"),
                FocusAppDescriptor(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm"),
                FocusAppDescriptor(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp"),
                FocusAppDescriptor(bundleIdentifier: "com.github.wez.wezterm", appName: "WezTerm"),
                FocusAppDescriptor(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty"),
                FocusAppDescriptor(bundleIdentifier: "org.alacritty", appName: "Alacritty")
            ]

            if let preferredDescriptor {
                return [preferredDescriptor] + fallbackDescriptors.filter { $0 != preferredDescriptor }
            }

            return fallbackDescriptors
        case .unknown:
            return [
                FocusAppDescriptor(bundleIdentifier: nil, appName: "Codex"),
                FocusAppDescriptor(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code"),
                FocusAppDescriptor(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
            ]
        }
    }

    private func approvalScriptArguments(processNames: [String], buttonTitles: [String]) -> [String] {
        let buttonList = appleScriptList(buttonTitles)
        let processList = appleScriptList(processNames)

        return [
            "-e", "set targetButtons to \(buttonList)",
            "-e", "set targetProcesses to \(processList)",
            "-e", "set normalizedButtons to {}",
            "-e", "repeat with buttonTitle in targetButtons",
            "-e", "set end of normalizedButtons to my lowerText(buttonTitle as text)",
            "-e", "end repeat",
            "-e", "on lowerText(inputText)",
            "-e", "return do shell script \"printf %s \" & quoted form of inputText & \" | tr '[:upper:]' '[:lower:]'\"",
            "-e", "end lowerText",
            "-e", "on clickButtons(processName, targetButtons)",
            "-e", "tell application \"System Events\"",
            "-e", "tell process processName",
            "-e", "set searchRoots to {}",
            "-e", "try",
            "-e", "repeat with windowRef in windows",
            "-e", "copy windowRef to end of searchRoots",
            "-e", "end repeat",
            "-e", "end try",
            "-e", "repeat with rootRef in searchRoots",
            "-e", "set buttonList to {}",
            "-e", "try",
            "-e", "set buttonList to every button of entire contents of rootRef",
            "-e", "end try",
            "-e", "repeat with buttonRef in buttonList",
            "-e", "try",
            "-e", "set buttonName to my lowerText(name of buttonRef as text)",
            "-e", "if normalizedButtons contains buttonName then",
            "-e", "click buttonRef",
            "-e", "return true",
            "-e", "end if",
            "-e", "end try",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "end tell",
            "-e", "return false",
            "-e", "end clickButtons",
            "-e", "repeat 25 times",
            "-e", "repeat with processName in targetProcesses",
            "-e", "tell application \"System Events\"",
            "-e", "if exists process processName then",
            "-e", "tell process processName to set frontmost to true",
            "-e", "end if",
            "-e", "end tell",
            "-e", "delay 0.12",
            "-e", "if my clickButtons(processName as text, targetButtons) then",
            "-e", "return \"clicked\"",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "delay 0.12",
            "-e", "end repeat",
            "-e", "return \"not-found\""
        ]
    }

    private func terminalApprovalScriptArguments(processNames: [String], response: String) -> [String] {
        let processList = appleScriptList(processNames)

        return [
            "-e", "set targetProcesses to \(processList)",
            "-e", "set approvalResponse to \"\(response)\"",
            "-e", "tell application \"System Events\"",
            "-e", "set focusedProcessFound to false",
            "-e", "repeat 20 times",
            "-e", "repeat with processName in targetProcesses",
            "-e", "if exists process processName then",
            "-e", "tell process processName to set frontmost to true",
            "-e", "set focusedProcessFound to true",
            "-e", "exit repeat",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "if focusedProcessFound then exit repeat",
            "-e", "delay 0.1",
            "-e", "end repeat",
            "-e", "if not focusedProcessFound then return \"not-found\"",
            "-e", "delay 0.15",
            "-e", "keystroke approvalResponse",
            "-e", "key code 36",
            "-e", "end tell",
            "-e", "return \"typed\""
        ]
    }

    private func appleScriptList(_ values: [String]) -> String {
        let escapedValues = values.map { value in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        return "{\(escapedValues.joined(separator: ", "))}"
    }

    private func iTermRoutingScriptArguments(for target: FocusTarget) -> [String] {
        let sessionHint = appleScriptOptionalString(target.terminalSessionHint)
        let workspaceHint = appleScriptOptionalString(target.workspaceHint ?? target.cwd)

        return [
            "-e", "set sessionHint to \(sessionHint)",
            "-e", "set workspaceHint to \(workspaceHint)",
            "-e", "tell application \"iTerm\" to activate",
            "-e", "tell application \"iTerm\"",
            "-e", "repeat with currentWindow in windows",
            "-e", "repeat with currentTab in tabs of currentWindow",
            "-e", "repeat with currentSession in sessions of currentTab",
            "-e", "set matched to false",
            "-e", "if sessionHint is not missing value then",
            "-e", "try",
            "-e", "set matched to (id of currentSession as text) is equal to (sessionHint as text)",
            "-e", "end try",
            "-e", "end if",
            "-e", "if matched is false and workspaceHint is not missing value then",
            "-e", "try",
            "-e", "set matched to ((name of currentSession as text) contains (workspaceHint as text))",
            "-e", "end try",
            "-e", "end if",
            "-e", "if matched is false and workspaceHint is not missing value then",
            "-e", "try",
            "-e", "set matched to ((tty of currentSession as text) contains (workspaceHint as text))",
            "-e", "end try",
            "-e", "end if",
            "-e", "if matched then",
            "-e", "select currentTab",
            "-e", "set current window to currentWindow",
            "-e", "return \"matched\"",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "return \"not-found\""
        ]
    }

    private func warpRoutingScriptArguments(for target: FocusTarget) -> [String] {
        let workspaceHint = appleScriptOptionalString(target.workspaceHint ?? target.cwd)

        return [
            "-e", "set workspaceHint to \(workspaceHint)",
            "-e", "tell application \"Warp\" to activate",
            "-e", "if workspaceHint is missing value then return \"not-found\"",
            "-e", "tell application \"System Events\"",
            "-e", "if not (exists process \"Warp\") then return \"not-found\"",
            "-e", "tell process \"Warp\"",
            "-e", "set frontmost to true",
            "-e", "repeat with windowRef in windows",
            "-e", "try",
            "-e", "set windowName to name of windowRef as text",
            "-e", "if windowName contains (workspaceHint as text) then",
            "-e", "perform action \"AXRaise\" of windowRef",
            "-e", "return \"matched\"",
            "-e", "end if",
            "-e", "end try",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "end tell",
            "-e", "return \"not-found\""
        ]
    }

    private func terminalRoutingScriptArguments(for target: FocusTarget) -> [String] {
        let workspaceHints = appleScriptList(terminalWorkspaceHints(for: target))

        return [
            "-e", "set workspaceHints to \(workspaceHints)",
            "-e", "if (count of workspaceHints) is 0 then return \"not-found\"",
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\"",
            "-e", "repeat with currentWindow in windows",
            "-e", "repeat with currentTab in tabs of currentWindow",
            "-e", "set matched to false",
            "-e", "repeat with workspaceHint in workspaceHints",
            "-e", "if matched is false then",
            "-e", "try",
            "-e", "set matched to ((tty of currentTab as text) contains (workspaceHint as text))",
            "-e", "end try",
            "-e", "end if",
            "-e", "if matched is false then",
            "-e", "try",
            "-e", "set matched to ((custom title of currentTab as text) contains (workspaceHint as text))",
            "-e", "end try",
            "-e", "end if",
            "-e", "if matched is false then",
            "-e", "try",
            "-e", "set matched to ((name of currentWindow as text) contains (workspaceHint as text))",
            "-e", "end try",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "if matched then",
            "-e", "set selected tab of currentWindow to currentTab",
            "-e", "set index of currentWindow to 1",
            "-e", "return \"matched\"",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "return \"not-found\""
        ]
    }

    private func accessibilityWindowRoutingScriptArguments(processName: String, workspaceHints: [String]) -> [String] {
        let escapedProcessName = processName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let workspaceHintList = appleScriptList(workspaceHints)

        return [
            "-e", "set targetProcess to \"\(escapedProcessName)\"",
            "-e", "set workspaceHints to \(workspaceHintList)",
            "-e", "if (count of workspaceHints) is 0 then return \"not-found\"",
            "-e", "tell application \"System Events\"",
            "-e", "if not (exists process targetProcess) then return \"not-found\"",
            "-e", "tell process targetProcess",
            "-e", "set frontmost to true",
            "-e", "repeat with windowRef in windows",
            "-e", "try",
            "-e", "set windowName to name of windowRef as text",
            "-e", "repeat with workspaceHint in workspaceHints",
            "-e", "if windowName contains (workspaceHint as text) then",
            "-e", "perform action \"AXRaise\" of windowRef",
            "-e", "return \"matched\"",
            "-e", "end if",
            "-e", "end repeat",
            "-e", "end try",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "end tell",
            "-e", "return \"not-found\""
        ]
    }

    private func routeWezTermPaneIfPossible(for target: FocusTarget) -> Bool {
        guard let paneID = target.terminalSessionHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !paneID.isEmpty else {
            return false
        }

        for executableURL in wezTermExecutableCandidates() {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = wezTermActivationArguments(forPaneID: paneID, executableURL: executableURL)
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }

            if process.terminationStatus == 0 {
                return true
            }
        }

        return false
    }

    private func wezTermExecutableCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/usr/bin/env"),
            URL(fileURLWithPath: "/opt/homebrew/bin/wezterm"),
            URL(fileURLWithPath: "/usr/local/bin/wezterm"),
            URL(fileURLWithPath: "/Applications/WezTerm.app/Contents/MacOS/wezterm")
        ]
    }

    private func wezTermActivationArguments(forPaneID paneID: String, executableURL: URL) -> [String] {
        let arguments = ["cli", "activate-pane", "--pane-id", paneID]
        if executableURL.path == "/usr/bin/env" {
            return ["wezterm"] + arguments
        }
        return arguments
    }

    private func terminalWorkspaceHints(for target: FocusTarget) -> [String] {
        var hints: [String] = []
        var seen = Set<String>()

        for rawHint in [target.workspaceHint, target.cwd] {
            guard let trimmed = rawHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }

            for candidate in [trimmed, URL(fileURLWithPath: trimmed).lastPathComponent] {
                guard !candidate.isEmpty, !seen.contains(candidate) else {
                    continue
                }

                seen.insert(candidate)
                hints.append(candidate)
            }
        }

        return hints
    }

    private func appleScriptOptionalString(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "missing value"
        }

        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func clickApprovalElement(in app: NSRunningApplication, matching buttonTitles: [String]) -> AccessibilityClickResult {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let normalizedTargets = buttonTitles.map(normalizeAccessibilityLabel(_:))

        for _ in 0..<24 {
            if let element = findMatchingAccessibilityElement(
                in: applicationElement,
                normalizedTargets: normalizedTargets,
                depth: 0
            ) {
                return performPress(on: element) ? .success : .pressFailed
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return .elementNotFound
    }

    private func findMatchingAccessibilityElement(
        in element: AXUIElement,
        normalizedTargets: [String],
        depth: Int
    ) -> AXUIElement? {
        guard depth <= 8 else {
            return nil
        }

        if matchesApprovalText(element, normalizedTargets: normalizedTargets),
           let actionableElement = actionableApprovalElement(for: element) {
            return actionableElement
        }

        for child in accessibilityChildren(of: element) {
            if let match = findMatchingAccessibilityElement(
                in: child,
                normalizedTargets: normalizedTargets,
                depth: depth + 1
            ) {
                return match
            }
        }

        return nil
    }

    private func matchesApprovalText(_ element: AXUIElement, normalizedTargets: [String]) -> Bool {
        let searchableValues = [
            accessibilityStringAttribute("AXTitle", on: element),
            accessibilityStringAttribute("AXDescription", on: element),
            accessibilityStringAttribute("AXValue", on: element),
            accessibilityStringAttribute("AXIdentifier", on: element),
            accessibilityStringAttribute("AXHelp", on: element),
            accessibilityStringAttribute("AXRoleDescription", on: element),
            accessibilityStringAttribute("AXSubrole", on: element)
        ]
            .compactMap { $0 }
            .map(normalizeAccessibilityLabel(_:))

        guard !searchableValues.isEmpty else {
            return false
        }

        let matches = searchableValues.contains { candidate in
            normalizedTargets.contains { target in
                candidate == target || candidate.contains(target) || target.contains(candidate)
            }
        }

        guard matches else {
            return false
        }

        return true
    }

    private func actionableApprovalElement(for element: AXUIElement) -> AXUIElement? {
        if canPerformApprovalAction(on: element) {
            return element
        }

        var currentElement = element
        for _ in 0..<5 {
            guard let parentValue = accessibilityAttribute("AXParent", on: currentElement) else {
                return nil
            }
            guard CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return nil
            }

            let parentElement = unsafeBitCast(parentValue, to: AXUIElement.self)
            if canPerformApprovalAction(on: parentElement) {
                return parentElement
            }
            currentElement = parentElement
        }

        return nil
    }

    private func canPerformApprovalAction(on element: AXUIElement) -> Bool {
        let actionNames = accessibilityActionNames(of: element)
        return actionNames.contains("AXPress") || actionNames.contains("AXConfirm")
    }

    private func performPress(on element: AXUIElement) -> Bool {
        let pressResult = AXUIElementPerformAction(element, "AXPress" as CFString)
        if pressResult == .success {
            return true
        }

        let confirmResult = AXUIElementPerformAction(element, "AXConfirm" as CFString)
        if confirmResult == .success {
            return true
        }

        return false
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            "AXFocusedWindow",
            "AXMainWindow",
            "AXWindows",
            "AXSheets",
            "AXChildren"
        ]

        var results: [AXUIElement] = []

        for attribute in attributes {
            if let value = accessibilityAttribute(attribute, on: element) {
                if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    results.append(unsafeBitCast(value, to: AXUIElement.self))
                } else if CFGetTypeID(value) == CFArrayGetTypeID(),
                          let array = value as? [Any] {
                    results.append(contentsOf: array.compactMap { item in
                        let itemObject = item as AnyObject
                        guard CFGetTypeID(itemObject) == AXUIElementGetTypeID() else {
                            return nil
                        }
                        return unsafeBitCast(itemObject, to: AXUIElement.self)
                    })
                }
            }
        }

        return results
    }

    private func accessibilityStringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        guard let value = accessibilityAttribute(attribute, on: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func accessibilityActionNames(of element: AXUIElement) -> [String] {
        var actionNames: CFArray?
        let result = AXUIElementCopyActionNames(element, &actionNames)
        guard result == .success, let actionNames else {
            return []
        }

        return (actionNames as? [String]) ?? []
    }

    private func accessibilityAttribute(_ attribute: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value
    }

    private func normalizeAccessibilityLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}

private struct FocusAppDescriptor: Equatable {
    let bundleIdentifier: String?
    let appName: String?
}

private enum AccessibilityClickResult {
    case success
    case elementNotFound
    case pressFailed
}
