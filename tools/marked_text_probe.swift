// Marked-Text Probe — D2 可行性验证脚本
//
// 目的：验证「监听焦点应用文本框的 marked text」这个信号在常用 app
// 里是否稳定可拿。如果可以，主程序才会上 D2 方案。
//
// 用法：
//   ./tools/run_probe.sh
//
// 或手动编译运行：
//   swiftc tools/marked_text_probe.swift -o build/marked_text_probe
//   ./build/marked_text_probe
//
// 第一次运行时 macOS 会要求把这个 binary 加入「系统设置 → 隐私与安
// 全性 → 辅助功能」。授权后再跑一次。
//
// 然后切到目标输入法（豆包或微信），在不同 app 的输入框里：
//   1. 中文模式下敲拼音（如 nihao），看是否打印 markedText
//   2. 上屏，看 markedText 是否清空
//   3. 英文模式下敲字母，确认 markedText 始终为空但 AXValue 变化
//
// 测试覆盖建议：终端 / VSCode / Safari 地址栏 / Safari web 输入框 /
// Chrome web 输入框 / Notes / 微信聊天框 / Slack 聊天框

import AppKit
import ApplicationServices
import Foundation

// MARK: - AX helpers

func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
        return nil
    }
    return ref as? String
}

func axInt(_ element: AXUIElement, _ attr: String) -> Int? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
        return nil
    }
    if let n = ref as? Int { return n }
    if let n = ref as? NSNumber { return n.intValue }
    return nil
}

func axRange(_ element: AXUIElement, _ attr: String) -> NSRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
          let value = ref else { return nil }
    let axValue = value as! AXValue
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    AXValueGetValue(axValue, .cfRange, &range)
    return NSRange(location: range.location, length: range.length)
}

func axRole(_ element: AXUIElement) -> String {
    axString(element, kAXRoleAttribute) ?? "?"
}

func axSubrole(_ element: AXUIElement) -> String? {
    axString(element, kAXSubroleAttribute)
}

func axAllAttributes(_ element: AXUIElement) -> [String] {
    var ref: CFArray?
    guard AXUIElementCopyAttributeNames(element, &ref) == .success,
          let names = ref as? [String] else {
        return []
    }
    return names
}

// MARK: - Probe

enum FocusSource {
    case systemWide
    case appScoped
    case appElementOnly  // App 元素本身可读，但拿不到 focused 子元素
}

struct FocusResult {
    let element: AXUIElement?
    let source: FocusSource
    let appElementReadable: Bool
}

func currentFocusedElement() -> FocusResult {
    // Path 1: system-wide focused element
    let systemWide = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
       let value = ref {
        return FocusResult(element: (value as! AXUIElement), source: .systemWide, appElementReadable: true)
    }

    // Path 2: app-scoped focused element
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return FocusResult(element: nil, source: .systemWide, appElementReadable: false)
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)

    // Probe whether the app element itself is readable (has any AX attrs)
    var attrsRef: CFArray?
    let appReadable = AXUIElementCopyAttributeNames(appElement, &attrsRef) == .success

    var appRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appRef) == .success,
       let value = appRef {
        return FocusResult(element: (value as! AXUIElement), source: .appScoped, appElementReadable: appReadable)
    }

    // Path 3: only the app element is readable; we can still inspect its windows
    if appReadable {
        return FocusResult(element: appElement, source: .appElementOnly, appElementReadable: true)
    }

    return FocusResult(element: nil, source: .systemWide, appElementReadable: false)
}

func currentFocusedAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

func currentFocusedAppBundle() -> String {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
}

struct Sample {
    let timestamp: String
    let app: String
    let bundle: String
    let trusted: Bool
    let focus: FocusResult
    let role: String
    let subrole: String?
    let value: String
    let valueLen: Int
    let selectedText: String?
    let markedText: String?
    let markedAttrName: String?
    let selectedTextRange: String?
    let attrNames: [String]

    func formatted(verbose: Bool) -> String {
        guard focus.element != nil else {
            let hint = focus.appElementReadable
                ? "app supports AX but exposes NO focused element (Electron/web/custom-renderer?)"
                : "app does NOT implement AX at all (or no permission for it)"
            return "\(timestamp) [\(app) (\(bundle))] trusted=\(trusted) NO_FOCUSED_ELEMENT — \(hint)"
        }
        let valuePreview = value.count > 50
            ? String(value.prefix(50)) + "…(\(value.count))"
            : value
        var parts: [String] = [
            timestamp,
            "[\(app)]",
            "src=\(focus.source)",
            "role=\(role)\(subrole.map { "/\($0)" } ?? "")",
            "value=\"\(valuePreview)\"(len=\(valueLen))",
        ]
        if let s = selectedText { parts.append("selText=\"\(s)\"") }
        if let r = selectedTextRange { parts.append("selRange=\(r)") }
        if let m = markedText, let n = markedAttrName {
            parts.append("MARKED[\(n)]=\"\(m)\"")
        } else {
            parts.append("marked=nil")
        }
        if verbose {
            let ax = attrNames.filter { $0.lowercased().contains("mark") || $0.lowercased().contains("text") || $0.lowercased().contains("selected") || $0.lowercased().contains("value") }
            if !ax.isEmpty {
                parts.append("textAttrs=\(ax)")
            }
        }
        return parts.joined(separator: " ")
    }
}

let markedAttrCandidates = [
    "AXMarkedText",
    "AXMarkedTextRange",
    "AXMarkedTextString",
    "AXHasMarkedText",
    "AXTextInputMarkedRange",
]

func probeOnce(trusted: Bool) -> Sample {
    let ts = ISO8601DateFormatter().string(from: Date())
    let appName = currentFocusedAppName()
    let bundle = currentFocusedAppBundle()
    let focus = currentFocusedElement()
    guard let element = focus.element else {
        return Sample(timestamp: ts, app: appName, bundle: bundle, trusted: trusted,
                      focus: focus, role: "", subrole: nil, value: "", valueLen: 0,
                      selectedText: nil, markedText: nil, markedAttrName: nil,
                      selectedTextRange: nil, attrNames: [])
    }

    let value = axString(element, kAXValueAttribute) ?? ""
    let valueLen = axInt(element, kAXNumberOfCharactersAttribute) ?? value.count
    let selText = axString(element, kAXSelectedTextAttribute)

    var selRangeStr: String?
    if let range = axRange(element, kAXSelectedTextRangeAttribute) {
        selRangeStr = "\(range.location),\(range.length)"
    }

    var marked: String?
    var markedName: String?
    for attr in markedAttrCandidates {
        if let s = axString(element, attr), !s.isEmpty {
            marked = s
            markedName = attr
            break
        }
        if let r = axRange(element, attr), r.length > 0 {
            marked = "range(\(r.location),\(r.length))"
            markedName = attr
            break
        }
    }

    let attrNames = axAllAttributes(element)

    return Sample(
        timestamp: ts, app: appName, bundle: bundle, trusted: trusted,
        focus: focus, role: axRole(element), subrole: axSubrole(element),
        value: value, valueLen: valueLen,
        selectedText: selText, markedText: marked, markedAttrName: markedName,
        selectedTextRange: selRangeStr, attrNames: attrNames
    )
}

// MARK: - Main

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
let initialTrusted = AXIsProcessTrustedWithOptions(opts)

print("D2 marked-text probe")
print("  AXIsProcessTrusted = \(initialTrusted)")
print("  argv[0] = \(CommandLine.arguments[0])")
if !initialTrusted {
    print("  ⚠️  This binary is not yet in System Settings → Privacy & Security → Accessibility.")
    print("     macOS should have shown a permission prompt. Add this exact binary path,")
    print("     toggle it ON, then re-run. If you don't see the prompt, drag the binary")
    print("     into the Accessibility list manually.")
}
print("Sampling every 200 ms. Ctrl-C to stop.")
print("Switch focus to apps and type in Chinese / English mode to compare output.")
print("Set MARKED_TEXT_PROBE_VERBOSE=1 to also print discovered text-related AX attrs.")
print(String(repeating: "─", count: 80))

let verbose = ProcessInfo.processInfo.environment["MARKED_TEXT_PROBE_VERBOSE"] == "1"

var lastSummary = ""
var lastTickAt = Date.distantPast
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    let trusted = AXIsProcessTrusted()
    let s = probeOnce(trusted: trusted)
    let line = s.formatted(verbose: verbose)
    let now = Date()
    // Print on change OR at least once per 2 seconds for liveness.
    let summary = "\(s.app)|\(s.role)|\(s.value)|\(s.markedText ?? "")|\(s.selectedTextRange ?? "")"
    if summary != lastSummary || now.timeIntervalSince(lastTickAt) >= 2 {
        print(line)
        lastSummary = summary
        lastTickAt = now
    }
}

RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
