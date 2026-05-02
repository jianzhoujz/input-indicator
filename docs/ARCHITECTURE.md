# 架构与状态推断策略

本文记录指示器如何推断豆包 / 微信输入法的内部「中文 / 英文」状态，以
及为什么采用现在的策略。给后续贡献者和复现状态问题时定位用。

## 总体原则：正向证据策略

macOS 没有官方 API 能读到这两个输入法内部的中英文子状态（详见下文「调
研：豆包内部状态可观察面」一节）。所以指示器只能**观察**多个间接信号，
然后按以下原则合并：

> 永远只在拿到「中文」的正向证据时切到中文，只在拿到「英文」的正向证
> 据时切到英文；任何信号的*缺席*都不允许推断为另一种状态。
>
> 不确定时显示 🫥（未知），让用户手动校准或等待权威信号到来。
>
> 宁可显示「未知」，也不要显示错的。

这条原则是 v1.2.x 系列的核心修订动机。早期版本会从「连续敲了 ≥2 个字
母却没看到候选窗」推断为英文模式，是「莫名其妙跳到🇺🇸」误判的主要来源。

## 三层校准信号

按可靠度从高到低排列。每一层都只能**确认**一种模式，不能从信号缺席反
推另一种模式。

### 1. Accessibility 模式指示器（最可靠，窄域读取）

豆包 / 微信在按 Shift 切换模式时会弹一个约 25×28 pt 的小提示窗，里面
画一个「中」或「英」字符。指示器的读取流程：

1. `pollCandidateWindow` 每 0.3s 用 `CGWindowListCopyWindowInfo`
   扫描 IME 进程的高 layer 窗口（layer ≥ 2_147_483_000）
2. 把尺寸落在 15–50 pt 方形范围的窗口认成"指示器候选"，记录其
   `kCGWindowBounds`
3. 与上一轮的 ID 集合做差，新出现的窗口才触发读取（避免重复）
4. 调 `CandidateWindowMonitor.recognizeModeFromIndicatorRect(pid:rect:)`：
   - 用 `AXUIElementCreateApplication(pid)` 拿到 IME 进程根
   - 用 `AXUIElementCopyElementAtPosition` 命中那个矩形中心点上的 AX 元素
   - 只走那个元素的子树，深度 ≤ 3、每层 ≤ 8 个子节点
   - 读 `kAXValueAttribute` / `kAXTitleAttribute` / `kAXDescriptionAttribute`
   - 文本 trim 后**必须严格等于** `中` 或 `英` 才接受

为什么这样写：

- 历史上的实现是扫整个 IME 进程的 AX 树，对所有文本做
  `text.contains("中") || text.contains("英")`。这会被设置面板里的
  「英语词典」「英文标点」等字眼误吃，然后状态错乱
- 命中点 + 浅子树 + 严格单字符匹配三层防线后，可以排除上述几乎所有
  误识别场景

### 2. 候选词窗口可见性（仅作中文正向证据）

候选词面板可见时（高 layer 上的高窗口，或宽 ≥ 100 pt 的单行窗口）→
设为中文。

**反过来不成立**：候选词面板缺席不能推断英文，因为候选词在中文模式下
也常常不显示，例如：

- 焦点在密码框（系统强制旁路 IME）
- 焦点在豆包自己的搜索框 / 设置面板
- 焦点在不实现 IMK 协议的控件（部分终端、某些 Electron / 游戏窗口）
- 用户刚上屏一个词，候选窗短暂消失
- IME 卡顿或网络云候选延迟

### 3. Shift 翻转（最低可靠度，但是唯一的"翻转"信号）

当模式已经为已知值，并且观察到一次干净的独立 Shift 按下与抬起（中间
没有别的键盘 / 鼠标活动，且持续时间在合理范围内），按下 → 抬起的输入
源没变，则把当前模式翻转。

实现细节：

- 同时挂 `CGEvent.tapCreate(..., .listenOnly, ...)` 和
  `NSEvent.addGlobalMonitorForEvents(...)`，前者优先后者作降级，避免
  双重计数
- 1 秒启动忽略窗，跳过启动瞬间的余留 modifier 状态
- Shift 翻转后立即调度 0.15s / 0.4s / 0.7s 三次"验证 burst"重新跑
  `pollCandidateWindow`，捕获 IME 在模式切换瞬间弹出的指示器窗
- 翻转后 `autoCalibrationCooldown` 秒内禁用候选窗 polling 校准，避免
  残留候选窗瞬时把状态又改回去

### 何时进入「未知」状态

以下情况指示器会清空已知状态、显示 🫥：

- 启动忽略窗内出现 Shift（可能漏掉一次切换）
- 一次独立 Shift 按下持续过长（用户可能挂着 Shift 改主意了）
- Shift 按下到抬起之间输入源发生变化
- 从其它输入法切回目标 IME（多数 IME 重新激活时会重置内部模式）

进入未知后，下一次拿到任意一种正向证据（候选窗 / AX 指示器读取 /
手动校准）就会重新锁定状态。

## 调研：豆包内部状态可观察面

为评估「能不能拿到更权威的状态信号」，对本机豆包 IMK bundle 做过端到
端排查。结论：

### 磁盘层面：没有反映中英文状态的文件

| 路径 | 内容 | 用得上吗 |
|---|---|---|
| `~/Library/Preferences/com.bytedance.inputmethod.doubaoime.plist` | 仅 `oime.device_id` / `oime.vendor_id` | ❌ |
| `~/Library/Preferences/com.bytedance.inputmethod.doubaoime.settings.plist` | 仅 `oime.device_id` | ❌ |
| `~/Library/Application Support/DoubaoIme/MMKV/com.apple.xpc.activity` | 16K 全 0，XPC 调度活动占位 | ❌ |
| `~/Library/Application Support/DoubaoIme/EngineUserDict/*.dat` | 用户词库二进制 | ❌ |
| `~/Library/Application Support/DoubaoIme/Crash/settings.dat` | 40 字节 Crash 上报句柄 | ❌ |
| `~/Library/Caches/com.bytedance.inputmethod.doubaoime/Cache.db` | NSURLCache | ❌ |

中英文状态完全不写盘——逻辑上也合理，按 Shift 是高频操作，写盘会损耗
SSD 且无必要。

### 日志：有但加密

豆包用字节自家的 **alog** 框架写日志到
`~/Library/Application Support/DoubaoIme/Log/alog/log/*.alog.hot`，文
件头 magic `a1 09 00 00 ...` + AES 加密负载。GitHub 上 `bytedance/alog`
仅是写库，不公开解密工具。即便能解密，这也只是事后日志，不能用来实时
查询状态。

### 二进制：状态字段确实存在，但拿不到

`otool -ov /Library/Input\ Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme`
反汇编结果显示：

- Swift 类 `DoubaoIme.InputState`（混淆名 `_TtC9DoubaoIme10InputState`）
- 单例 `sharedInstance`
- 成员变量 `enMode`：Bool，偏移 +16，`true` = 英文，`false` = 中文
- 相关方法 `switchToEnglish:`、`selectInputMode:`
- 配置项 `useShiftToSwitchBetweenChineseAndEnglish`

但豆包**没有**暴露任何 IPC 把这个状态广播出去。`strings` 全扫：

- 无 `MachServiceName`
- 无 `NSXPCConnection`
- 无任何 mode/state 相关的 distributed notification 名（唯一的
  `com.bytedance.persistence` 是它们的持久化框架内部用的，跟模式无关）

跨进程读 `enMode` 的内存需要 `task_for_pid()`，这要 root + 关 SIP，不
现实；进程注入也行不通，IMK bundle 由 macOS 加载并强制校验代码签名。

**结论**：没有任何合规的外部读取手段能拿到豆包的 `enMode`。所有信号都
只能是观察 IMK 协议的副作用（候选窗、指示器小窗、客户端文本框的
marked text）。当前实现用了前两个。

## 后续可能的增强：D2（Marked Text 观察）

未来可以再加一层："监听焦点应用文本框的 `kAXSelectedTextChangedNotification`，
如果用户敲 alpha 键后焦点元素出现 marked text → 认定中文模式；如果
value 直接增长且 marked text 始终为空 → 认定英文模式。"

这个信号源于 IMK 协议层面的强制约定（任何 IMK 输入法在合成中文时都必
须把 marked text 写入 client text input），跨输入法实现一致，比观察
豆包自己的窗口更稳定。

代价：

- 需要管理 `AXObserver` 生命周期，跟随焦点元素切换 attach / detach
- 部分应用的 AX text field 不暴露 marked range：Electron（VSCode、
  Slack、Discord）、Chrome 的 web 输入框、终端类（Terminal、iTerm、
  Alacritty）。这些场景需要降级回上面三层

引入前应先做最小 PoC 验证常用 app 的 marked text 信号是否稳定，再决
定是否全量上。
