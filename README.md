# 中文输入法指示器

![macOS](https://img.shields.io/badge/macOS-12.0%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-brightgreen)
![Intel](https://img.shields.io/badge/Intel-supported-brightgreen)
![Release](https://img.shields.io/github/v/release/jianzhoujz/input-indicator)

一个专为豆包输入法、微信输入法设计的 macOS 菜单栏状态指示器。

它用一个简洁的菜单栏图标显示当前是中文模式还是英文模式，不占用 Dock，不打开主窗口，适合长期常驻使用。

> 🤖 **AI 协作 Agent / 贡献者请先看 [AGENTS.md](AGENTS.md)**：这是项目唯一的"面向 AI 阅读"入口文档，包含代码结构地图、状态推断算法、调研结论、构建发布规范。

## 介绍

部分第三方中文输入法会把“中文 / 英文”状态保存在输入法进程内部。macOS 自带输入法菜单通常只能显示当前输入法，不能稳定显示输入法内部的中英文模式。

中文输入法指示器通过监听当前输入法和 Shift 切换行为，在菜单栏提供一个稳定、直观的状态提示：

| 图标 | 含义 |
| --- | --- |
| `🇨🇳` | 中文模式 |
| `🇺🇸` | 英文模式 |
| `🫥` | 中英文状态未知，需要校准或等待自动校准 |
| `🤐` | 当前不是目标输入法 |
| `🥶` | 输入监控权限未开启或未确认 |

当前提供两个版本：

| 版本 | 适用输入法 | 应用名称 | Homebrew Cask |
| --- | --- | --- | --- |
| 豆包输入法指示器 | 豆包输入法 | `DoubaoInputIndicator.app` | `doubao-input-indicator` |
| 微信输入法指示器 | 微信输入法 | `WeTypeInputIndicator.app` | `wetype-input-indicator` |

## 安装

推荐使用 Homebrew 安装。先添加 tap：

```bash
brew tap jianzhoujz/tap
```

然后根据你使用的输入法二选一安装。

### 豆包输入法

```bash
brew install --cask doubao-input-indicator
```

### 微信输入法

```bash
brew install --cask wetype-input-indicator
```

### 更新

豆包输入法指示器：

```bash
brew update
brew upgrade --cask doubao-input-indicator
```

微信输入法指示器：

```bash
brew update
brew upgrade --cask wetype-input-indicator
```

### 卸载

```bash
brew uninstall --cask doubao-input-indicator
brew uninstall --cask wetype-input-indicator
```

### 手动安装

如果不使用 Homebrew，可以从 [GitHub Releases](https://github.com/jianzhoujz/input-indicator/releases) 下载对应压缩包：

- `DoubaoInputIndicator-版本号.dmg`
- `WeTypeInputIndicator-版本号.dmg`

打开 `.dmg` 后，将应用拖到窗口里的 `Applications` 快捷方式，然后从 `/Applications` 启动应用。

## 首次启动

当前应用没有 Apple Developer ID 签名。首次启动时，macOS 可能提示无法验证开发者、应用已损坏，或者阻止打开。

如果你确认应用来源可信，可以先尝试：

1. 打开 `系统设置 -> 隐私与安全性`
2. 在安全性提示中选择 `仍要打开`
3. 再次启动应用

如果仍然无法打开，可以移除 quarantine 标记。

豆包输入法版本：

```bash
xattr -dr com.apple.quarantine /Applications/DoubaoInputIndicator.app
```

微信输入法版本：

```bash
xattr -dr com.apple.quarantine /Applications/WeTypeInputIndicator.app
```

## 使用说明

启动后，应用会出现在 macOS 菜单栏。点击菜单栏图标可以打开菜单。

菜单中提供：

- `开机启动`：登录 macOS 后自动启动
- `版本`：查看当前安装版本
- `检查更新...`：检查 GitHub Releases 中的新版本
- `退出`：退出应用

应用启动时状态为「未知」（`🫥`），通过以下方式自动校准：

- **Accessibility 模式指示器（窄域读取）**：按 Shift 切换中英文时，豆包输入法会弹出一个「中」/「英」提示窗口。应用先用 `CGWindowList` 找到那个特定的小窗口及其屏幕矩形，再用 `AXUIElementCopyElementAtPosition` 命中该矩形上的 AX 元素，只读这个子树（深度 ≤ 3、每层 ≤ 8 个子节点），且要求 trim 后的文本严格等于 `中` 或 `英`。这样可以避免被输入法设置面板、词典窗口里出现的「中」「英」字误触发。这是最可靠的校准方式。
- **候选词窗口检测（仅作中文正向证据）**：目标输入法出现候选词窗口时，自动校准为中文。**反过来不成立**：候选词窗口缺席不会被推断为英文模式，因为用户可能正在密码框、终端、Electron 应用或输入法自己的搜索框里输入，候选词本就不会出现。
- 候选词窗口检测采用自适应轮询：活跃输入时快速扫描，空闲时自动降频以节省 CPU。
- **英文模式的判定**仅来自两个强信号：Shift 翻转（已知中文 → Shift 后翻为英文）、或 Accessibility 读到「英」字符。其它情况一律保留原状态或显示 `🫥`，宁可显示未知，也不显示错的。

如果显示状态和实际输入状态不一致，可以在菜单中手动校准：

- `校准为中文`
- `校准为英文`

如果应用检测到可能漏掉了一次 Shift 切换，例如启动瞬间按了 Shift，或者 Shift 按下到松开期间输入源发生变化，菜单栏会显示 `🫥`。这种情况下可以使用菜单里的校准项重新同步，或继续输入让候选词窗口自动校准。

### 输入监控权限

如果菜单显示输入监控权限未完成，请打开：

```text
系统设置 -> 隐私与安全性 -> 输入监控
```

然后启用对应应用：

- `DoubaoInputIndicator.app`
- `WeTypeInputIndicator.app`

授权后请退出并重新启动应用。

没有输入监控权限时，应用仍可通过候选词窗口自动校准为中文，也可通过 Shift 后的 Accessibility 模式指示器读取来校准。英文模式只能依靠 Shift 翻转或 Accessibility 读到「英」字符来判定。

菜单中的 Shift 监听状态会显示当前权限信息：已启用或等待授权。

### 调试模式

启动时传入参数可开启详细事件日志：

```bash
defaults write local.doubao-input-indicator verboseEventLogging -bool true
```

开启后，日志文件会记录窗口扫描详情等额外信息，便于定位状态机问题。关闭：

```bash
defaults delete local.doubao-input-indicator verboseEventLogging
```

日志文件位于 `~/Library/Logs/DoubaoInputIndicator.log`（或 `WeTypeInputIndicator.log`），超过 1 MB 自动轮转。可通过菜单中的「日志」打开日志目录，「清空日志」删除所有日志文件。

## 开发构建

本仓库提供简单的构建和安装脚本：

```bash
./build.sh doubao
./build.sh wetype
```

`build.sh` 只生成 `build/<AppName>.app`，不直接运行。

生成面向用户分发的 DMG：

```bash
./package-dmg.sh doubao
./package-dmg.sh wetype
```

DMG 会输出到 `dist/`，窗口中包含应用、`Applications` 快捷方式和拖拽安装提示背景图。

开发调试时使用：

```bash
./install.sh doubao
./install.sh wetype
```

`install.sh` 会先停止正在运行的同名进程，然后重新构建、替换 `/Applications/<AppName>.app`，并通过 LaunchAgent 从 `/Applications` 启动。脚本也会清理旧的 `~/Applications/<AppName>.app`，避免运行到用户目录或 `build/` 目录里的旧产物。

卸载开发安装：

```bash
./uninstall.sh doubao
./uninstall.sh wetype
```

### 微信输入法设置

使用微信输入法版本时，请先在微信输入法设置中打开：

```text
快捷键 -> 切换状态 -> 使用 shift 切换中英文
```

![微信输入法快捷键设置](docs/images/wetype-shift-setting.jpg)

## 系统要求

- macOS 12.0 Monterey 或更高版本
- 支持 Intel Mac 和 Apple Silicon Mac

## 工作原理

如果你想了解状态校准的具体策略、为什么这样设计、以及对豆包内部状态的调研结论，可以阅读 [AGENTS.md](AGENTS.md)。

## 反馈与问题

如果遇到状态不准、权限异常、安装失败或其他问题，请在 [GitHub Issues](https://github.com/jianzhoujz/input-indicator/issues) 提交反馈。

## FAQ

### 在哪里下载 Mac 版豆包输入法？

官网还没有，但是网上有泄露的内测版，大家可以自行搜索下载，注意鉴别。

![豆包输入法 Mac 内测版](docs/images/C9AE6EBE-3BC0-4EF8-9E7C-E0DBB2ED6576.png)
