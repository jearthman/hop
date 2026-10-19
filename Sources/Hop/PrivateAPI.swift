import AppKit
import ApplicationServices

/// Private macOS calls, resolved at runtime with dlsym so a missing symbol degrades
/// gracefully instead of crashing at launch. Same techniques AltTab uses.
enum PrivateAPI {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func load<T>(_ name: String, from handle: UnsafeMutableRawPointer?, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let getWindow = load("_AXUIElementGetWindow", from: rtldDefault, as: GetWindowFn.self)
    private static let createWithRemoteToken = load("_AXUIElementCreateWithRemoteToken", from: rtldDefault, as: CreateWithRemoteTokenFn.self)
    private static let getProcessForPID = load("GetProcessForPID", from: rtldDefault, as: GetProcessForPIDFn.self)
    private static let setFrontProcess = load("_SLPSSetFrontProcessWithOptions", from: skyLight, as: SetFrontProcessFn.self)
    private static let postEventRecord = load("SLPSPostEventRecordTo", from: skyLight, as: PostEventRecordFn.self)

    static var canBruteForce: Bool { createWithRemoteToken != nil && getWindow != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID {
        guard let getWindow else { return 0 }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success ? id : 0
    }

    /// AX only lists windows on the current Space. Elements for windows on other Spaces can
    /// still be created from a remote token (pid + element id), so probe the low id range.
    static func bruteForceWindows(pid: pid_t, budget: TimeInterval) -> [(CGWindowID, AXUIElement)] {
        guard let create = createWithRemoteToken else { return [] }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        let deadline = Date().addingTimeInterval(budget)
        var found: [(CGWindowID, AXUIElement)] = []
        for elementID: UInt64 in 0..<1000 {
            if Date() > deadline { break }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData)?.takeRetainedValue(),
                  AX.isWindowSubrole(AX.subrole(of: element)) else { continue }
            let wid = windowID(of: element)
            if wid != 0 { found.append((wid, element)) }
        }
        return found
    }

    /// Makes a specific window the key window of its app and brings that app forward,
    /// switching Spaces if needed. Returns false when the private calls are unavailable.
    static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, windowID, userGenerated) == .success else { return false }

        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
        return true
    }
}
