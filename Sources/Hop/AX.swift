import AppKit
import ApplicationServices

enum AX {
    enum WindowRead {
        case window(title: String, minimized: Bool)
        case notAWindow
        case gone
    }

    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Caps how long any single AX call may block, so one hung app can't stall the switcher.
    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isWindowSubrole(_ subrole: String?) -> Bool {
        subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    /// Reads subrole, title and minimized state in one round trip.
    static func read(_ window: AXUIElement) -> WindowRead {
        let attributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(window, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if err == .invalidUIElement { return .gone }
        guard err == .success, let list = values as? [Any], list.count == 3 else { return .notAWindow }
        guard isWindowSubrole(list[0] as? String) else { return .notAWindow }
        return .window(title: list[1] as? String ?? "", minimized: list[2] as? Bool ?? false)
    }
}
