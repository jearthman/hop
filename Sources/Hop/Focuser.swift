import AppKit
import ApplicationServices

enum Focuser {
    static func focus(_ item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        if app?.isHidden == true { app?.unhide() }
        if item.isMinimized {
            AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let broughtForward = item.windowID != 0 && PrivateAPI.bringToFront(pid: item.pid, windowID: item.windowID)
        AXUIElementSetAttributeValue(item.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
        if !broughtForward { app?.activate() }
    }
}
