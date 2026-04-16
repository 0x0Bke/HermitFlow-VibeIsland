# Claude 当前状态流转

本文档说明 HermitFlow 当前如何追踪 Claude Code 状态，包括 managed hook 注册、本地回调监听、内存 bridge 状态，以及最终进入 reducer 和 UI 的链路。

## 总览

Claude 状态不是一份独立的状态机配置文件。当前实现由 `ClaudeHookBridge` 在内存里维护两份核心状态：

- `sessions: [String: ClaudeTrackedSession]`
- `approvals: [String: ClaudePendingApproval]`

运行时入口在：

- `DynamicCLIIsland/Sources/Claude/ClaudeHookBootstrap.swift`
- `DynamicCLIIsland/State/RuntimeStore.swift`

应用启动时，HermitFlow 会：

1. 启动本地 Claude 回调监听器。
2. 重写并重新同步 managed Claude hook。
3. 轮询 Claude 与 Codex 的活动快照，合并后更新 UI。

## 启动与注册

`RuntimeStore.handleLaunch()` 会调用 `claudeHookBootstrap.bootstrap()`。

`ClaudeHookBootstrap.bootstrap()` 做两件事：

1. `callbackServer.start()`
2. `installer.resync()`

本地监听器通过 `LocalCodexSource.swift` 里的 `ClaudeHookBridge` 实现，目前：

- 监听端口 `46821`
- 支持 `GET /health`
- 支持 `GET /state`
- 处理 `POST /state`
- 处理 `POST /permission/hermitflow`

managed hook 脚本会写到：

- `~/.hermitflow/claude-hooks/hermit-claude-hook.js`

managed Claude settings 会同步到：

- `~/.claude/settings.json`
- `~/.hermitflow/claude-settings-paths.json` 里声明的额外路径
- `HERMITFLOW_CLAUDE_SETTINGS_PATHS` 环境变量里声明的额外路径

## 注册到 Claude 的 Hook

HermitFlow 当前会注册以下 Claude command hook：

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

每个 command hook 都会被注册成：

```text
"<nodePath>" "<scriptPath>" <EVENT>
```

另外还会注册：

- `PermissionRequest`，作为 HTTP hook 指向 `http://127.0.0.1:46821/permission/hermitflow`
- `statusLine`，作为 command hook 调用 `"<nodePath>" "<scriptPath>" StatusLine`

## Hook 脚本中的事件映射

生成出来的 Node.js hook 脚本，先把 Claude 事件映射成中间状态标签：

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

对于 command hook，脚本会把以下字段 POST 到 `POST /state`：

- `event`
- `state`
- `session_id`
- `cwd`
- `source`
- `client_origin`
- `terminal_client`
- `terminal_session_hint`

对于 `StatusLine`，脚本还会额外：

- 把原始 payload 写到 `/tmp/hermitflow-claude-statusline-debug.json`
- 把兼容的额度窗口写到 `/tmp/hermitflow-rl.json`

## Bridge 如何处理事件

`POST /state` 会被解码为 `ClaudeHookEventPayload`，然后写入 `ClaudeHookBridge.sessions`。

核心行为：

- `SessionEnd` 直接删除 session。
- 其他事件走 `mergedClaudeSession(...)`。
- 某些事件会顺带清掉该 session 关联的 pending approval。

Bridge 内部最终只保留四种 Claude session 状态：

- `idle`
- `running`
- `success`
- `failure`

从 hook payload 到最终内部状态的映射是：

- `error` 或 `PostToolUseFailure` 或 `StopFailure` -> `failure`
- `attention` 或 `Stop` 或 `PostCompact` -> `success`
- `notification` 或 `Notification` 或 `Elicitation` -> `idle`
- `idle` 或 `sleeping` -> `idle`
- 其他全部归为 `running`

## 状态修正与稳定规则

Bridge 在生成 UI 快照前，不只看 hook 事件，还会结合本地 Claude session/project/history 信号做修正。

关键规则：

- `Notification` 和 `Elicitation` 不会把一个正在运行的 session 错误打回 idle。
- 从 idle 切到 running，只接受显式 running 事件。
- 成功或失败后短时间内的 trailing running 事件会被忽略，避免 UI 抖动。
- project 里的 `user_prompt` 活动可以把 session 再拉回 running。
- 卡住的 prompt 会被降回 idle，并记为 `stalled_prompt`。
- interruption 或 project 推导出来的状态，可以覆盖 hook 状态，把 running 打回 idle。
- `success` 只显示 `1.25s`，`failure` 只显示 `2.0s`，之后都会回落为 idle。
- 超过 `10min` 无活动的 session 会被清理。

HermitFlow 还会从 `~/.claude/sessions` 里补发现 session，所以即便内存里的 hook 状态不完整，本地 Claude session 仍可能显示出来。

## 审批流

Claude 审批通过本地 HTTP hook 完成。

链路如下：

1. Claude 触发 `PermissionRequest`。
2. HermitFlow 收到 `POST /permission/hermitflow`。
3. Bridge 创建 `ClaudePendingApproval`。
4. 对应的 Claude session 会被强制标成 running。
5. `RuntimeStore.refreshLocalApprovalStatus()` 轮询 `claudeSource.fetchLatestApprovalRequest()`。
6. UI 展示审批请求。
7. 用户点击同意或拒绝后，通过 `HTTPHookApprovalExecutor` 执行。
8. `localClaudeSource.resolveApproval(...)` 把 HTTP JSON 响应直接写回原始 `NWConnection`。

这使 Claude 审批形成一个纯本地闭环，不依赖辅助功能自动化。

## Runtime 与 UI 集成

`RuntimeStore.refreshLocalCodexStatus()` 会同时拉：

- `localCodexSource.fetchActivity()`
- `localClaudeSource.fetchActivity()`

两个快照先经过 `ActivitySnapshotMerger` 合并，再由 `ActivitySnapshotEventAdapter` 转成 `IslandEvent`，最后进入：

- `RuntimeReducer`
- `SessionReducer`
- `ApprovalReducer`

Claude 状态最终就是这样驱动：

- session 卡片
- approval UI
- island 总状态
- focus target

## 额度与调试的附加链路

Claude 额度通过 `ClaudeUsageLoader.load()` 加载。

优先级是：

1. 本地 hook 管理的缓存
2. 命令式 provider usage 查询
3. 远程 provider 回退查询

当前链路涉及的本地文件有：

- `/tmp/hermitflow-rl.json`
- `/tmp/hermitflow-claude-statusline-debug.json`

## 说明

- 本文档描述的是当前仓库实现，不是 Claude 官方 hook 语义文档。
- UI 不会保留 `thinking`、`working`、`juggling`、`sweeping` 这些细粒度标签；它们最终都会折叠成 `idle`、`running`、`success`、`failure`。
- Claude 最终状态是“hook 实时事件 + 本地 session/project/history 修正逻辑”的合成结果，不是对原始 hook 事件的一对一直接映射。
