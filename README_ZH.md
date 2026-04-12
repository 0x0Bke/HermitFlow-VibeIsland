# HermitFlow

[English](README.md) | [简体中文](README_ZH.md)

HermitFlow 是一个基于 SwiftUI 开发的 macOS 顶部悬浮岛应用，用来聚合展示本机 `Claude Code`、`Codex` 等会话的状态、审批请求和快速回焦入口。

它的目标不是替代终端或桌面客户端，而是在你编码时，把最重要的 CLI 状态持续放到屏幕顶部。

## 名称含义

`HermitFlow` 这个名字来自两个部分：

- `Hermit`：指寄居蟹，对应“附着在系统里运行”的 AI 或 CLI agent
- `Flow`：对应任务流、agent flow，以及 CLI 的状态流

合起来，它表达的是一种“寄居在系统中并持续流动的 AI / 任务”。

## 当前能力

- 顶部居中的无边框悬浮窗口，自动贴合屏幕安全区与摄像头区域
- 三种展示状态：隐藏态、岛态、展开面板态
- 同时聚合本机 `Claude Code` 与 `Codex` 的最近会话
- 展示会话来源、工作目录、运行状态与最近更新时间
- 检测审批请求，并在岛态或面板中直接处理
- 岛态审批支持键盘选择与确认
- 支持从本地缓存读取 `Claude Code` 与 `Codex` 的额度信息
- 在展开面板中展示本地额度进度条，不依赖网络请求
- 为 `Claude Code` 与 `Codex` 会话提供一键回焦入口
- 状态栏菜单支持显示/隐藏窗口、切换左侧品牌 Logo
- 状态栏菜单支持手动执行 `Resync Claude Hooks`
- 面板内置诊断卡片，可直接展示 Claude hook 同步错误
- `Codex CLI` 审批可通过 macOS 辅助功能自动执行
- `Claude Code` 通过本地 hook 接入，审批通过本地 HTTP 回调完成

## 效果展示

### 空闲态

![HermitFlow 空闲态](docs/images/idle.png)

### 详情面板

![HermitFlow 详情面板](docs/images/panel.png)

### 执行中

![HermitFlow 执行中](docs/images/running.png)

### 请求审批

![HermitFlow 请求审批](docs/images/approval.png)

### 执行成功

![HermitFlow 执行成功](docs/images/success.png)

## 工作方式

### Codex

应用启动后会轮询本机 `~/.codex` 下的状态文件，聚合最近活跃的 Codex 会话，并尽可能识别其来源与回焦目标。当前使用到的数据包括：

- `~/.codex/state_5.sqlite`
- `~/.codex/logs_1.sqlite`
- `~/.codex/sessions/`
- `~/.codex/.codex-global-state.json`
- `~/.codex/log/codex-tui.log`
- `~/.codex/shell_snapshots/`

如果这些文件不存在，HermitFlow 会继续运行，但 Codex 状态会显示为不可用或等待活动。

HermitFlow 也会从本地 rollout 日志中读取 Codex 额度信息：

- `~/.codex/sessions/**/rollout-*.jsonl`

应用会优先扫描较新的 rollout 文件，并提取最近一条有效的本地 `token_count.rate_limits` 数据。如果 rollout 额度数据不存在、损坏或不可用，应用其他功能不受影响，对应额度行会被直接省略。

### Claude Code

HermitFlow 已接入 Claude Code。应用启动时会执行以下初始化动作：

- 启动本地监听器，接收 Claude Code hook 事件
- 在 `~/.hermitflow/claude-hooks/` 下写入 hook 脚本
- 自动同步 Claude 配置文件，为 Claude Code 注册所需 hooks

其中：

- 状态事件通过本地 command hook 上报
- 审批请求通过本地 HTTP hook 回调到 HermitFlow
- HermitFlow 专用的审批回调路径为 `/permission/hermitflow`
- Claude 审批不依赖 macOS 辅助功能权限

如果本机没有可执行的 `node`，Claude hook 无法正常工作。

HermitFlow 也支持从自己管理的本地缓存文件读取 Claude 额度：

- `/tmp/hermitflow-rl.json`

这个文件是可选的本地产物。HermitFlow 会在 Claude hook 与 `statusLine` bridge 读到兼容的额度字段后自行写入它。如果这个文件不存在，HermitFlow 也可以回退到三方 provider 查询配置：

- `~/.hermitflow/claude-provider-usage.json`

## 运行要求

- macOS
- Xcode
- 本机已安装并使用过 `Codex` 或 `Claude Code`
- 如需 Claude Code 集成：系统环境中可执行 `node`
- 如需 Codex 自动审批：授予 HermitFlow macOS“辅助功能”权限

## 打开与运行

1. 用 Xcode 打开 [HermitFlow.xcodeproj](/Users/fuyue/Documents/HermitFlow/HermitFlow.xcodeproj)
2. 选择 `HermitFlow` scheme
3. 直接运行

首次启动时，应用会立即开始：

- 启动本地会话监控
- 尝试接入 Claude Code hooks
- 检查辅助功能权限状态

如果 Claude hook 初始化失败，应用仍可继续运行，但 Claude Code 状态与审批不会生效。相关错误会出现在面板中的 `Diagnostic` 卡片中。

## 使用方式

- 单击悬浮岛：隐藏态切到岛态，或从岛态展开到面板态
- 双击悬浮岛：从岛态或面板态切回隐藏态
- 展开面板后可查看最近会话、审批请求和会话详情
- 面板内审批卡片可直接点击 `Deny`、`Allow Once`、`Always Allow`
- 展开面板中还可以查看 `Claude` 和 `Codex` 的本地额度进度条
- 当存在审批请求时，岛态会直接展开为审批卡片
- 在岛态审批卡片中，可用 `Left` / `Right` 切换选中的审批动作，按 `Return` 直接确认
- 如果审批是在终端里直接处理的，HermitFlow 会在本地 source 观察到请求已消失或已解决后自动收起审批 UI
- 面板中的 `Diagnostic` 卡片会展示 Claude hook 同步失败原因
- 可在面板或状态栏菜单中点击 `Resync Claude Hooks` 重新同步 Claude hooks
- 可通过会话卡片或审批卡片上的回焦入口，直接拉起对应的 `Claude Code` / `Codex` 客户端
- 对于 `Claude Code` 终端会话，在存在本地 session hint 时，HermitFlow 还会尝试精确跳转到对应的 `iTerm` 标签/会话或 `Warp` 窗口
- 通过系统状态栏图标可显示/隐藏窗口，并切换左侧 Logo

### 额度展示

展开面板会在会话卡片区域显示额度信息：

- `Claude`：存在本地 Claude 缓存时展示 `5h` 与 `wk` 两个剩余额度进度条；若命中受支持的三方 Claude provider，也可通过 provider 接口展示
- `Codex`：存在本地 rollout 额度数据时展示 `5h` 与 `wk` 两个剩余额度进度条

额度展示遵循本地优先和可选降级：

- 没有额度文件：面板正常工作，只是不显示额度行
- 额度文件损坏或格式不兼容：面板正常工作，只是不显示对应 provider 的额度行
- 若识别到受支持的三方 provider 且远程额度查询成功：Claude 行/卡片会显示为 `Claude · <Provider>`

当前 UI 展示的是剩余额度，而不是已使用额度。

对于 Claude，是否能显示额度取决于本地 payload 形状或受支持 provider 的响应结构。只有当上游 payload 提供官方 Claude 风格的 `rate_limits.five_hour` 与 `rate_limits.seven_day`，或者三方 provider 响应能被映射为兼容窗口时，HermitFlow 才会显示 `5h` / `wk`。某些第三方 Anthropic 兼容模型只提供 context window 信息，或者完全不提供 rate limit 字段，此时 Claude 活动和审批仍然可用，但 Claude 额度不会显示。

### Claude 三方 Provider

HermitFlow 可以通过以下信息识别受支持的 Claude 三方 provider：

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_MODEL`
- 最近一次受管 Claude `statusLine` payload

provider 查询配置文件位于：

- `~/.hermitflow/claude-provider-usage.json`

首次启动会自动写入默认模板，内置：

- `Kimi`
- `Zhipu`
- `ZenMux`
- `MinMax`

当前内置默认接口：

- `Kimi`: `https://api.kimi.com/coding/v1/usages`
- `Zhipu`: `https://api.z.ai/api/monitor/usage/quota/limit`
- `ZenMux`: `https://zenmux.ai/api/v1/management/subscription/detail`
- `MinMax`: `https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`

每个 provider 配置项可定义：

- 如何识别该 provider
- 该调用哪个额度接口
- 认证 header 名称和前缀如何拼装
- 请求头、query、body 如何构造
- `Authorization: Bearer <token>` 应读取哪个 `authEnvKey`
- 如何把 provider 响应映射成 Claude `5h` / `wk` 窗口

`authEnvKey` 现在支持两种写法：

- Claude `settings.json.env` 中的环境变量名
- 直接写真实 token，例如 `sk-...`

如果 `~/.hermitflow/claude-provider-usage.json` 已经存在，HermitFlow 不会自动覆盖它。默认接口变更后，需要手动更新本地文件。

对于响应结构不统一的 provider，HermitFlow 也内置了 provider-specific 解析逻辑：

- `ZenMux`：解析 `data.quota_5_hour` 和 `data.quota_7_day`
- `MinMax`：解析 `model_remains[]`，优先匹配当前 Claude 模型，再回退到 `MiniMax-M*`
- `Kimi`：解析 `limits[].detail` 和顶层 `usage`
- `Zhipu`：解析 `data.limits[]` 中 `type == TOKENS_LIMIT` 的额度项

也就是说，某些 provider 即使无法只靠静态 JSON path，也仍然可以正常展示额度。

## 权限与配置

### 辅助功能权限

只有 `Codex CLI` 的自动审批依赖 macOS“辅助功能”权限。未授权时，HermitFlow 会在面板中显示提示，并提供打开系统设置入口。

### Claude 配置写入

为了接入 Claude Code，HermitFlow 默认会更新 `~/.claude/settings.json` 中的 `hooks` 配置，并写入自己的本地 hook 脚本。如果你有自定义 Claude hooks，HermitFlow 会尝试增量更新自身相关条目，而不是覆盖整个配置文件。

当前支持的写入目标包括：

- 默认路径：`~/.claude/settings.json`
- 额外路径配置文件：`~/.hermitflow/claude-settings-paths.json`
- 额外环境变量：`HERMITFLOW_CLAUDE_SETTINGS_PATHS`

`~/.hermitflow/claude-settings-paths.json` 支持两种格式：

- JSON 数组，例如 `["~/custom-claude/settings.json", "/opt/company/claude/settings.json"]`
- 对象形式，例如 `{"paths":["~/custom-claude/settings.json","/opt/company/claude/settings.json"]}`

环境变量 `HERMITFLOW_CLAUDE_SETTINGS_PATHS` 支持使用换行或分号分隔多条路径。

默认路径 `~/.claude/settings.json` 始终会保留在同步列表中。

另外，以下特殊情况也会被安全处理：

- 自定义 `settings.json` 不存在：会自动创建
- 自定义 `settings.json` 是空文件：会按空对象 `{}` 处理后写入
- `claude-settings-paths.json` 带有常见的尾随逗号：会做兼容解析

## 打包

仓库内置了本地打包脚本：

```bash
./scripts/package.sh
```

默认会按当前机器架构生成 `Release` 版本，输出文件名格式为 `HermitFlow-<arch>.app` 和 `HermitFlow-<arch>.pkg`。

例如在 Apple Silicon 机器上会输出：

- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow-arm64.app`
- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow-arm64.pkg`

如果要在 Apple Silicon 机器上打 Intel (`x86_64`) 安装包：

```bash
./scripts/package.sh Release intel
```

会输出：

- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow-intel.app`
- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow-intel.pkg`

如需打 `Debug` 包：

```bash
./scripts/package.sh Debug
```

## 工程结构

- `HermitFlow.xcodeproj`：Xcode 工程
- `DynamicCLIIsland/`：主应用源码
- `DynamicCLIIsland/App/`：应用环境与启动装配
- `DynamicCLIIsland/Core/`：共享模型、reducer、协议、工具与事件定义
- `DynamicCLIIsland/State/`：应用级、运行时和展示层 store
- `DynamicCLIIsland/Views/`：SwiftUI 界面
- `DynamicCLIIsland/Views/Approval/`：审批相关视图
- `DynamicCLIIsland/Views/Diagnostics/`：诊断相关视图
- `DynamicCLIIsland/Views/Usage/`：本地额度卡片与摘要视图
- `DynamicCLIIsland/Stores/`：状态聚合与 UI 状态管理
- `DynamicCLIIsland/Sources/`：本地 Claude / Codex 数据源与 hook 接入逻辑
- `DynamicCLIIsland/Services/`：窗口回焦、审批执行、诊断、额度与系统交互
- `DynamicCLIIsland/Coordinators/`：窗口、菜单栏和监控协调器
- `DynamicCLIIsland/Legacy/`：重构过程中保留的兼容适配层
- `DynamicCLIIsland/Resources/`：应用使用的图片资源与资源授权文件
- `scripts/package.sh`：本地打包脚本
- `dist/`：打包输出目录

## 已知边界

- HermitFlow 依赖本机现有的 Claude / Codex 数据与进程环境，不提供远程同步
- 额度信息依赖本地缓存或 rollout 文件，即使已安装 Claude / Codex，也可能暂时没有可展示的额度数据
- Claude 额度依赖本地 Claude payload 的字段形状；某些第三方 Anthropic 兼容 provider 不会暴露 `5h` / `7d` rate limit 窗口
- Claude Code 集成依赖本地 hook 机制和 `node`
- Codex 自动审批依赖辅助功能权限以及终端前台控制能力
- 如果 CLI 会话已经退出、窗口已关闭，部分“回到会话”入口可能不可用
- 如果目标 Claude 配置文件本身不是合法 JSON 对象，HermitFlow 不会强行覆盖该文件

## License

源代码采用 [MIT License](LICENSE) 进行授权。

**图片与美术资源（[DynamicCLIIsland/Resources](/Users/fuyue/Documents/HermitFlow/DynamicCLIIsland/Resources)）不包含在 MIT 授权范围内。** 其权利归各自版权持有人所有。详情见 [DynamicCLIIsland/Resources/LICENSE](/Users/fuyue/Documents/HermitFlow/DynamicCLIIsland/Resources/LICENSE)。

- **Clawd、Claude Code** 相关角色与图形资产归 [Anthropic](https://www.anthropic.com) 所有。
- **Codex、OpenAI** 相关角色与图形资产归 [OpenAI](https://www.openai.com) 所有。
- **ZenMux** 相关角色与图形资产归 [Zenmux](https://www.zenmux.ai) 所有。
- 本项目为非官方同人项目，与上述平台或机构无关联，亦未获得其认可或背书。
- 第三方贡献内容的版权归各自作者所有。
