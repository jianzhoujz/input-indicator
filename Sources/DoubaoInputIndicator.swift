import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation

private enum DisplayMode {
    case chinese
    case english
    case unknown
    case nonTarget

    var title: String {
        switch self {
        case .chinese:
            return "🇨🇳"
        case .english:
            return "🇺🇸"
        case .unknown:
            return "🫥"
        case .nonTarget:
            return "🤐"
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
        case .nonTarget:
            return "非目标输入法"
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
private let gitHubURL = URL(string: "https://github.com/jianzhoujz/input-indicator")!
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

private final class CandidateWindowMonitor {

    /// IME candidate panels and overlay popups typically sit at very high
    /// window layers (near INT32_MAX ≈ 2_147_483_647).  Doubao uses layer
    /// 2_147_483_628 for its candidate panel; WeType uses both 2_147_483_628
    /// and 2_147_483_629.  We treat any layer above this threshold as a
    /// potential candidate overlay.
    private static let candidateLayerThreshold = 2_147_483_000

    /// Minimum window height (in points) to be considered a candidate panel.
    /// Full multi-row candidate panels are typically 50+ pt tall.
    private static let minimumCandidateWindowHeight = 40
    /// Doubao sometimes shows a single-row candidate panel at ~32 pt height
    /// with a width of 400+ pt.  We use a combined height+width check to
    /// distinguish these from tiny persistent toolbar/tooltip windows.
    private static let minimumSingleRowCandidateWindowHeight = 24
    private static let minimumSingleRowCandidateWindowWidth = 100

    /// Find the PID of a running input method process by bundle ID.
    static func findIMEProcessID(_ bundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }?.processIdentifier
    }

    /// Bounds of an indicator-sized IME window in screen coordinates.
    struct IndicatorWindow {
        let wid: CGWindowID
        let frame: CGRect
    }

    /// Snapshot of on-screen IME windows relevant to mode detection.
    struct WindowSnapshot {
        /// Whether a tall candidate panel is visible (Chinese input active).
        let candidateVisible: Bool
        /// Window IDs of small indicator-sized windows (the "中"/"英" tooltip).
        let indicatorWIDs: Set<CGWindowID>
        /// Frames of those indicator windows, keyed by window ID. Used to
        /// scope Accessibility text reads to the indicator's screen rect
        /// instead of the entire IME process AX tree.
        let indicatorFrames: [CGWindowID: CGRect]
    }

    /// Scans on-screen windows owned by the target IME and returns a snapshot
    /// containing both candidate panel visibility and indicator window IDs.
    static func snapshot(bundleID: String,
                         indicatorMinSize: Int,
                         indicatorMaxSize: Int,
                         logHandler: ((String) -> Void)? = nil) -> WindowSnapshot {
        guard let pid = cachedFindIMEProcessID(bundleID) else {
            return WindowSnapshot(candidateVisible: false, indicatorWIDs: [], indicatorFrames: [:])
        }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return WindowSnapshot(candidateVisible: false, indicatorWIDs: [], indicatorFrames: [:])
        }

        var candidateVisible = false
        var indicatorWIDs = Set<CGWindowID>()
        var indicatorFrames = [CGWindowID: CGRect]()
        var scannedCount = 0

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= candidateLayerThreshold else {
                continue
            }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Int,
                  let height = bounds["Height"] as? Int else {
                continue
            }

            scannedCount += 1
            logHandler?("window layer=\(layer) w=\(width) h=\(height)")

            if height >= minimumCandidateWindowHeight
                || (height >= minimumSingleRowCandidateWindowHeight
                    && width >= minimumSingleRowCandidateWindowWidth) {
                candidateVisible = true
            }

            if width >= indicatorMinSize && width <= indicatorMaxSize
                && height >= indicatorMinSize && height <= indicatorMaxSize {
                let wid = info[kCGWindowNumber as String] as? CGWindowID ?? 0
                if wid != 0 {
                    indicatorWIDs.insert(wid)
                    let x = (bounds["X"] as? Double) ?? Double(bounds["X"] as? Int ?? 0)
                    let y = (bounds["Y"] as? Double) ?? Double(bounds["Y"] as? Int ?? 0)
                    indicatorFrames[wid] = CGRect(x: x, y: y, width: Double(width), height: Double(height))
                }
            }
        }

        if scannedCount == 0 {
            logHandler?("snapshot: no high-layer windows found for pid=\(pid)")
        }

        return WindowSnapshot(candidateVisible: candidateVisible,
                              indicatorWIDs: indicatorWIDs,
                              indicatorFrames: indicatorFrames)
    }

    /// Returns `true` when the target IME currently has an on-screen candidate
    /// window, indicating Chinese input mode is active.
    static func isCandidateWindowVisible(bundleID: String) -> Bool {
        snapshot(bundleID: bundleID, indicatorMinSize: 0, indicatorMaxSize: 0).candidateVisible
    }

    // MARK: - PID cache

    private static var cachedPID: pid_t?
    private static var cachedPIDBundleID: String = ""
    private static var cachedPIDAt: CFAbsoluteTime = 0
    private static let pidCacheTTL: CFAbsoluteTime = 5.0

    /// Find the IME process ID, using a short-lived cache to avoid repeated
    /// linear scans of `runningApplications`.
    static func cachedFindIMEProcessID(_ bundleID: String) -> pid_t? {
        let now = CFAbsoluteTimeGetCurrent()
        if bundleID == cachedPIDBundleID,
           let pid = cachedPID,
           now - cachedPIDAt < pidCacheTTL {
            return pid
        }
        let pid = findIMEProcessID(bundleID)
        cachedPID = pid
        cachedPIDBundleID = bundleID
        cachedPIDAt = now
        return pid
    }

    // MARK: - Mode indicator reading via Accessibility API

    /// Recognized mode from the IME's mode-indicator tooltip.
    enum RecognizedMode {
        case chinese
        case english
        case unrecognized
    }

    /// Use the Accessibility API to read text content scoped to a specific
    /// indicator window's screen rectangle.  This avoids walking the IME
    /// process's entire AX tree (which contains settings panels, dictionary
    /// windows, toolbars, etc., any of which may legitimately contain "中" or
    /// "英" characters and cause false-positive mode flips).
    ///
    /// We hit-test the centre of the rect with `AXUIElementCopyElementAtPosition`,
    /// then walk only that element's small subtree (depth 3, child cap 8) and
    /// require an exact single-character match — `中` means Chinese, `英`
    /// means English.  Anything else is `.unrecognized` and the caller leaves
    /// the tracked mode untouched.
    static func recognizeModeFromIndicatorRect(pid: pid_t, rect: CGRect) -> (RecognizedMode, String) {
        let app = AXUIElementCreateApplication(pid)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        var hit: AXUIElement?
        var hitRef: AXUIElement?
        if AXUIElementCopyElementAtPosition(app, Float(centre.x), Float(centre.y), &hitRef) == .success {
            hit = hitRef
        }

        var texts = [String]()
        if let element = hit {
            collectTexts(from: element, into: &texts, depth: 0, maxDepth: 3, childCap: 8)
        }

        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "中" { return (.chinese, trimmed) }
            if trimmed == "英" { return (.english, trimmed) }
        }

        return (.unrecognized, texts.joined(separator: "|"))
    }

    /// Recursively collect text content (title, value, description) from an
    /// AXUIElement tree, capped by depth and per-node child count to keep the
    /// scan bounded when reading a small indicator subtree.
    private static func collectTexts(from element: AXUIElement,
                                     into texts: inout [String],
                                     depth: Int,
                                     maxDepth: Int,
                                     childCap: Int) {
        guard depth <= maxDepth else { return }

        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as [String] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let str = ref as? String, !str.isEmpty {
                texts.append(str)
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children.prefix(childCap) {
            collectTexts(from: child, into: &texts, depth: depth + 1, maxDepth: maxDepth, childCap: childCap)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let menu = NSMenu()
    private let maximumStandaloneShiftTapDuration: CFAbsoluteTime = 1.0
    private let verboseEventLogging = UserDefaults.standard.bool(forKey: "verboseEventLogging")
    private let logDateFormatter = ISO8601DateFormatter()

    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var globalFlagsMonitor: Any?
    private var menuIsOpen = false
    private var lastRenderedTitle = ""
    private var lastRenderedTooltip = ""
    private var logDirectoryCreated = false

    private var currentSource = InputSourceReader.Source(id: "", name: "", bundleID: "", inputModeID: "")
    // Always start in unknown mode on launch.  The persisted state may be
    // stale because the user could have toggled the IME while this app was
    // not running.  Auto-calibration will correct it quickly once the user
    // starts typing or a candidate window appears.
    private var targetModeChinese = true
    private var targetModeKnown = false
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

    // --- Candidate window auto-calibration ---
    /// Timer used to defer the candidate window check after a key press.
    private var candidateCheckTimer: Timer?
    /// How many alphabetic key-downs we have seen since the last candidate
    /// window check while the target IME is active.
    private var pendingAlphaKeyCount = 0
    /// Timestamp of the last successful auto-calibration to throttle checks.
    private var lastAutoCalibrationAt: CFAbsoluteTime = 0
    /// Minimum interval between auto-calibrations (seconds).
    private let autoCalibrationCooldown: CFAbsoluteTime = 2.0

    // --- Shift tracking improvements ---
    /// Tracks the previous input source so we can detect switching back to the
    /// target IME from another source.
    private var previousSourceBundleID = ""
    /// Minimum gap between consecutive shift toggles (seconds). Doubao's
    /// internal `ShiftKeyEventCoalescer` debounces rapid repeats; we mirror
    /// that here to stay in sync.
    private let minimumShiftToggleGap: CFAbsoluteTime = 0.35
    /// Timestamp of the last accepted shift toggle.
    private var lastShiftToggleAt: CFAbsoluteTime = 0
    private let maximumLogFileSize: UInt64 = 1_048_576
    /// Timestamp of the last key activity (alpha key or shift) for adaptive
    /// poll throttling.
    private var lastKeyActivityAt: CFAbsoluteTime = 0

    private var logDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs", isDirectory: true)
    }

    private var logFileURL: URL {
        logDirectoryURL.appendingPathComponent(appConfig.logFileName)
    }

    private var rotatedLogFileURL: URL {
        logFileURL.appendingPathExtension("old")
    }

    // --- Mode indicator window detection ---
    /// Window IDs of small (mode indicator) windows seen in the previous poll.
    /// When new IDs appear, it signals a mode toggle by the IME.
    private var knownIndicatorWIDs = Set<CGWindowID>()
    /// Size constraints for the mode indicator window ("中"/"英" tooltip).
    /// Doubao shows a ~25×28 pt black tooltip on each mode switch.
    private static let indicatorMaxSize = 50
    private static let indicatorMinSize = 15

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
        requestAccessibilityIfNeeded()
        requestListenAccessIfNeeded()
        installEventTap()
        if !eventTapActive || !listenAccessGranted {
            installGlobalMonitor()
        } else {
            log("global monitor skipped reason=event-tap-active-and-authorized")
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshInputSource()
            self?.pollCandidateWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventTap()
        candidateCheckTimer?.invalidate()
        candidateCheckTimer = nil
        removeGlobalMonitor()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshListenAccessStatus()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("accessibility trusted=\(trusted)")
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
        guard globalFlagsMonitor == nil else {
            return
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.handle(event: event)
        }

        if globalFlagsMonitor == nil {
            log("global monitor create failed")
        } else {
            log("global monitor active")
        }
    }

    private func removeGlobalMonitor() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        globalFlagsMonitor = nil
    }

    private func handle(event: NSEvent) {
        let keyCode = event.type == .flagsChanged ? Int64(event.keyCode) : nil
        guard !shouldIgnoreEventDuringStartup(source: "nsevent", keyCode: keyCode) else {
            return
        }

        switch event.type {
        case .keyDown:
            noteInputEvent()
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
            noteAlphaKeyDown(keyCode: Int64(event.keyCode))
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

        switch type {
        case .keyDown:
            noteInputEvent()
            if shiftDownAt != nil {
                shiftHadOtherKey = true
            }
            noteAlphaKeyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
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

    // MARK: - Candidate window auto-calibration

    /// Called every 0.3s from the main timer.  Detects the IME's mode-indicator
    /// tooltip ("中"/"英") and candidate panel to auto-calibrate mode state.
    private func pollCandidateWindow() {
        guard isTargetInputMethodSelected else {
            knownIndicatorWIDs.removeAll()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()

        // Adaptive polling: skip expensive window scan when idle and mode is
        // already known.  Always scan when mode is unknown (needs calibration).
        let idleThreshold: CFAbsoluteTime = 3.0
        if targetModeKnown && (now - lastKeyActivityAt) >= idleThreshold {
            return
        }

        let snap = CandidateWindowMonitor.snapshot(
            bundleID: appConfig.targetInputMethodBundleID,
            indicatorMinSize: Self.indicatorMinSize,
            indicatorMaxSize: Self.indicatorMaxSize,
            logHandler: !targetModeKnown ? { [weak self] msg in self?.logVerbose(msg) } : nil
        )

        // --- Mode indicator window ("中"/"英" tooltip) detection ---
        let newWIDs = snap.indicatorWIDs.subtracting(knownIndicatorWIDs)
        knownIndicatorWIDs = snap.indicatorWIDs

        if !newWIDs.isEmpty {
            // A new indicator window appeared → the IME just changed modes.
            // Read mode text scoped to that window's screen rect (avoids
            // accidentally picking up "中"/"英" characters from unrelated IME
            // UI like settings panels or dictionary windows).
            guard let pid = CandidateWindowMonitor.findIMEProcessID(appConfig.targetInputMethodBundleID) else {
                return
            }

            var recognized = CandidateWindowMonitor.RecognizedMode.unrecognized
            var detail = ""
            for wid in newWIDs {
                guard let rect = snap.indicatorFrames[wid] else { continue }
                let (mode, text) = CandidateWindowMonitor.recognizeModeFromIndicatorRect(pid: pid, rect: rect)
                if mode != .unrecognized {
                    recognized = mode
                    detail = text
                    break
                }
                if !text.isEmpty {
                    detail = text
                }
            }

            switch recognized {
            case .chinese:
                let oldMode = targetModeKnown ? (targetModeChinese ? "中文" : "英文") : "未知"
                if !targetModeKnown || !targetModeChinese {
                    targetModeChinese = true
                    targetModeKnown = true
                    UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
                    log("auto-calibrate mode=中文 old=\(oldMode) trigger=indicator-ax text=\(detail)")
                    updateTitle()
                    rebuildMenuIfOpen()
                } else {
                    log("indicator-ax confirmed mode=中文 text=\(detail)")
                }
                lastAutoCalibrationAt = now
                return
            case .english:
                let oldMode = targetModeKnown ? (targetModeChinese ? "中文" : "英文") : "未知"
                if !targetModeKnown || targetModeChinese {
                    targetModeChinese = false
                    targetModeKnown = true
                    UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
                    log("auto-calibrate mode=英文 old=\(oldMode) trigger=indicator-ax text=\(detail)")
                    updateTitle()
                    rebuildMenuIfOpen()
                } else {
                    log("indicator-ax confirmed mode=英文 text=\(detail)")
                }
                lastAutoCalibrationAt = now
                return
            case .unrecognized:
                log("indicator-ax result=unrecognized detail=\(detail)")
            }
        }

        // --- Candidate window (tall panel) detection ---
        guard now - lastAutoCalibrationAt >= autoCalibrationCooldown else {
            return
        }

        if snap.candidateVisible {
            if !targetModeKnown || !targetModeChinese {
                let oldMode = targetModeKnown ? (targetModeChinese ? "中文" : "英文") : "未知"
                targetModeChinese = true
                targetModeKnown = true
                UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
                lastAutoCalibrationAt = now
                log("auto-calibrate mode=中文 old=\(oldMode) trigger=candidate-window-visible source=poll")
                updateTitle()
                rebuildMenuIfOpen()
            }
        }
    }

    /// Alphabetic key codes on a QWERTY layout (A-Z).
    private static let alphaKeyCodes: Set<Int64> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        31, 32, 34, 35, 37, 38, 40, 45, 46,
    ]

    /// Called on every keyDown to accumulate alphabetic key presses for
    /// candidate window detection.  Both the CGEvent tap and the NSEvent global
    /// monitor fire for the same physical keystroke, so we deduplicate by
    /// ignoring events that arrive within a very short window of each other.
    private var lastAlphaKeyNoteAt: CFAbsoluteTime = 0

    private func noteAlphaKeyDown(keyCode: Int64) {
        // Track key activity for adaptive poll throttling
        lastKeyActivityAt = CFAbsoluteTimeGetCurrent()

        if !isTargetInputMethodSelected {
            // The cached currentSource may be stale (updated every 0.3 s by
            // the timer).  When the user has just switched to the target IME
            // and starts typing immediately, the first keystrokes would
            // otherwise be silently discarded.  Do a one-off live check here
            // so we don't miss those early keys.
            refreshInputSource()
            guard isTargetInputMethodSelected else {
                pendingAlphaKeyCount = 0
                candidateCheckTimer?.invalidate()
                candidateCheckTimer = nil
                return
            }
        }

        guard Self.alphaKeyCodes.contains(keyCode) else {
            return
        }

        // Deduplicate: if we just noted an alpha key within 20 ms, this is
        // almost certainly the same physical keystroke arriving through the
        // other event source.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAlphaKeyNoteAt > 0.02 else {
            return
        }
        lastAlphaKeyNoteAt = now

        pendingAlphaKeyCount += 1

        // Schedule (or reschedule) a deferred check.  We wait a short moment
        // because the candidate window needs time to appear after a keystroke.
        candidateCheckTimer?.invalidate()
        candidateCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.performCandidateWindowCheck()
        }
    }

    /// Checks whether the target IME's candidate window is on-screen and uses
    /// the result to auto-calibrate the tracked Chinese/English mode.
    /// This path is triggered by keyDown events (requires Input Monitoring)
    /// and can additionally detect English mode via the absence of candidates.
    private func performCandidateWindowCheck() {
        candidateCheckTimer = nil

        guard isTargetInputMethodSelected else {
            pendingAlphaKeyCount = 0
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAutoCalibrationAt >= autoCalibrationCooldown else {
            // Don't discard pending key evidence during cooldown.
            // Schedule a deferred check for when cooldown expires.
            let remaining = autoCalibrationCooldown - (now - lastAutoCalibrationAt) + 0.05
            candidateCheckTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                self?.performCandidateWindowCheck()
            }
            return
        }

        let keysTyped = pendingAlphaKeyCount
        pendingAlphaKeyCount = 0

        let visible = CandidateWindowMonitor.snapshot(
            bundleID: appConfig.targetInputMethodBundleID,
            indicatorMinSize: 0,
            indicatorMaxSize: 0
        ).candidateVisible

        if visible {
            // Candidate window is showing → definitely Chinese mode.
            if !targetModeKnown || !targetModeChinese {
                let oldMode = targetModeKnown ? (targetModeChinese ? "中文" : "英文") : "未知"
                targetModeChinese = true
                targetModeKnown = true
                UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
                lastAutoCalibrationAt = now
                log("auto-calibrate mode=中文 old=\(oldMode) trigger=candidate-window-visible source=keydown keys=\(keysTyped)")
                updateTitle()
                rebuildMenuIfOpen()
            }
        } else {
            // Absence of candidate window is NOT a reliable English signal:
            // the user might be typing in a non-IME-aware control, in
            // Doubao's own settings/search field, in a password field, or
            // simply between commits where the panel briefly hides. Trust
            // only positive Chinese evidence; never infer English here.
            log("candidate-check no-candidate keys=\(keysTyped) (no inference)")
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

        // Always install global monitor as fallback after a tap disable event.
        // noteInputEvent() will confirm CGEvent is working again.
        installGlobalMonitor()

        updateTitle()
        rebuildMenu()
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard isShiftKey(keyCode) else {
            return
        }

        let isDown = isSpecificShiftDown(keyCode, rawFlags: event.flags.rawValue)
        handleShiftKeyChange(source: "cgevent", keyCode: keyCode, isDown: isDown)
    }

    private func isShiftKey(_ keyCode: Int64) -> Bool {
        keyCode == 56 || keyCode == 60
    }

    /// Check device-level modifier flags embedded in the event to determine
    /// whether a specific Shift key is pressed.  This is more reliable than
    /// `CGEventSource.keyState` because it reflects the state AT THE TIME of
    /// the event, not the instantaneous state which may have changed if the
    /// key was released before the handler runs.
    private func isSpecificShiftDown(_ keyCode: Int64, rawFlags: UInt64) -> Bool {
        switch keyCode {
        case 56: return (rawFlags & 0x2) != 0   // NX_DEVICELSHIFTKEYMASK
        case 60: return (rawFlags & 0x4) != 0   // NX_DEVICERSHIFTKEYMASK
        default: return false
        }
    }

    private func refreshInputSource() {
        let next = InputSourceReader.current()
        let changed = next.id != currentSource.id || next.inputModeID != currentSource.inputModeID || next.bundleID != currentSource.bundleID

        if changed {
            previousSourceBundleID = currentSource.bundleID
        }

        currentSource = next

        if changed {
            log("source changed id=\(currentSource.id) name=\(currentSource.name) bundle=\(currentSource.bundleID) mode=\(currentSource.inputModeID)")
            if shiftDownAt != nil {
                shiftHadOtherKey = true
                shiftSourceChanged = true
                log("shift invalidated reason=source-changed")
            }

            // --- Improvement: detect re-entry to the target IME ---
            // When the user switches away from the target IME and later
            // switches back, the IME may have reset its internal mode (most
            // Chinese IMEs default to Chinese on re-activation).  Mark the
            // tracked mode as unknown so the candidate-window auto-calibration
            // or manual calibration can correct it.
            if isTargetInputMethodSelected && !previousSourceBundleID.isEmpty && !isTargetInputMethod(InputSourceReader.Source(id: "", name: "", bundleID: previousSourceBundleID, inputModeID: "")) {
                log("target IME re-entered from bundle=\(previousSourceBundleID)")
                // Reset pending alpha keys so the candidate check starts fresh
                pendingAlphaKeyCount = 0
                candidateCheckTimer?.invalidate()
                candidateCheckTimer = nil
                markTargetModeUnknown(reason: "target IME re-entered after switching away")
            }

            updateTitle()
            rebuildMenuIfOpen()
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

    private var appBuildTime: String {
        Bundle.main.object(forInfoDictionaryKey: "BuildTime") as? String ?? "未知"
    }

    private var displayMode: DisplayMode {
        if isTargetInputMethodSelected {
            guard targetModeKnown else {
                return .unknown
            }
            return targetModeChinese ? .chinese : .english
        }

        return .nonTarget
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        guard isShiftKey(keyCode) else {
            return
        }

        let isDown = isSpecificShiftDown(keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
        handleShiftKeyChange(source: "nsevent", keyCode: keyCode, isDown: isDown)
    }

    private func handleShiftKeyChange(source: String, keyCode: Int64, isDown: Bool) {
        // Track key activity for adaptive poll throttling
        lastKeyActivityAt = CFAbsoluteTimeGetCurrent()

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

        // --- Improvement: debounce rapid shift toggles ---
        // When Accessibility-based verification is unavailable, we debounce
        // to stay in sync with Doubao's internal ShiftKeyEventCoalescer.
        // When AX is active, skip the debounce because AX will verify/correct.
        if !cachedAXTrusted {
            let gapSinceLastToggle = now - lastShiftToggleAt
            guard gapSinceLastToggle >= minimumShiftToggleGap else {
                log("shift ignored source=\(source) reason=debounce gap=\(gapSinceLastToggle)")
                return
            }
        }

        guard targetModeKnown else {
            log("shift observed source=\(source) reason=unknown-mode-needs-calibration")
            updateTitle()
            rebuildMenuIfOpen()
            schedulePostShiftVerification()
            return
        }

        targetModeChinese.toggle()
        UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
        lastShiftToggleAt = now
        // Suppress poll-based auto-calibration for a while after a Shift
        // toggle so a lingering candidate window cannot immediately override
        // the mode we just set.
        lastAutoCalibrationAt = now
        log("shift toggled source=\(source) mode=\(displayMode.detail)")
        updateTitle()
        rebuildMenuIfOpen()
        schedulePostShiftVerification()
    }

    /// Timers for the post-Shift verification burst.  Kept so that rapid
    /// Shift taps cancel stale timers instead of accumulating them.
    private var postShiftTimers = [Timer]()

    /// After a Shift toggle, the IME shows a small "中"/"英" indicator window
    /// for about 1 second.  Schedule a quick burst of checks to capture and
    /// OCR it for authoritative calibration.
    private func schedulePostShiftVerification() {
        // Cancel any outstanding burst from a previous Shift tap.
        for t in postShiftTimers { t.invalidate() }
        postShiftTimers.removeAll()

        for delay in [0.15, 0.4, 0.7] {
            let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.pollCandidateWindow()
            }
            postShiftTimers.append(t)
        }
    }

    // MARK: - Accessibility trust cache

    private var _cachedAXTrusted: Bool?
    private var _cachedAXTrustedAt: CFAbsoluteTime = 0

    /// Cached wrapper around `AXIsProcessTrusted()`.  The trust state almost
    /// never changes at runtime, so we re-check at most every 10 seconds.
    private var cachedAXTrusted: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = _cachedAXTrusted, now - _cachedAXTrustedAt < 10.0 {
            return cached
        }
        let value = AXIsProcessTrusted()
        _cachedAXTrusted = value
        _cachedAXTrustedAt = now
        return value
    }

    private func markTargetModeUnknown(reason: String) {
        let hadSavedState = UserDefaults.standard.object(forKey: appConfig.modeStateKey) != nil
        guard targetModeKnown || hadSavedState else {
            return
        }

        targetModeKnown = false
        UserDefaults.standard.removeObject(forKey: appConfig.modeStateKey)
        // Clear auto-calibration cooldown so that candidate-window detection
        // can kick in immediately once the user starts typing.
        lastAutoCalibrationAt = 0
        log("mode marked unknown reason=\(reason)")
        updateTitle()
        rebuildMenuIfOpen()
    }

    private func setTargetMode(chinese: Bool, reason: String) {
        targetModeChinese = chinese
        targetModeKnown = true
        UserDefaults.standard.set(targetModeChinese, forKey: appConfig.modeStateKey)
        let label = chinese ? "中文" : "英文"
        log("mode set mode=\(label) reason=\(reason)")
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
        let title = needsInputMonitoringPermission ? "🥶" : displayMode.title
        let tooltip = tooltipText()

        guard title != lastRenderedTitle || tooltip != lastRenderedTooltip else {
            return
        }

        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltip
        lastRenderedTitle = title
        lastRenderedTooltip = tooltip
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
            let permission = NSMenuItem(title: "🥶 输入监控权限未完成", action: nil, keyEquivalent: "")
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

        let logs = NSMenuItem(title: "日志", action: #selector(openLogsDirectory), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let clearLogs = NSMenuItem(title: "清空日志", action: #selector(clearLogs), keyEquivalent: "")
        clearLogs.target = self
        menu.addItem(clearLogs)

        menu.addItem(.separator())

        let appNameItem = NSMenuItem(title: appConfig.displayName, action: nil, keyEquivalent: "")
        appNameItem.isEnabled = false
        menu.addItem(appNameItem)

        let appPath = Bundle.main.bundlePath
        let pathDisplay: String
        if appPath.hasPrefix("/Applications") {
            pathDisplay = "安装位置：/Applications"
        } else if appPath.hasPrefix(NSHomeDirectory() + "/Applications") {
            pathDisplay = "安装位置：~/Applications"
        } else {
            pathDisplay = "路径：\(appPath)"
        }
        let pathItem = NSMenuItem(title: pathDisplay, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        let version = NSMenuItem(title: "版本 \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let buildTime = NSMenuItem(title: "构建时间 \(appBuildTime)", action: nil, keyEquivalent: "")
        buildTime.isEnabled = false
        menu.addItem(buildTime)

        let updateTitle = updateCheckInProgress ? "正在检查更新..." : "检查更新..."
        let update = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = !updateCheckInProgress
        menu.addItem(update)

        let gitHub = NSMenuItem(title: "GitHub 主页", action: #selector(openGitHub), keyEquivalent: "")
        gitHub.target = self
        menu.addItem(gitHub)

        let star = NSMenuItem(title: "⭐ 给个 Star", action: #selector(openGitHubStar), keyEquivalent: "")
        star.target = self
        menu.addItem(star)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func rebuildMenuIfOpen() {
        guard menuIsOpen else {
            return
        }
        rebuildMenu()
    }

    @objc private func calibrateChinese() {
        setTargetMode(chinese: true, reason: "manual calibration")
        updateTitle()
        rebuildMenu()
    }

    @objc private func calibrateEnglish() {
        setTargetMode(chinese: false, reason: "manual calibration")
        updateTitle()
        rebuildMenu()
    }

    @objc private func retryEventTap() {
        requestListenAccessIfNeeded()
        installEventTap()
        if !eventTapActive || !listenAccessGranted {
            installGlobalMonitor()
        }
        updateTitle()
        rebuildMenu()
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openLogsDirectory() {
        ensureLogDirectory()
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    @objc private func clearLogs() {
        clearLogFiles()
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        logDirectoryCreated = true
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(gitHubURL)
    }

    @objc private func openGitHubStar() {
        NSWorkspace.shared.open(gitHubURL)
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
        rebuildMenuIfOpen()
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
        let timestamp = logDateFormatter.string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = logFileURL

        if let data = line.data(using: .utf8) {
            ensureLogDirectory()
            rotateLogIfNeeded(additionalBytes: data.count)
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

    private func logVerbose(_ message: String) {
        guard verboseEventLogging else {
            return
        }
        log(message)
    }

    private func ensureLogDirectory() {
        guard !logDirectoryCreated else {
            return
        }
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        logDirectoryCreated = true
    }

    private func rotateLogIfNeeded(additionalBytes: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value + UInt64(additionalBytes) > maximumLogFileSize else {
            return
        }

        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }

    private func clearLogFiles() {
        ensureLogDirectory()

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents {
            let name = url.lastPathComponent
            if name == appConfig.logFileName || name.hasPrefix("\(appConfig.logFileName).") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
