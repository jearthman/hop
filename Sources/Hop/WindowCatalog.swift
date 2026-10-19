import AppKit
import ApplicationServices

struct WindowItem {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let element: AXUIElement
    let isMinimized: Bool
    let isAppHidden: Bool
}

struct AppInfo {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let isHidden: Bool

    @MainActor static func regularApps() -> [AppInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown", icon: $0.icon, isHidden: $0.isHidden) }
    }
}

/// Builds window snapshots on demand and remembers what it learns between snapshots:
/// AX elements for windows that have moved to other Spaces, and focus recency.
/// Nothing runs while idle except event-driven bookkeeping.
final class WindowCatalog: @unchecked Sendable {
    private struct Found {
        let windowID: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let title: String
        let minimized: Bool
    }

    private let lock = NSLock()
    private var cache: [CGWindowID: AXUIElement] = [:]
    private var mru: [CGWindowID] = []
    private var bruteScanned: [pid_t: Set<CGWindowID>] = [:]

    private let queue = DispatchQueue(label: "hop.catalog", qos: .userInteractive)
    private let bruteQueue = DispatchQueue(label: "hop.bruteforce", qos: .utility)

    /// Called on the main queue when a background scan finds windows the last snapshot missed.
    var onWindowsDiscovered: (() -> Void)?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Public

    func snapshot(apps: [AppInfo], completion: @escaping ([WindowItem]) -> Void) {
        queue.async {
            let items = self.build(apps)
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// Fills recency from the current z-order so the first open after launch is sensible.
    func warmUp(apps: [AppInfo]) {
        queue.async {
            let ids = self.build(apps).map(\.windowID).filter { $0 != 0 }
            self.locked {
                let known = Set(self.mru)
                self.mru.append(contentsOf: ids.filter { !known.contains($0) })
            }
        }
    }

    /// Remembers elements for windows on the current Space, before they become invisible to AX.
    func harvestVisible(apps: [AppInfo]) {
        queue.async { _ = self.harvest(apps.map(\.pid)) }
    }

    func recordFocus(_ windowID: CGWindowID) {
        guard windowID != 0 else { return }
        locked {
            mru.removeAll { $0 == windowID }
            mru.insert(windowID, at: 0)
            if mru.count > 500 { mru.removeLast(mru.count - 500) }
        }
    }

    func noteFocused(window: AXUIElement) {
        queue.async {
            let wid = PrivateAPI.windowID(of: window)
            guard wid != 0 else { return }
            self.locked { self.cache[wid] = window }
            self.recordFocus(wid)
        }
    }

    func recordFocusedWindow(ofPID pid: pid_t) {
        queue.async {
            if let window = AX.focusedWindow(of: pid) {
                let wid = PrivateAPI.windowID(of: window)
                guard wid != 0 else { return }
                self.locked { self.cache[wid] = window }
                self.recordFocus(wid)
            }
        }
    }

    // MARK: - Snapshot

    private func build(_ apps: [AppInfo]) -> [WindowItem] {
        let appsByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let cgWindows = Self.cgWindowList().filter { appsByPID[$0.pid] != nil }

        var found: [CGWindowID: Found] = [:]
        var unidentified: [Found] = []
        for f in harvest(Array(appsByPID.keys)) {
            if f.windowID == 0 { unidentified.append(f) } else { found[f.windowID] = f }
        }

        // Windows the window server knows about but AX didn't list are usually on another
        // Space. Use elements remembered from earlier, and queue a deeper scan for the rest.
        let liveIDs = Set(cgWindows.map(\.id))
        let cached = locked { () -> [CGWindowID: AXUIElement] in
            cache = cache.filter { liveIDs.contains($0.key) }
            return cache
        }
        var missing: [pid_t: Set<CGWindowID>] = [:]
        for w in cgWindows where found[w.id] == nil {
            if let element = cached[w.id] {
                switch AX.read(element) {
                case let .window(title, minimized):
                    found[w.id] = Found(windowID: w.id, pid: w.pid, element: element, title: title, minimized: minimized)
                    continue
                case .gone:
                    locked { cache[w.id] = nil }
                case .notAWindow:
                    continue
                }
            }
            missing[w.pid, default: []].insert(w.id)
        }
        scheduleBruteForce(missing)

        let recency = locked { Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: min) }
        var entries: [(recency: Int, zOrder: Int, item: WindowItem)] = []
        for (z, w) in cgWindows.enumerated() {
            guard let f = found.removeValue(forKey: w.id), let app = appsByPID[f.pid] else { continue }
            entries.append((recency[f.windowID] ?? Int.max, z, item(f, app)))
        }
        var z = cgWindows.count
        for f in Array(found.values) + unidentified {
            guard let app = appsByPID[f.pid] else { continue }
            z += 1
            entries.append((recency[f.windowID] ?? Int.max, z, item(f, app)))
        }
        entries.sort { ($0.recency, $0.zOrder) < ($1.recency, $1.zOrder) }
        return entries.map(\.item)
    }

    private func item(_ f: Found, _ app: AppInfo) -> WindowItem {
        WindowItem(windowID: f.windowID, pid: f.pid, appName: app.name, title: f.title,
                   icon: app.icon, element: f.element, isMinimized: f.minimized, isAppHidden: app.isHidden)
    }

    /// Reads every app's AX window list in parallel and caches what it finds.
    private func harvest(_ pids: [pid_t]) -> [Found] {
        var results = [[Found]](repeating: [], count: pids.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            var appWindows: [Found] = []
            for window in AX.windows(of: pid) {
                if case let .window(title, minimized) = AX.read(window) {
                    appWindows.append(Found(windowID: PrivateAPI.windowID(of: window), pid: pid,
                                            element: window, title: title, minimized: minimized))
                }
            }
            resultsLock.lock()
            results[i] = appWindows
            resultsLock.unlock()
        }
        let all = results.flatMap { $0 }
        locked {
            for f in all where f.windowID != 0 { cache[f.windowID] = f.element }
        }
        return all
    }

    private func scheduleBruteForce(_ missing: [pid_t: Set<CGWindowID>]) {
        guard PrivateAPI.canBruteForce, !missing.isEmpty else { return }
        // Only rescan an app when it has unresolved window ids we haven't already tried;
        // some apps keep invisible helper windows that will never resolve.
        let todo: [pid_t: Set<CGWindowID>] = locked {
            var todo: [pid_t: Set<CGWindowID>] = [:]
            for (pid, ids) in missing {
                let tried = bruteScanned[pid, default: []]
                if !ids.isSubset(of: tried) {
                    todo[pid] = ids
                    bruteScanned[pid] = tried.union(ids)
                }
            }
            return todo
        }
        guard !todo.isEmpty else { return }
        bruteQueue.async {
            var discovered = false
            for (pid, ids) in todo {
                for (wid, element) in PrivateAPI.bruteForceWindows(pid: pid, budget: 0.25) {
                    self.locked { self.cache[wid] = element }
                    if ids.contains(wid) { discovered = true }
                }
            }
            if discovered {
                DispatchQueue.main.async { self.onWindowsDiscovered?() }
            }
        }
    }

    /// Layer-0 windows of every app, front to back. Needs no Screen Recording permission
    /// because it never reads window names.
    private static func cgWindowList() -> [(id: CGWindowID, pid: pid_t)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (id, pid)
        }
    }
}
