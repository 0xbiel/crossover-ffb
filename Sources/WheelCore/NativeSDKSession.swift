import Foundation
import Darwin

public enum WheelOutputMode: String, Codable, Sendable {
    case appManaged, sdkInputOnly, passive
    public var appMayWrite: Bool { self == .appManaged }
}

/// Cooperative process-wide exclusion. Older app versions and third-party writers must also
/// be stopped in preflight. SDK child lifetime must end before this lease is released.
public final class MotorProcessLease {
    private let descriptor: Int32
    public convenience init() throws {
        try self.init(lockPath: "/tmp/crossover-ffb-motor-\(getuid()).lock")
    }
    /// Internal injection keeps offline tests out of the live application's ownership domain.
    /// Both entry points use the same owner, type, symlink and link-count checks.
    internal init(lockPath: String) throws {
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SessionError.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw SessionError.busy
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
public enum SessionError: Error, Equatable { case busy, rejected, stale, invalidTransition }

/// Pure supervision state machine. It never launches Wine, opens HID or sends a motor command.
/// Faults latch until a fresh explicit arm. A fault never falls back to app-managed output.
public struct NativeSDKSupervisor: Sendable {
    public enum State: Equatable, Sendable { case idle, armed, running, faulted }
    public private(set) var state: State = .idle
    public private(set) var epoch: UInt64 = 0
    private var deadline: Double = 0
    private var lastTime: Double = 0
    public init() {}
    public mutating func arm(preflight: SDKPreflight, now: Double) throws -> UInt64 {
        guard state == .idle, preflight.blockers.isEmpty, now.isFinite else { throw SessionError.rejected }
        epoch &+= 1; state = .armed; deadline = now + 2; lastTime = now
        return epoch
    }
    public mutating func started(epoch: UInt64, now: Double) throws {
        guard self.epoch == epoch, state == .armed, now.isFinite, now >= lastTime, now < deadline else { fault(); throw SessionError.stale }
        state = .running; deadline = now + 0.5; lastTime = now
    }
    public mutating func heartbeat(epoch: UInt64, now: Double) throws {
        guard self.epoch == epoch, state == .running, now.isFinite, now >= lastTime, now < deadline else { fault(); throw SessionError.stale }
        deadline = now + 0.5; lastTime = now
    }
    public mutating func poll(now: Double) {
        if state == .armed || state == .running, !now.isFinite || now < lastTime || now >= deadline { fault() }
    }
    public mutating func disconnected() { fault() }
    public mutating func processExited() { fault() }
    private mutating func fault() { state = .faulted; epoch &+= 1 }
    /// Call only after the external SDK process is confirmed dead and its lease is released.
    public mutating func reset(processConfirmedDead: Bool) throws {
        guard processConfirmedDead else { throw SessionError.busy }
        state = .idle
    }
}

/// Versioned evidence, not a claim that stock CrossOver transports native TrueForce.
public struct SDKPreflight: Sendable {
    public static let transportContract = "winebus-11.17-g923-v1"
    public var model: WheelModel = .unknown
    public var explicitOptIn = false
    public var originalSDKSignatureVerified = false
    public var sdkVersion = ""
    public var crossoverVersion = ""
    public var transportContract = ""
    public var transportHashVerified = false
    public var physicalContainerVerified = false
    public var physicalPathVerified = false
    public var inputOnlyLeaseHeld = false
    public var competingWritersStopped = false
    public var hardwareAcceptanceRecorded = false
    public init() {}
    public var blockers: [String] {
        var result: [String] = []
        if model != .g923PS { result.append("Only PS/PC G923 is a native SDK candidate") }
        if !explicitOptIn { result.append("Explicit opt-in required") }
        if !originalSDKSignatureVerified || sdkVersion != "1.3.12" { result.append("User-supplied original signed SDK 1.3.12 evidence required") }
        if crossoverVersion != "27.0.0.41069" || transportContract != Self.transportContract || !transportHashVerified {
            result.append("Separately built and verified patched Wine 11.17 transport required")
        }
        if !physicalContainerVerified || !physicalPathVerified { result.append("Physical path and vendor collection/container grouping must be verified") }
        if !inputOnlyLeaseHeld || !competingWritersStopped { result.append("Exclusive motor ownership and input-only app required") }
        if !hardwareAcceptanceRecorded { result.append("Independent model/runtime/hardware acceptance is missing") }
        return result
    }
}

/// Reversible local plan only. No installation, registry writes, bottle mutation, SDK loading,
/// or process launch. Verification booleans must come from recorded evidence, not UI toggles.
public struct NativeSDKSetupPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sdkPath: String
    public let transportPath: String
    public let mode: WheelOutputMode
    public let transportContract: String
    public init(sdkPath: String, transportPath: String) {
        schemaVersion = 1; self.sdkPath = sdkPath; self.transportPath = transportPath
        mode = .sdkInputOnly; transportContract = SDKPreflight.transportContract
    }
    public func save(to newFile: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: newFile, options: .withoutOverwriting)
    }
    public func remove(from file: URL) throws {
        let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard saved == self else { throw SessionError.rejected }
        try FileManager.default.removeItem(at: file)
    }
}
