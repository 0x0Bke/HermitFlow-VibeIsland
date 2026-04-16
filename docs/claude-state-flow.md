# Claude State Flow

This document describes how HermitFlow tracks Claude Code activity today, including the managed hook registration, the local callback server, the in-memory bridge state, and the reducer/UI integration path.

## Overview

Claude state is not modeled as a standalone state machine file. The current implementation keeps two in-memory collections inside `ClaudeHookBridge`:

- `sessions: [String: ClaudeTrackedSession]`
- `approvals: [String: ClaudePendingApproval]`

The runtime entrypoint is:

- `DynamicCLIIsland/Sources/Claude/ClaudeHookBootstrap.swift`
- `DynamicCLIIsland/State/RuntimeStore.swift`

At launch, HermitFlow:

1. Starts the local Claude callback listener.
2. Regenerates and resyncs the managed Claude hook entries.
3. Polls Claude and Codex activity snapshots and merges them before updating the UI.

## Startup And Registration

`RuntimeStore.handleLaunch()` calls `claudeHookBootstrap.bootstrap()`.

`ClaudeHookBootstrap.bootstrap()` does two things:

1. `callbackServer.start()`
2. `installer.resync()`

The local listener is implemented in `LocalCodexSource.swift` through `ClaudeHookBridge`. The listener currently:

- listens on port `46821`
- supports `GET /health`
- supports `GET /state`
- handles `POST /state`
- handles `POST /permission/hermitflow`

The managed hook script is written to:

- `~/.hermitflow/claude-hooks/hermit-claude-hook.js`

Managed Claude settings are synced into:

- `~/.claude/settings.json`
- extra paths from `~/.hermitflow/claude-settings-paths.json`
- extra paths from `HERMITFLOW_CLAUDE_SETTINGS_PATHS`

## Registered Claude Hooks

HermitFlow registers the following Claude command hooks:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `PostToolUseFailure`
- `StopFailure`
- `Stop`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`
- `PostCompact`
- `Notification`
- `Elicitation`
- `WorktreeCreate`

Each command hook is registered in the form:

```text
"<nodePath>" "<scriptPath>" <EVENT>
```

HermitFlow also registers:

- `PermissionRequest` as an HTTP hook to `http://127.0.0.1:46821/permission/hermitflow`
- `statusLine` as a command hook calling `"<nodePath>" "<scriptPath>" StatusLine`

## Hook Script State Mapping

Inside the generated Node.js hook script, Claude events are first mapped into intermediate state labels:

- `SessionStart -> idle`
- `SessionEnd -> sleeping`
- `UserPromptSubmit -> thinking`
- `PreToolUse -> working`
- `PostToolUse -> working`
- `PostToolUseFailure -> error`
- `StopFailure -> error`
- `Stop -> attention`
- `SubagentStart -> juggling`
- `SubagentStop -> working`
- `PreCompact -> sweeping`
- `PostCompact -> attention`
- `Notification -> notification`
- `Elicitation -> notification`
- `WorktreeCreate -> carrying`

For command hooks, the script sends a payload to `POST /state` including:

- `event`
- `state`
- `session_id`
- `cwd`
- `source`
- `client_origin`
- `terminal_client`
- `terminal_session_hint`

For `StatusLine`, the script also:

- writes the raw payload to `/tmp/hermitflow-claude-statusline-debug.json`
- writes compatible usage windows to `/tmp/hermitflow-rl.json`

## Bridge Processing

`POST /state` is decoded into `ClaudeHookEventPayload` and applied to `ClaudeHookBridge.sessions`.

Core behavior:

- `SessionEnd` removes the session immediately.
- Other events merge through `mergedClaudeSession(...)`.
- Certain events also clear any pending approval for that session.

The bridge keeps the final internal Claude session state as one of:

- `idle`
- `running`
- `success`
- `failure`

The reduction from hook payload to final internal state is:

- `error` or `PostToolUseFailure` or `StopFailure` -> `failure`
- `attention` or `Stop` or `PostCompact` -> `success`
- `notification` or `Notification` or `Elicitation` -> `idle`
- `idle` or `sleeping` -> `idle`
- everything else -> `running`

## State Corrections And Stability Rules

The bridge does not trust hook events alone. Before producing UI snapshots, it also reads local Claude session/project/history signals and applies corrective rules.

Important rules:

- `Notification` and `Elicitation` do not knock an actively running session back to idle.
- A transition from idle to running is accepted only for explicit running events.
- Short trailing running events after success or failure are ignored to avoid UI flicker.
- Project `user_prompt` activity can re-promote a session back to running.
- A stalled prompt can be downgraded to idle as `stalled_prompt`.
- Interruption or project-derived state can override hook state and demote running back to idle.
- `success` is shown for `1.25s`, `failure` for `2.0s`, then both fall back to idle.
- Sessions older than `10min` without activity are pruned.

HermitFlow also merges discovered sessions from `~/.claude/sessions` so that local Claude sessions can still surface even when the in-memory hook state is incomplete.

## Approval Flow

Claude approvals are handled through the local HTTP hook path.

Flow:

1. Claude triggers `PermissionRequest`.
2. HermitFlow receives `POST /permission/hermitflow`.
3. The bridge creates `ClaudePendingApproval`.
4. The related Claude session is forced into a running state.
5. `RuntimeStore.refreshLocalApprovalStatus()` polls `claudeSource.fetchLatestApprovalRequest()`.
6. The UI presents the request.
7. Accept/reject is executed through `HTTPHookApprovalExecutor`.
8. `localClaudeSource.resolveApproval(...)` writes the HTTP JSON response back onto the original `NWConnection`.

This makes Claude approvals local-first and closes the loop without Accessibility automation.

## Runtime And UI Integration

`RuntimeStore.refreshLocalCodexStatus()` fetches:

- `localCodexSource.fetchActivity()`
- `localClaudeSource.fetchActivity()`

The two snapshots are merged through `ActivitySnapshotMerger`, converted into `IslandEvent`s by `ActivitySnapshotEventAdapter`, and then applied to:

- `RuntimeReducer`
- `SessionReducer`
- `ApprovalReducer`

This is how Claude state ends up driving:

- session cards
- approval UI
- overall island status
- focus targets

## Usage And Debug Side Effects

Claude usage is loaded by `ClaudeUsageLoader.load()`.

The loader prefers:

1. the local hook-managed cache
2. command-based provider usage
3. remote provider fallback

The current local files involved in that flow are:

- `/tmp/hermitflow-rl.json`
- `/tmp/hermitflow-claude-statusline-debug.json`

## Notes

- This document reflects the current repository implementation, not Claude's official hook semantics.
- The UI does not preserve intermediate labels such as `thinking`, `working`, `juggling`, or `sweeping`; they are collapsed into `idle`, `running`, `success`, or `failure`.
- Final Claude status is a composite of hook events plus local session/project/history correction logic, not a direct one-to-one projection of raw hook events.
