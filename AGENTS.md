# AGENTS.md — 给 AI 协作 Agent 的项目指南

本文件是项目唯一的「面向 AI 阅读」的入口文档。任何 AI Agent（Claude
Code / Cursor / Codex / Gemini Code Assist / Cline 等）在开始工作前
都应先读完本文，再去翻代码。本文回答四个问题：

1. **这是什么项目？** —— 一句话定位 + 用户视角
2. **代码长什么样？** —— 单文件 Swift 应用的结构地图
3. **状态推断怎么做？为什么这么做？** —— 核心算法与设计原则
4. **开发与发布流程？** —— 构建、安装、调试、提交规范

---

## 1. 项目一句话定位

豆包输入法 / 微信输入法的 macOS 菜单栏中英文状态指示器。**单文件
Swift 应用**（[Sources/DoubaoInputIndicator.swift](Sources/DoubaoInputIndicator.swift)，约 1700
行），通过编译期 `-D WETYPE` flag 切出两个产品（豆包版 / 微信版）。

### 用户视角

菜单栏出现一个 emoji 图标，指示当前 IME 的中英文子状态：

| 图标 | 含义 |
|---|---|
| `🇨🇳` | 中文模式 |
| `🇺🇸` | 英文模式 |
| `🫥` | 状态未知，需要校准或等待自动校准 |
| `🤐` | 当前不是目标输入法（豆包/微信），不显示状态 |
| `🥶` | 输入监控权限未开启 |

`LSUIElement` accessory 应用——无 Dock 图标、无主窗口，常驻菜单栏。

### 为什么需要这个东西

豆包、微信输入法的「中文 / 英文」子状态保存在它们自己的进程内存里，
**没有任何官方 API 能从外部读到**（详见 §3.4 的调研结论）。系统输入
法菜单只能显示「当前选中了哪个输入法」，无法显示该输入法内部的中英
状态。因此本项目用多种间接信号（Shift 键、候选词窗、AX 模式指示框）
推断状态。

---

## 2. 代码结构地图

### 仓库布局

```
input-indicator/
├── AGENTS.md                       ← 本文件，AI 入口
├── README.md                       ← 用户视角的安装与使用文档
├── DEVELOPMENT_CONTEXT.md          ← 仅本地，作者私人开发笔记（.gitignore）
├── Sources/
│   └── DoubaoInputIndicator.swift  ← 全部业务代码，单文件
├── Resources/
│   └── AppIcon.icns                ← 应用图标
├── tools/
│   └── make_app_icon.swift         ← 从 emoji 生成 iconset 的脚本
├── packaging/
│   └── dmg/                        ← DMG 打包用的 .DS_Store / 背景图
├── scripts/
│   └── package-release.sh          ← 同时打两个 zip 给 Homebrew tap 用
├── docs/
│   └── images/                     ← README 用图
├── build.sh                        ← swiftc + lipo + codesign，输出 build/<App>.app
├── install.sh                      ← 构建 + 装到 /Applications + LaunchAgent
├── uninstall.sh                    ← 反向操作
└── package-dmg.sh                  ← 从 build/<App>.app 打 dmg 到 dist/
```

### 单文件源码结构（[Sources/DoubaoInputIndicator.swift](Sources/DoubaoInputIndicator.swift)）

按出现顺序：

| 行号 | 符号 | 职责 |
|---|---|---|
| [L7-L38](Sources/DoubaoInputIndicator.swift#L7) | `enum DisplayMode` | 状态枚举（chinese / english / unknown / nonTarget） + 显示用的 emoji 标题 |
| [L40-L47](Sources/DoubaoInputIndicator.swift#L40) | `struct AppConfig` | 变体配置：app 名、目标 IME bundle ID、UserDefaults key、日志文件名 |
| [L49-L82](Sources/DoubaoInputIndicator.swift#L49) | GitHub release 工具 | `VersionNumber` 比较 + 检查更新所需的 URL 常量 |
| [L84-L102](Sources/DoubaoInputIndicator.swift#L84) | `#if WETYPE` 分支 | **唯一**编译期分歧：豆包 vs 微信的 `appConfig` 实例 |
| [L104-L131](Sources/DoubaoInputIndicator.swift#L104) | `class InputSourceReader` | `TISCopyCurrentKeyboardInputSource` 的封装，返回当前输入源标识 |
| [L133-L347](Sources/DoubaoInputIndicator.swift#L133) | `class CandidateWindowMonitor` | 候选窗 / 模式指示器小窗口的扫描与 AX 文本读取（**核心算法在这里**） |
| [L349-L1694](Sources/DoubaoInputIndicator.swift#L349) | `class AppDelegate` | 状态机、事件监听、菜单构建、权限管理、日志、自启、更新检查 |
| [L1696-L1699](Sources/DoubaoInputIndicator.swift#L1696) | 入口 | `NSApplication.shared.run()` |

### `CandidateWindowMonitor` 关键方法

| 行号 | 方法 | 用途 |
|---|---|---|
| [L189-L247](Sources/DoubaoInputIndicator.swift#L189) | `snapshot(bundleID:indicatorMinSize:indicatorMaxSize:logHandler:)` | 一次扫描，返回候选窗是否可见 + 所有指示器小窗口的 ID 与屏幕矩形 |
| [L256-L274](Sources/DoubaoInputIndicator.swift#L256) | `cachedFindIMEProcessID(_:)` | PID 5 秒缓存，避免每次都扫 `runningApplications` |
| [L292-L315](Sources/DoubaoInputIndicator.swift#L292) | `recognizeModeFromIndicatorRect(pid:rect:)` | **窄域 AX 读取**：只读指示器矩形上的 AX 子树，严格匹配单字符「中」「英」 |
| [L319-L345](Sources/DoubaoInputIndicator.swift#L319) | `collectTexts(from:into:depth:maxDepth:childCap:)` | 受限的 AX 子树文本收集，深度 ≤3、每层 ≤8 子节点 |

### `AppDelegate` 关键方法

| 行号 | 方法 | 用途 |
|---|---|---|
| [L431-L458](Sources/DoubaoInputIndicator.swift#L431) | `applicationDidFinishLaunching` | 装事件 tap、装权限、起 0.3s 主轮询 timer |
| [L506-L554](Sources/DoubaoInputIndicator.swift#L506) | `installEventTap` | 装 CGEvent listen-only tap（要 Input Monitoring 权限） |
| [L568-L582](Sources/DoubaoInputIndicator.swift#L568) | `installGlobalMonitor` | NSEvent 全局监听 fallback |
| [L591-L646](Sources/DoubaoInputIndicator.swift#L591) | `handle(event:)` / `handle(type:event:)` | 把 NSEvent / CGEvent 路由到 keyDown / mouseDown / flagsChanged |
| [L653-L725](Sources/DoubaoInputIndicator.swift#L653) | `pollCandidateWindow` | **每 0.3s 调一次**，触发指示器窗 AX 读取与候选窗校准 |
| [L768-L811](Sources/DoubaoInputIndicator.swift#L768) | `noteAlphaKeyDown` | 累计 alpha 键计数，安排 0.25s 后的延迟候选窗检查 |
| [L814-L854](Sources/DoubaoInputIndicator.swift#L814) | `performCandidateWindowCheck` | 候选窗看到 → 中文。**注意：候选窗没看到不会推断英文**（见 §3） |
| [L1010-L1156](Sources/DoubaoInputIndicator.swift#L1010) | `handleFlagsChanged` / `handleShiftKeyChange` / `finishShiftTap` | Shift 翻转的完整状态机 |
| [L1145-L1156](Sources/DoubaoInputIndicator.swift#L1145) | `schedulePostShiftVerification` | Shift 后 0.15 / 0.4 / 0.7 秒各跑一次 `pollCandidateWindow`，捕获指示器窗 |
| [L1176-L1190](Sources/DoubaoInputIndicator.swift#L1176) | `markTargetModeUnknown` | 失去信心时清空状态，显示 🫥 |
| [L1236-L1351](Sources/DoubaoInputIndicator.swift#L1236) | `rebuildMenu` | 菜单完整重建（每次状态变化或菜单将打开时） |

### 两个变体的差异点

整个项目只有 [L84-L102](Sources/DoubaoInputIndicator.swift#L84) 一处 `#if WETYPE` 分支：

| 字段 | 豆包 | 微信 |
|---|---|---|
| `appName` | `DoubaoInputIndicator` | `WeTypeInputIndicator` |
| `displayName` | `豆包输入法指示器` | `微信输入法指示器` |
| `targetInputMethodBundleID` | `com.bytedance.inputmethod.doubaoime` | `com.tencent.inputmethod.wetype` |
| `launchAgentID` | `local.doubao-input-indicator` | `local.wetype-input-indicator` |
| `modeStateKey`（UserDefaults） | `doubaoModeChinese` | `wetypeModeChinese` |
| `logFileName` | `DoubaoInputIndicator.log` | `WeTypeInputIndicator.log` |

[build.sh](build.sh) 通过 `-D WETYPE` 切换，编译两份 universal binary。

---

## 3. 状态推断算法（核心知识点）

### 3.1 核心原则：正向证据策略（Positive-Evidence Policy）

> 只在拿到「中文」的正向证据时切到中文；只在拿到「英文」的正向证据
> 时切到英文。任何信号的*缺席*都不允许推断为另一种状态。
>
> 不确定时显示 🫥（未知），让用户手动校准或等待权威信号到来。
>
> **宁可显示「未知」，也不要显示错的。**

这是 v1.2.x 系列的核心修订动机。早期版本会从「连续敲了 ≥2 个字母却
没看到候选窗」推断为英文模式，是「莫名其妙跳到🇺🇸」误判的主要来源。

### 3.2 三层校准信号（按可靠度从高到低）

#### 第一层：Accessibility 模式指示器（最可靠，窄域读取）

豆包 / 微信在按 Shift 切换模式时会弹一个约 25×28 pt 的小提示窗，里
面画一个「中」或「英」字符。读取流程见
[`pollCandidateWindow`](Sources/DoubaoInputIndicator.swift#L653) →
[`recognizeModeFromIndicatorRect`](Sources/DoubaoInputIndicator.swift#L292)：

1. 每 0.3s 用 `CGWindowListCopyWindowInfo` 扫描 IME 进程的高 layer
   窗口（layer ≥ `2_147_483_000`，Doubao 实测用 `2_147_483_628`）
2. 把尺寸落在 15–50 pt 方形范围的窗口认成"指示器候选"，记录其 `kCGWindowBounds`
3. 与上一轮的 ID 集合做差，只对**新出现**的窗口触发读取
4. 读取过程：
   - 用 `AXUIElementCreateApplication(pid)` 拿到 IME 进程根
   - 用 `AXUIElementCopyElementAtPosition(_, x, y, _)` 命中那个矩形中心点上的 AX 元素
   - 只走那个元素的子树，深度 ≤ 3、每层 ≤ 8 个子节点
   - 读 `kAXValueAttribute` / `kAXTitleAttribute` / `kAXDescriptionAttribute`
   - **必须** trim 后严格等于 `中` 或 `英` 才接受

**为什么这样写**（这条非常重要，避免 AI 退化回旧实现）：

历史上是扫整个 IME 进程的 AX 树，对所有文本做
`text.contains("中") || text.contains("英")`。这会被设置面板里的「英语
词典」「英文标点」等字眼误吃，导致状态错乱。命中点 + 浅子树 + 严格
单字符匹配三层防线后，可以排除上述几乎所有误识别场景。**不要回退到
全树扫描或 contains 匹配。**

#### 第二层：候选词窗口可见性（仅作中文正向证据）

候选词面板可见时设为中文。判定条件（[L233-L237](Sources/DoubaoInputIndicator.swift#L233)）：

- 高 layer（≥ `2_147_483_000`）窗口
- 高度 ≥ 40 pt 的"高面板"，**或**
- 高度 ≥ 24 pt 且宽度 ≥ 100 pt 的"单行面板"（豆包有时候候选窗只有一行）

**反过来不成立**：候选词面板缺席不能推断英文，因为候选词在中文模式
下也常常不显示，例如：

- 焦点在密码框（系统强制旁路 IME）
- 焦点在豆包自己的搜索框 / 设置面板
- 焦点在不实现 IMK 协议的控件（部分终端、某些 Electron / 游戏窗口）
- 用户刚上屏一个词，候选窗短暂消失
- IME 卡顿或网络云候选延迟

#### 第三层：Shift 翻转（最低可靠度，但是唯一的"翻转"信号）

当模式已经为已知值，并且观察到一次干净的独立 Shift 按下与抬起，则
翻转。完整状态机在
[`handleShiftKeyChange`](Sources/DoubaoInputIndicator.swift#L1020) →
[`finishShiftTap`](Sources/DoubaoInputIndicator.swift#L1052)。

要求：

- 中间没有别的键盘 / 鼠标活动（`shiftHadOtherKey == false`）
- 持续时间 ≤ `maximumStandaloneShiftTapDuration` (1.0s)
- 按下到抬起之间输入源没变（`currentSource.id == shiftDownSourceID && bundleID == shiftDownBundleID`）
- 距上次翻转 ≥ `minimumShiftToggleGap` (0.35s) ——豆包内部有
  `ShiftKeyEventCoalescer` 去抖，我们模仿它

实现细节：

- 同时挂 `CGEvent.tapCreate(..., .listenOnly, ...)` 和
  `NSEvent.addGlobalMonitorForEvents(...)`，前者优先后者作降级，避免
  双重计数（[`installGlobalMonitor`](Sources/DoubaoInputIndicator.swift#L568) 仅在 event tap 失败时启用）
- 1 秒启动忽略窗（`ignoreEventsUntil`），跳过启动瞬间的余留 modifier 状态
- Shift 翻转后立即调度 0.15s / 0.4s / 0.7s 三次"验证 burst"（[`schedulePostShiftVerification`](Sources/DoubaoInputIndicator.swift#L1145)）重新跑 `pollCandidateWindow`，捕获 IME 在模式切换瞬间弹出的指示器窗
- 翻转后 `autoCalibrationCooldown` (2.0s) 内禁用候选窗 polling 校准，避免残留候选窗瞬时把状态又改回去

### 3.3 何时进入「未知」状态

[`markTargetModeUnknown`](Sources/DoubaoInputIndicator.swift#L1176) 会被以下情况触发：

- 启动忽略窗内出现 Shift（可能漏掉一次切换）
- 一次独立 Shift 按下持续过长（用户可能挂着 Shift 改主意了）
- Shift 按下到抬起之间输入源发生变化
- 从其它输入法切回目标 IME（多数 IME 重新激活时会重置内部模式）

进入未知后，下一次拿到任意一种正向证据（候选窗 / AX 指示器读取 /
手动校准）就会重新锁定状态。

### 3.4 调研结论：豆包内部状态可观察面

为评估「能不能拿到更权威的状态信号」，对本机豆包 IMK bundle 做过端
到端排查。**结论：没有任何合规的外部读取手段能拿到豆包的内部
`enMode`。所有信号都只能是 IMK 协议的副作用。**

#### 磁盘层面：没有反映中英文状态的文件

| 路径 | 内容 | 用得上吗 |
|---|---|---|
| `~/Library/Preferences/com.bytedance.inputmethod.doubaoime.plist` | 仅 `oime.device_id` / `oime.vendor_id` | ❌ |
| `~/Library/Preferences/com.bytedance.inputmethod.doubaoime.settings.plist` | 仅 `oime.device_id` | ❌ |
| `~/Library/Application Support/DoubaoIme/MMKV/com.apple.xpc.activity` | 16K 全 0，XPC 调度活动占位 | ❌ |
| `~/Library/Application Support/DoubaoIme/EngineUserDict/*.dat` | 用户词库二进制 | ❌ |
| `~/Library/Application Support/DoubaoIme/Crash/settings.dat` | 40 字节 Crash 上报句柄 | ❌ |
| `~/Library/Caches/com.bytedance.inputmethod.doubaoime/Cache.db` | NSURLCache | ❌ |

中英文状态完全不写盘——按 Shift 是高频操作，写盘会损耗 SSD 且无必要。

#### 日志：有但加密

豆包用字节自家的 **alog** 框架写日志到
`~/Library/Application Support/DoubaoIme/Log/alog/log/*.alog.hot`，文
件头 magic `a1 09 00 00 ...` + AES 加密负载。GitHub 上 `bytedance/alog`
仅是写库，不公开解密工具。即便能解密，这也只是事后日志，不能用来实
时查询状态。

#### 二进制：状态字段确实存在，但拿不到

`otool -ov /Library/Input\ Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme`
反汇编结果：

- Swift 类 `DoubaoIme.InputState`（混淆名 `_TtC9DoubaoIme10InputState`）
- 单例 `sharedInstance`
- 成员变量 `enMode`：Bool，偏移 +16，`true` = 英文，`false` = 中文
- 相关方法 `switchToEnglish:`、`selectInputMode:`
- 配置项 `useShiftToSwitchBetweenChineseAndEnglish`

但豆包**没有**暴露任何 IPC 把这个状态广播出去。`strings` 全扫无
`MachServiceName`、无 `NSXPCConnection`、无任何 mode/state 相关的
distributed notification 名。唯一的 `com.bytedance.persistence` 是
它们的持久化框架内部用，跟模式无关。跨进程读 `enMode` 的内存需要
`task_for_pid()`（root + 关 SIP），不现实；进程注入也行不通，IMK
bundle 由 macOS 加载并强制校验代码签名。

### 3.5 后续可能的增强：D2（Marked Text 观察）

未来可以加一层："监听焦点应用文本框的
`kAXSelectedTextChangedNotification`，用户敲 alpha 键后焦点元素出
现 marked text → 中文模式；value 直接增长且 marked text 始终为空 →
英文模式。"

这个信号源于 IMK 协议层面的强制约定（任何 IMK 输入法在合成中文时都
必须把 marked text 写入 client text input），跨输入法实现一致，比观
察豆包自己的窗口更稳定。

代价：

- 需要管理 `AXObserver` 生命周期，跟随焦点元素切换 attach / detach
- 部分应用的 AX text field 不暴露 marked range：Electron（VSCode、
  Slack、Discord）、Chrome web 输入框、终端（Terminal、iTerm、
  Alacritty）。这些场景要降级回前面三层

引入前应先做最小 PoC 验证常用 app 的 marked text 信号是否稳定，再
决定是否全量上。

### 3.6 已被弃用 / 不要回退的方案

| 方案 | 为什么放弃 |
|---|---|
| 全 IME 进程 AX 树 + `text.contains("中"/"英")` | 被设置面板、词典窗口里的「中」「英」字误吃 |
| "敲了 ≥2 个字母没看到候选窗 → 推断英文" | 候选窗在中文模式下也常缺席（密码框、Electron、IME 自己的搜索框等） |
| 写一个 IMK bundle 探针拿系统级事件 | 只能更早收到「输入源切换」事件，**完全解决不了**「中/英子状态」根本问题 |
| 跨进程读豆包内存的 `InputState.enMode` | 需要 root + 关 SIP，不合规 |

---

## 4. 工程化规范

### 4.1 构建

```bash
./build.sh doubao    # → build/DoubaoInputIndicator.app
./build.sh wetype    # → build/WeTypeInputIndicator.app
```

[build.sh](build.sh) 流程：

1. 清空 `build/`
2. `swiftc` 分别编译 arm64 和 x86_64 切片
3. `lipo -create` 合并成 universal binary
4. 拷贝 `Resources/AppIcon.icns`
5. 写 `Info.plist`（含 `LSUIElement=true`、版本号、构建时间）
6. `codesign --force --deep --sign -`（ad-hoc 签名）

环境变量：

- `APP_VERSION` 覆盖版本号（默认见 build.sh 顶部）
- `REGENERATE_APP_ICON=1` 重新从 emoji 生成图标

### 4.2 安装与调试

```bash
./install.sh doubao  # 停旧进程 → 构建 → 装到 /Applications → 写 LaunchAgent → 启动
./install.sh wetype
./uninstall.sh doubao
```

调试 verbose 日志：

```bash
defaults write local.doubao-input-indicator verboseEventLogging -bool true
# 或微信版
defaults write local.wetype-input-indicator verboseEventLogging -bool true
```

日志位置：

- `~/Library/Logs/DoubaoInputIndicator.log`
- `~/Library/Logs/WeTypeInputIndicator.log`

超过 1 MB 自动轮转为 `.old`。菜单的「日志」「清空日志」可便捷访问。

### 4.3 发布流程

发布走 [scripts/package-release.sh](scripts/package-release.sh) 同时打两个 zip，配合相邻仓库
`/Users/zhou/Projects/demo/homebrew-tap` 的 cask。完整步骤参考
DEVELOPMENT_CONTEXT.md（仅本地，含具体路径和步骤）。

### 4.4 提交规范

- Commit message 用中文 + Conventional Commits 前缀（`fix:` / `feat:` /
  `docs:` / `refactor:`）。第一行简短描述，空行后写 body 解释「为什么」
  和影响面
- 每个 commit 末尾自动加 `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
  当 AI Agent 参与时
- 遵循 user 全局 CLAUDE.md 中的 git 安全协议：永不 amend、永不
  `--no-verify`、不主动 push（用户明示后再 push）

### 4.5 权限说明

应用需要两类权限：

1. **辅助功能（Accessibility）**：用于读取 IME 进程的 AX 树。第一次
   启动会用 `AXIsProcessTrustedWithOptions` 拉起授权弹窗
2. **输入监控（Input Monitoring）**：用于监听 Shift 等全局键盘事件。
   通过 `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`
   检查与请求

注意 ad-hoc 签名的本地构建，macOS 可能在 `CGPreflightListenEventAccess`
返回 `false` 即便事件实际可观察。代码中有 fallback：只要
[`noteInputEvent`](Sources/DoubaoInputIndicator.swift) 实际收到过任何事件，就把权限当成"实际可用"。

---

## 5. 给 AI 的工作守则

在本仓库做改动时：

- **优先编辑** [Sources/DoubaoInputIndicator.swift](Sources/DoubaoInputIndicator.swift)（业务全在这一个文件）
- **改完必须**两个变体都编译过：`./build.sh doubao && ./build.sh wetype`
- **改状态推断逻辑**前，先重读 §3 的「正向证据策略」和「已被弃用方
  案」表，避免回退到旧错误
- **有 UI 变化**（菜单项、tooltip、emoji）记得在 [README.md](README.md) 同步更新
- **状态推断逻辑变化**记得回头更新本文 §3 对应小节
- 不要新建 `docs/ARCHITECTURE.md` / `CONTRIBUTING.md` / `CLAUDE.md` 等
  并行的"AI 文档"——本项目唯一的 AI 入口就是这个 AGENTS.md
- 只有作者本机才用得上的内容（PID、release 路径、个人安装位置）放
  到 [DEVELOPMENT_CONTEXT.md](DEVELOPMENT_CONTEXT.md)（已在 .gitignore），不要入库
