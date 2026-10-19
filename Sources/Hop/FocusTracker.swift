import AppKit
import ApplicationServices

/// Watches each app's focused-window changes so window recency stays accurate
/// even when you switch windows without Hop.
final class FocusTracker {
    var onFocusedWindow: ((AXUIElement) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]

    func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue().onFocusedWindow?(element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid),
                                            kAXFocusedWindowChangedNotification as CFString, refcon)
        guard err == .success || err == .notificationAlreadyRegistered else {
            // Freshly launched apps often aren't ready for AX yet.
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.observe(app, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func forget(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
