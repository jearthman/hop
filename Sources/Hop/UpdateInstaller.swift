import AppKit
import CryptoKit
import HopCore
import Security

struct Release {
    let version: AppVersion
    let notes: String
    let pageURL: URL?
    let assetURL: URL
    let assetSize: Int64
    let sha256: String?
}

enum UpdateError: LocalizedError {
    case server(Int)
    case noDownload
    case cantReplace(String)
    case checksumMismatch
    case unverifiable
    case badBundle(String)
    case signatureMismatch(OSStatus)
    case tool(String, String)

    var errorDescription: String? {
        switch self {
        case let .server(code): return "GitHub returned an error (HTTP \(code))."
        case .noDownload: return "The latest release doesn't include an update package (Hop-<version>.zip)."
        case let .cantReplace(reason): return reason
        case .checksumMismatch: return "The download was corrupted (checksum mismatch)."
        case .unverifiable: return "The download couldn't be verified, so it wasn't installed."
        case let .badBundle(reason): return "The downloaded app isn't valid: \(reason)."
        case .signatureMismatch: return "The new version isn't signed with the same certificate as this one, so it wasn't installed."
        case let .tool(tool, output): return "\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

enum ReleaseFeed {
    /// Override for testing: `open Hop.app --args -UpdateFeedURL http://127.0.0.1:8000/latest.json`
    static var url: URL {
        UserDefaults.standard.string(forKey: "UpdateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/jearthman/hop/releases/latest")!
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64
            let digest: String?
        }
        let tag_name: String
        let body: String?
        let html_url: URL?
        let assets: [Asset]
    }

    static func latest(currentVersion: String) async throws -> Release? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil } // no releases yet
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.server(http.statusCode) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = AppVersion(release.tag_name) else { return nil }
        // Updates use the .zip asset: mounting the .dmg would trip macOS's removable-volume privacy check.
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("Hop") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noDownload
        }
        let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Release(version: version, notes: release.body ?? "", pageURL: release.html_url,
                       assetURL: asset.browser_download_url, assetSize: asset.size, sha256: digest)
    }
}

/// Downloads a file with progress reporting. Callbacks arrive on the main queue.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!
    private var expectedSize: Int64 = 0
    private var onProgress: ((Int64, Int64) -> Void)?

    func download(_ url: URL, to destination: URL, expectedSize: Int64,
                  onProgress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            DispatchQueue.main.async { self.task?.cancel() }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        onProgress?(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(UpdateError.server(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }
}

/// Verifies a downloaded DMG, extracts the app and swaps it in after Hop quits.
enum UpdateInstaller {
    static var currentApp: URL { Bundle.main.bundleURL }

    /// Fails early if Hop can't overwrite itself where it's running from.
    static func checkCanReplace() throws {
        let path = currentApp.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw UpdateError.cantReplace("Hop is running from a temporary location. Move Hop to your Applications folder, open it from there, and try again.")
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: currentApp.deletingLastPathComponent().path), fm.isWritableFile(atPath: path) else {
            throw UpdateError.cantReplace("Hop doesn't have permission to replace itself at \(path).")
        }
    }

    static func makeWorkDirectory() throws -> URL {
        // Same volume as the app, so the final swap is a fast rename.
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: currentApp, create: true)
    }

    /// Checks the downloaded zip, extracts the app and validates it. Returns the staged app.
    static func prepare(archive: URL, release: Release, workDir: URL) throws -> URL {
        let runningAdHoc = isAdHocSigned()
        if let expected = release.sha256 {
            guard try sha256(of: archive) == expected else { throw UpdateError.checksumMismatch }
        } else if runningAdHoc {
            // Without a certificate to compare against, the checksum is the only integrity check.
            throw UpdateError.unverifiable
        }

        let extracted = workDir.appendingPathComponent("extracted")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: extracted.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.badBundle("no app inside the archive")
        }
        let staged = extracted.appendingPathComponent(appName)

        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.badBundle("missing Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.badBundle("unexpected bundle identifier")
        }
        guard let newVersion = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              newVersion == release.version else {
            throw UpdateError.badBundle("its version doesn't match release \(release.version)")
        }

        try verifySignature(of: staged, matchRunningApp: !runningAdHoc)
        return staged
    }

    /// Starts a detached helper that waits for Hop to quit, swaps the bundles and reopens Hop.
    static func scheduleSwapAndRelaunch(newApp: URL, workDir: URL) throws {
        let script = workDir.appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        pid="$1"; target="$2"; new="$3"; work="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        backup="$work/previous.app"
        if mv "$target" "$backup" && ditto "$new" "$target"; then
          rm -rf "$backup"
        else
          rm -rf "$target"; mv "$backup" "$target"
        fi
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        open "$target"
        rm -rf "$work"
        """.write(to: script, atomically: true, encoding: .utf8)

        // Double-fork through sh so the helper outlives Hop.
        let quoted = [script.path, String(getpid()), currentApp.path, newApp.path, workDir.path].map(shellQuote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \(quoted) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Helpers

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runningStaticCode() -> SecStaticCode? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    static func isAdHocSigned() -> Bool {
        guard let code = runningStaticCode() else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as NSDictionary?)?[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// The new app must have a valid signature and, when Hop is certificate-signed, satisfy
    /// the running app's designated requirement (same identifier, same certificate).
    private static func verifySignature(of app: URL, matchRunningApp: Bool) throws {
        var requirement: SecRequirement?
        if matchRunningApp {
            guard let current = runningStaticCode(),
                  SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess else {
                throw UpdateError.unverifiable
            }
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.badBundle("unreadable code signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signatureMismatch(status) }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.tool(tool, output) }
        return output
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
