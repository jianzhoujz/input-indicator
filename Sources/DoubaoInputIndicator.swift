import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation

private enum DisplayMode {
    case chinese
    case english
    case unknown

    var title: String {
        switch self {
        case .chinese:
            return "🇨🇳"
        case .english:
            return "🇺🇸"
        case .unknown:
            return "?"
        }
    }

    var detail: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "英文"
        case .unknown:
            return "未知"
        }
    }
}

private struct AppConfig {
    let appName: String
    let displayName: String
    let targetInputMethodBundleID: String
    let launchAgentID: String
    let modeStateKey: String
    let logFileName: String
}

private let gitHubRepository = "jianzhoujz/input-indicator"
private let latestReleaseURL = URL(string: "https://github.com/\(gitHubRepository)/releases/latest")!

private struct GitHubRelease {
    let tagName: String
    let htmlURL: URL
}

private struct VersionNumber: Comparable {
    let parts: [Int]

    init(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let core = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        parts = core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

#if WETYPE
private let appConfig = AppConfig(
    appName: "WeTypeInputIndicator",
    displayName: "微信输入法指示器",
    targetInputMethodBundleID: "com.tencent.inputmethod.wetype",
    launchAgentID: "local.wetype-input-indicator",
    modeStateKey: "wetypeModeChinese",
    logFileName: "WeTypeInputIndicator.log"
)
#else
private let appConfig = AppConfig(
    appName: "DoubaoInputIndicator",
    displayName: "豆包输入法指示器",
    targetInputMethodBundleID: "com.bytedance.inputmethod.doubaoime",
    launchAgentID: "local.doubao-input-indicator",
    modeStateKey: "doubaoModeChinese",
    logFileName: "DoubaoInputIndicator.log"
)
#endif

private final class InputSourceReader {
    struct Source {
        let id: String
        let name: String
        let bundleID: String
        let inputModeID: String
    }

    static func current() -> Source {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return Source(id: "", name: "", bundleID: "", inputModeID: "")
        }

        return Source(
            id: string(source, kTISPropertyInputSourceID),
            name: string(source, kTISPropertyLocalizedName),
            bundleID: string(source, kTISPropertyBundleID),
            inputModeID: string(source, kTISPropertyInputModeID)
        )
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return ""
        }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String ?? ""
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let menu = NSMenu()
    private let maximumStandaloneShiftTapDuration: CFAbsoluteTime = 1.0

    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var globalFlagsMonitor: Any?

    private var currentSource = InputSourceReader.Source(id: "", name: "", bundleID: "", inputModeID: "")
    private var hasRefreshedInputSource = false
    private var targetModeChinese = UserDefaults.standard.object(forKey: appConfig.modeStateKey) as? Bool ?? true
    private var targetModeKnown = UserDefaults.standard.object(forKey: appConfig.modeStateKey) is Bool
    private var listenAccessGranted = false
    private var observedInputEvent = false
    private var eventTapActive = false
    private var updateCheckInProgress = false

    private var shiftDownAt: CFAbsoluteTime?
    private var shiftDownKeyCode: Int64?
    private var shiftDownSourceID = ""
    private var shiftDownBundleID = ""
    private var shiftDownWasTarget = false
    private var shiftHadOtherKey = false
    private var shiftSourceChanged = false
    private var activeShiftKeys = Set<Int64>()
    private var ignoreEventsUntil = CFAbsoluteTimeGetCurrent() + 1.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ignoreEventsUntil = CFAbsoluteTimeGetCurrent() + 1.0
        log("launch app=\(Bundle.main.bundlePath)")

        if let button = statusItem.button {
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            button.alignment = .center
        }
        menu.delegate = self
        statusItem.menu = menu

        rebuildMenu()
        refreshInputSource()
        requestListenAccessIfNeeded()
        installEventTap()
        installGlobalMonitor()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshInputSource()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventTap()
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        globalFlagsMonitor = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshListenAccessStatus()
        rebuildMenu()
    }

    private func requestListenAccessIfNeeded() {
        refreshListenAccessStatus(requestIfNeeded: true)
    }

    private func refreshListenAccessStatus(requestIfNeeded: Bool = false) {
        let wasUsable = inputMonitoringUsable

        if #available(macOS 10.15, *) {
            listenAccessGranted = CGPreflightListenEventAccess()
            if requestIfNeeded && !listenAccessGranted {
                listenAccessGranted = CGRequestListenEventAccess()
            }
        } else {
            listenAccessGranted = true
        }
        log("listen access granted=\(listenAccessGranted)")

        if wasUsable != inputMonitoringUsable {
            updateTitle()
            rebuildMenu()
        }
    }

    private func installEventTap() {
        removeEventTap()

        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                delegate.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else {
            eventTapActive = false
            log("event tap create failed")
            rebuildMenu()
            updateTitle()
            return
        }

        eventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = eventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        eventTapActive = true
        log("event tap active")
        rebuildMenu()
        updateTitle()
    }

    private func removeEventTap() {
        if let source = eventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventRunLoopSource = nil
        eventTap = nil
        eventTapActive = false
    }

    private func installGlobalMonitor() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.handle(event: event)
        }

        if globalFlagsMonitor == nil {
            log("global monitor create failed")
        } else {
            log("global monitor active")
        }
    }

    private func handle(event: NSEvent) {
        let keyCode = event.type == .flagsChanged ? Int64(event.keyCode) : nil
        guard !shouldIgnoreEventDuringStartup(source: "nsevent", keyCode: keyCode) else {
            return
        }
        noteInputEvent()

        switch event.type {
        case .keyDown:
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleEventTapDisabled(type)
            return
        default:
            break
        }

        let keyCode = type == .flagsChanged ? event.getIntegerValueField(.keyboardEventKeycode) : nil
        guard !shouldIgnoreEventDuringStartup(source: "cgevent", keyCode: keyCode) else {
            return
        }
        noteInputEvent()

        switch type {
        case .keyDown:
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func shouldIgnoreEventDuringStartup(source: String, keyCode: Int64?) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < ignoreEventsUntil else {
            return false
        }

        if let keyCode, isShiftKey(keyCode) {
            refreshInputSource()
            if isTargetInputMethodSelected {
                markTargetModeUnknown(reason: "shift event during startup ignore window from \(source)")
            }
        }

        return true
    }

    private func handleEventTapDisabled(_ type: CGEventType) {
        eventTapActive = false
        resetShiftTracking()
        refreshInputSource()
        log("event tap disabled reason=\(type)")

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            eventTapActive = true
            log("event tap re-enabled reason=\(type)")
        }

        updateTitle()
        rebuildMenu()
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard isShiftKey(keyCode) else {
            return
        }

        handleShiftKeyChange(source: "cgevent", keyCode: keyCode)
    }

    private func isShiftKey(_ keyCode: Int64) -> Bool {
        keyCode == 56 || keyCode == 60
    }

    private func refreshInputSource() {
        let next = InputSourceReader.current()
        let wasInitialized = hasRefreshedInputSource
        let wasTarget = isTargetInputMethod(currentSource)
        let nextIsTarget = isTargetInputMethod(next)
        let changed = next.id != currentSource.id || next.inputModeID != currentSource.inputModeID || next.bundleID != currentSource.bundleID
        hasRefreshedInputSource = true
        currentSource = next

        if changed {
            log("source changed id=\(currentSource.id) name=\(currentSource.name) bundle=\(currentSource.bundleID) mode=\(currentSource.inputModeID)")
            if shiftDownAt != nil {
                shiftHadOtherKey = true
                shiftSourceChanged = true
                log("shift invalidated reason=source-changed")
            }
            if wasInitialized && !wasTarget && nextIsTarget {
                setTargetModeChinese(reason: "target input source selected")
            }
            updateTitle()
            rebuildMenu()
        } else {
            updateTitle()
        }
    }

    private var isTargetInputMethodSelected: Bool {
        isTargetInputMethod(currentSource)
    }

    private func isTargetInputMethod(_ source: InputSourceReader.Source) -> Bool {
        source.bundleID == appConfig.targetInputMethodBundleID || source.id.hasPrefix(appConfig.targetInputMethodBundleID)
    }

    private var inputMonitoringUsable: Bool {
        listenAccessGranted || observedInputEvent
    }

    private var needsInputMonitoringPermission: Bool {
        !inputMonitoringUsable
    }

    private var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(appConfig.launchAgentID).plist")
    }

    private var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var displayMode: DisplayMode {
        if isTargetInputMethodSelected {
            guard targetModeKnown else {
                return .unknown
            }
            return targetModeChinese ? .chinese : .english
        }

        let id = currentSource.id.lowercased()
        let mode = currentSource.inputModeID.lowercased()
        let name = currentSource.name.lowercased()

        if id.contains("keylayout") || id.contains("abc") || id.contains("roman") || name.contains("abc") || name.contains("u.s.") {
            return .english
        }

        if id.contains("pinyin") || id.contains("scim") || id.contains("tcim") || id.contains("chinese") || mode.contains("pinyin") {
            return .chinese
        }

        return .unknown
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        guard isShiftKey(keyCode) else {
            return
        }

        handleShiftKeyChange(source: "nsevent", keyCode: keyCode)
    }

    private func handleShiftKeyChange(source: String, keyCode: Int64) {
        let isDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))

        if isDown {
            if activeShiftKeys.isEmpty {
                refreshInputSource()
                shiftDownAt = CFAbsoluteTimeGetCurrent()
                shiftDownKeyCode = keyCode
                shiftDownSourceID = currentSource.id
                shiftDownBundleID = currentSource.bundleID
                shiftDownWasTarget = isTargetInputMethodSelected
                shiftHadOtherKey = false
                shiftSourceChanged = false
                log("shift down source=\(source) key=\(keyCode) current=\(currentSource.id)")
            }
            activeShiftKeys.insert(keyCode)
            return
        }

        guard activeShiftKeys.contains(keyCode) else {
            return
        }

        activeShiftKeys.remove(keyCode)
        log("shift up source=\(source) key=\(keyCode) remaining=\(activeShiftKeys.count)")

        if activeShiftKeys.isEmpty {
            finishShiftTap(source: source)
        }
    }

    private func finishShiftTap(source: String) {
        guard let startedAt = shiftDownAt else {
            return
        }

        defer {
            shiftDownAt = nil
            shiftDownKeyCode = nil
            shiftDownSourceID = ""
            shiftDownBundleID = ""
            shiftDownWasTarget = false
            shiftHadOtherKey = false
            shiftSourceChanged = false
            activeShiftKeys.removeAll()
        }

        guard !shiftHadOtherKey else {
            log("shift ignored source=\(source) reason=combined")
            if shiftSourceChanged && shiftDownWasTarget {
                markTargetModeUnknown(reason: "input source changed while shift was held")
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let duration = now - startedAt
        guard duration <= maximumStandaloneShiftTapDuration else {
            log("shift ignored source=\(source) reason=long duration=\(duration)")
            if shiftDownWasTarget {
                markTargetModeUnknown(reason: "standalone shift duration was too long")
            }
            return
        }

        refreshInputSource()

        guard shiftDownWasTarget else {
            log("shift ignored source=\(source) reason=started-not-target start=\(shiftDownSourceID) current=\(currentSource.id)")
            return
        }

        guard isTargetInputMethodSelected else {
            log("shift ignored source=\(source) reason=ended-not-target start=\(shiftDownSourceID) current=\(currentSource.id)")
            markTargetModeUnknown(reason: "target input source changed during shift tap")
            return
        }

        guard currentSource.id == shiftDownSourceID && currentSource.bundleID == shiftDownBundleID else {
            log("shift ignored source=\(source) reason=source-changed start=\(shiftDownSourceID) current=\(currentSource.id)")
            markTargetModeUnknown(reason: "input source changed during shift tap")
            return
        }

        guard targetModeKnown else {
            log("shift observed source=\(source) reason=unknown-mode-needs-calibration")
            updateTitle()
            rebuildMenu()
            return
        }

        targetModeChinese.toggle()
        UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
        log("shift toggled source=\(source) mode=\(displayMode.detail)")
        updateTitle()
        rebuildMenu()
    }

    private func markTargetModeUnknown(reason: String) {
        let hadSavedState = UserDefaults.standard.object(forKey: appConfig.modeStateKey) != nil
        guard targetModeKnown || hadSavedState else {
            return
        }

        targetModeKnown = false
        UserDefaults.standard.removeObject(forKey: appConfig.modeStateKey)
        log("mode marked unknown reason=\(reason)")
        updateTitle()
        rebuildMenu()
    }

    private func setTargetModeChinese(reason: String) {
        targetModeChinese = true
        targetModeKnown = true
        UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
        log("mode set mode=中文 reason=\(reason)")
    }

    private func resetShiftTracking() {
        shiftDownAt = nil
        shiftDownKeyCode = nil
        shiftDownSourceID = ""
        shiftDownBundleID = ""
        shiftDownWasTarget = false
        shiftHadOtherKey = false
        shiftSourceChanged = false
        activeShiftKeys.removeAll()
    }

    private func updateTitle() {
        let title = needsInputMonitoringPermission ? "⚠️" : displayMode.title

        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        let sourceName = currentSource.name.isEmpty ? currentSource.id : currentSource.name
        if needsInputMonitoringPermission {
            return "需要开启输入监控权限，Shift 同步才能工作。"
        }
        if isTargetInputMethodSelected && !targetModeKnown {
            return "\(sourceName): 需要校准中英文状态"
        }
        return "\(sourceName): \(displayMode.detail)"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let sourceName = currentSource.name.isEmpty ? currentSource.id : currentSource.name
        if needsInputMonitoringPermission {
            let permission = NSMenuItem(title: "⚠️ 输入监控权限未完成", action: nil, keyEquivalent: "")
            permission.isEnabled = false
            menu.addItem(permission)

            let openPermission = NSMenuItem(title: "打开输入监控授权...", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
            openPermission.target = self
            menu.addItem(openPermission)

            let retry = NSMenuItem(title: "重新检查权限", action: #selector(retryEventTap), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)

            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: "\(sourceName): \(displayMode.detail)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if isTargetInputMethodSelected && !targetModeKnown {
            let calibration = NSMenuItem(title: "状态需要校准", action: nil, keyEquivalent: "")
            calibration.isEnabled = false
            menu.addItem(calibration)
        }

        #if WETYPE
        let wetypeShiftSetting = NSMenuItem(title: "微信输入法需开启「使用 shift 切换中英文」", action: nil, keyEquivalent: "")
        wetypeShiftSetting.isEnabled = false
        menu.addItem(wetypeShiftSetting)
        #endif

        if isTargetInputMethodSelected {
            let listener = NSMenuItem(
                title: inputMonitoringUsable && eventTapActive ? "Shift 监听：已启用" : "Shift 监听：等待授权",
                action: nil,
                keyEquivalent: ""
            )
            listener.isEnabled = false
            menu.addItem(listener)

            menu.addItem(.separator())
            let calibrateChinese = NSMenuItem(title: "校准为中文", action: #selector(calibrateChinese), keyEquivalent: "")
            calibrateChinese.target = self
            menu.addItem(calibrateChinese)

            let calibrateEnglish = NSMenuItem(title: "校准为英文", action: #selector(calibrateEnglish), keyEquivalent: "")
            calibrateEnglish.target = self
            menu.addItem(calibrateEnglish)
        }

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let version = NSMenuItem(title: "版本 \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let updateTitle = updateCheckInProgress ? "正在检查更新..." : "检查更新..."
        let update = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = !updateCheckInProgress
        menu.addItem(update)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func calibrateChinese() {
        setTargetModeChinese(reason: "manual calibration")
        updateTitle()
        rebuildMenu()
    }

    @objc private func calibrateEnglish() {
        targetModeChinese = false
        targetModeKnown = true
        UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
        log("mode calibrated mode=英文")
        updateTitle()
        rebuildMenu()
    }

    @objc private func retryEventTap() {
        requestListenAccessIfNeeded()
        installEventTap()
        updateTitle()
        rebuildMenu()
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAtLoginEnabled {
            disableLaunchAtLogin()
        } else {
            enableLaunchAtLogin()
        }
        rebuildMenu()
    }

    @objc private func checkForUpdates() {
        guard !updateCheckInProgress else {
            return
        }

        updateCheckInProgress = true
        rebuildMenu()
        log("checking updates url=\(latestReleaseURL.absoluteString)")

        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "HEAD"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("\(appConfig.appName)/\(appVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                self?.finishUpdateCheck(response: response, error: error)
            }
        }.resume()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func finishUpdateCheck(response: URLResponse?, error: Error?) {
        updateCheckInProgress = false
        rebuildMenu()

        if let error {
            log("update check failed error=\(error.localizedDescription)")
            showMessage(title: "检查更新失败", message: error.localizedDescription)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            log("update check failed reason=missing-http-response")
            showMessage(title: "检查更新失败", message: "没有收到 GitHub 的有效响应。")
            return
        }

        if httpResponse.statusCode == 404 {
            log("update check no latest release")
            showMessage(title: "暂无可用更新", message: "GitHub 上还没有可用的正式 Release。")
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            log("update check failed status=\(httpResponse.statusCode)")
            showMessage(title: "检查更新失败", message: "GitHub 返回 HTTP \(httpResponse.statusCode)。")
            return
        }

        guard let release = latestRelease(from: httpResponse) else {
            log("update check failed reason=missing-release-tag finalURL=\(httpResponse.url?.absoluteString ?? "")")
            showMessage(title: "检查更新失败", message: "无法识别 GitHub 最新 Release 版本。")
            return
        }

        log("latest release tag=\(release.tagName) current=\(appVersion)")

        if VersionNumber(appVersion) < VersionNumber(release.tagName) {
            showUpdateAvailable(release)
        } else {
            showMessage(title: "已是最新版本", message: "\(appConfig.displayName) 当前版本为 \(appVersion)。")
        }
    }

    private func latestRelease(from response: HTTPURLResponse) -> GitHubRelease? {
        guard let finalURL = response.url else {
            return nil
        }

        let pathComponents = finalURL.pathComponents
        guard let tagIndex = pathComponents.firstIndex(of: "tag"),
              tagIndex + 1 < pathComponents.count else {
            return nil
        }

        let tagName = pathComponents[tagIndex + 1].removingPercentEncoding ?? pathComponents[tagIndex + 1]
        guard !tagName.isEmpty else {
            return nil
        }

        return GitHubRelease(tagName: tagName, htmlURL: finalURL)
    }

    private func showUpdateAvailable(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = "\(appConfig.displayName) 当前版本为 \(appVersion)。是否打开 GitHub Releases 下载更新？"
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func noteInputEvent() {
        guard !observedInputEvent else {
            return
        }

        observedInputEvent = true
        log("input monitoring observed event")
        updateTitle()
        rebuildMenu()
    }

    private func enableLaunchAtLogin() {
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let appPath = preferredInstalledAppPath()
            try launchAgentPlist(appPath: appPath).write(to: launchAgentURL, atomically: true, encoding: .utf8)

            let domain = "gui/\(getuid())"
            _ = runLaunchctl(["bootout", domain, launchAgentURL.path])
            _ = runLaunchctl(["bootstrap", domain, launchAgentURL.path])
            _ = runLaunchctl(["enable", "\(domain)/\(appConfig.launchAgentID)"])
            log("launch at login enabled app=\(appPath)")
        } catch {
            log("launch at login enable failed error=\(error.localizedDescription)")
        }
    }

    private func disableLaunchAtLogin() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, launchAgentURL.path])

        do {
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            log("launch at login disabled")
        } catch {
            log("launch at login disable failed error=\(error.localizedDescription)")
        }
    }

    private func preferredInstalledAppPath() -> String {
        let installed = "\(NSHomeDirectory())/Applications/\(appConfig.appName).app"
        if FileManager.default.fileExists(atPath: installed) {
            return installed
        }
        return Bundle.main.bundlePath
    }

    private func launchAgentPlist(appPath: String) -> String {
        let escapedAppPath = xmlEscaped(appPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(appConfig.launchAgentID)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-g</string>
            <string>\(escapedAppPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <false/>
        </dict>
        </plist>
        """
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            log("launchctl failed args=\(arguments.joined(separator: " ")) error=\(error.localizedDescription)")
            return -1
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/\(appConfig.logFileName)")

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
