# HermitFlow

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
- 为可回焦会话提供一键返回入口
- 状态栏菜单支持显示/隐藏窗口、切换左侧品牌 Logo
- 状态栏菜单支持手动执行 `Resync Claude Hooks`
- 面板内置诊断卡片，可直接展示 Claude hook 同步错误
- `Codex CLI` 审批可通过 macOS 辅助功能自动执行
- `Claude Code` 通过本地 hook 接入，审批通过本地 HTTP 回调完成

## 效果展示

### 空闲态

![HermitFlow 空闲态](docs/images/idle.png)

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
- 当存在审批请求时，岛态会直接展开为审批卡片
- 面板中的 `Diagnostic` 卡片会展示 Claude hook 同步失败原因
- 可在面板或状态栏菜单中点击 `Resync Claude Hooks` 重新同步 Claude hooks
- 通过系统状态栏图标可显示/隐藏窗口，并切换左侧 Logo

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

默认生成 `Release` 版本，输出到：

- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow.app`
- `/Users/fuyue/Documents/HermitFlow/dist/HermitFlow.pkg`

如需打 `Debug` 包：

```bash
./scripts/package.sh Debug
```

## 工程结构

- `HermitFlow.xcodeproj`：Xcode 工程
- `DynamicCLIIsland/`：主应用源码
- `DynamicCLIIsland/Views/`：SwiftUI 界面
- `DynamicCLIIsland/Stores/`：状态聚合与 UI 状态管理
- `DynamicCLIIsland/Sources/`：本地 Claude / Codex 数据源与 hook 接入逻辑
- `DynamicCLIIsland/Services/`：窗口回焦、审批执行与系统交互
- `DynamicCLIIsland/Resources/`：应用使用的图片资源与资源授权文件
- `scripts/package.sh`：本地打包脚本
- `dist/`：打包输出目录

## 已知边界

- HermitFlow 依赖本机现有的 Claude / Codex 数据与进程环境，不提供远程同步
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
