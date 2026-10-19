import AppKit
import HopCore

/// Checks GitHub for a newer release once a day (and on demand), then runs the
/// download → verify → swap → relaunch flow behind the update window.
@MainActor
final class Updater {
    static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private(set) var available: Release?
    private var timer: Timer?
    private var checking = false
    private var window: UpdateWindowController?
    private var installTask: Task<Void, Never>?
    private var workDir: URL?
    private let skippedKey = "SkippedVersion"

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(userInitiated: Bool) {
        if userInitiated, let available, installTask == nil {
            showOffer(available)
            return
        }
        guard !checking, installTask == nil else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                let current = Self.currentVersionString
                guard let release = try await ReleaseFeed.latest(currentVersion: current),
                      let currentVersion = AppVersion(current), currentVersion < release.version else {
                    available = nil
                    if userInitiated { showUpToDate() }
                    return
                }
                available = release
                let skipped = UserDefaults.standard.string(forKey: skippedKey).flatMap(AppVersion.init)
                if userInitiated || skipped != release.version {
                    showOffer(release)
                }
            } catch {
                if userInitiated { showCheckFailed(error) }
            }
        }
    }

    // MARK: - Window flow

    private func controller() -> UpdateWindowController {
        if let window { return window }
        let controller = UpdateWindowController()
        controller.onAction = { [weak self] action in self?.handle(action) }
        window = controller
        return controller
    }

    private func showOffer(_ release: Release) {
        let controller = controller()
        controller.showOffer(release, currentVersion: Self.currentVersionString)
        present(controller)
    }

    private func present(_ controller: UpdateWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        if controller.window?.isVisible != true { controller.window?.center() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func handle(_ action: UpdateWindowController.Action) {
        switch action {
        case .install:
            if let available { install(available) }
        case .skip:
            if let available { UserDefaults.standard.set(available.version.description, forKey: skippedKey) }
            window?.close()
        case .later:
            window?.close()
        case .cancel:
            installTask?.cancel()
        case .openReleasePage:
            if let url = available?.pageURL { NSWorkspace.shared.open(url) }
            window?.close()
        case .closed:
            installTask?.cancel()
        }
    }

    private func install(_ release: Release) {
        guard installTask == nil, let window else { return }
        window.showDownloading(received: 0, total: release.assetSize)
        installTask = Task {
            defer { installTask = nil }
            do {
                try UpdateInstaller.checkCanReplace()
                let work = try UpdateInstaller.makeWorkDirectory()
                workDir = work

                let archive = try await UpdateDownloader().download(
                    release.assetURL, to: work.appendingPathComponent("Hop.zip"), expectedSize: release.assetSize
                ) { received, total in
                    window.showDownloading(received: received, total: total)
                }
                try Task.checkCancellation()

                window.showWorking("Verifying update…")
                let newApp = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.prepare(archive: archive, release: release, workDir: work)
                }.value
                try Task.checkCancellation()

                window.showWorking("Installing update…")
                try UpdateInstaller.scheduleSwapAndRelaunch(newApp: newApp, workDir: work)
                window.showWorking("Restarting Hop…")
                try? await Task.sleep(nanoseconds: 400_000_000)
                NSApp.terminate(nil)
            } catch is CancellationError {
                cleanUp()
                window.close()
            } catch {
                cleanUp()
                window.showError(error.localizedDescription)
            }
        }
    }

    private func cleanUp() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - Alerts

    private func showUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Hop \(Self.currentVersionString) is the newest version available."
        alert.runModal()
    }

    private func showCheckFailed(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
