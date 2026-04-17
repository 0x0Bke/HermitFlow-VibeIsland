import Foundation

enum IslandBrandLogo: String {
    case hermit
    case clawd
    case zenmux
    case claudeCodeColor
    case codexColor
    case codexMono
    case openAI

    var resourceName: String {
        switch self {
        case .hermit:
            return "hermit"
        case .clawd:
            return "claudecode"
        case .zenmux:
            return "zenmux"
        case .claudeCodeColor:
            return "claudecode-v10"
        case .codexColor:
            return "codex-color"
        case .codexMono:
            return "codex"
        case .openAI:
            return "openai"
        }
    }

    var menuTitle: String {
        switch self {
        case .hermit:
            return "Hermit"
        case .clawd:
            return "Clawd"
        case .zenmux:
            return "ZenMux"
        case .claudeCodeColor:
            return "Claude Code"
        case .codexColor:
            return "Codex Color"
        case .codexMono:
            return "Codex Mono"
        case .openAI:
            return "OpenAI"
        }
    }
}

enum IslandSourceMode {
    case localCodex
    case demo
    case file(URL)
}

enum IslandDisplayMode: String {
    case hidden
    case island
    case panel
}

enum IslandCodexActivityState: String {
    case idle
    case running
    case success
    case failure
}

enum SessionFreshness: String, Hashable {
    case live
    case stale
}

enum SessionOrigin: String, Hashable, Codable {
    case claude
    case codex
    case generic

    var provider: CLIProvider {
        switch self {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .generic:
            return .generic
        }
    }
}

enum FocusClientOrigin: String, Hashable, Codable {
    case claudeCLI
    case claudeVSCode
    case codexDesktop
    case codexCLI
    case codexVSCode
    case unknown

    var displayName: String {
        switch self {
        case .claudeCLI:
            return "Claude Code"
        case .claudeVSCode:
            return "VS Code Claude"
        case .codexDesktop:
            return "Codex Desktop"
        case .codexCLI:
            return "Terminal Codex"
        case .codexVSCode:
            return "VS Code Codex"
        case .unknown:
            return "Unknown Session"
        }
    }
}

enum ApprovalResolutionKind: String, Hashable {
    case accessibilityAutomation
    case localHTTPHook
}

enum TerminalClient: String, Hashable, Codable {
    case warp
    case iTerm
    case terminal
    case wezTerm
    case ghostty
    case alacritty
    case unknown

    var displayName: String {
        switch self {
        case .warp:
            return "Warp"
        case .iTerm:
            return "iTerm"
        case .terminal:
            return "Terminal"
        case .wezTerm:
            return "WezTerm"
        case .ghostty:
            return "Ghostty"
        case .alacritty:
            return "Alacritty"
        case .unknown:
            return "Terminal"
        }
    }
}

struct FocusTarget: Hashable {
    let clientOrigin: FocusClientOrigin
    let sessionID: String
    let displayName: String
    let cwd: String?
    let terminalClient: TerminalClient?
    let terminalSessionHint: String?
    let workspaceHint: String?
}

struct ApprovalRequest: Identifiable, Hashable {
    let id: String
    let commandSummary: String
    let commandText: String
    let rationale: String?
    let focusTarget: FocusTarget?
    let createdAt: Date
    let source: SessionOrigin
    let resolutionKind: ApprovalResolutionKind
}

struct AgentSessionSnapshot: Identifiable, Hashable {
    let id: String
    let origin: SessionOrigin
    let title: String
    let detail: String
    let activityState: IslandCodexActivityState
    let updatedAt: Date
    let cwd: String?
    let focusTarget: FocusTarget?
    let freshness: SessionFreshness
}

struct ActivitySourceSnapshot {
    let sessions: [AgentSessionSnapshot]
    let statusMessage: String
    let lastUpdatedAt: Date
    let errorMessage: String?
    let approvalRequest: ApprovalRequest?
    let usageSnapshots: [ProviderUsageSnapshot]
}

struct IslandRuntimeState {
    let sessions: [AgentSessionSnapshot]
    let tasks: [CLIJob]
    let codexStatus: IslandCodexActivityState
    let statusMessage: String
    let lastUpdatedAt: Date
    let errorMessage: String?
    let approvalRequest: ApprovalRequest?
    let usageSnapshots: [ProviderUsageSnapshot]
}

struct ProviderUsageSnapshot: Hashable, Identifiable {
    let origin: SessionOrigin
    let shortWindowRemaining: Double
    let longWindowRemaining: Double
    let updatedAt: Date

    var id: SessionOrigin { origin }
}
