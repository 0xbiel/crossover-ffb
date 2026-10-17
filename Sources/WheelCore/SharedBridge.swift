import Foundation
import Darwin
import CBridgeAtomics

/// One force-feedback effect as mirrored by the Windows bridge DLL (bridge/shm.h, 96-byte record).
public struct BridgeEffect: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        case constant = 1, ramp, square, sine, triangle, sawtoothUp, sawtoothDown, spring, damper, inertia, friction
        public var isCondition: Bool { rawValue >= 8 }
    }
    public var slot: Int
    public var kind: Kind
    public var playing: Bool
    public var starts: UInt32
    public var durationMicros: UInt32 // 0xffffffff = infinite
    public var startDelayMicros: UInt32
    public var gain: UInt32 // 0...10000
    public var coordinates: UInt32 // 0x10 cartesian, 0x20 polar, 0x40 spherical
    public var axisCount: UInt32
    public var xIndex: UInt32
    public var direction: (Int32, Int32)
    public var hasEnvelope: Bool
    public var attackLevel: UInt32, attackMicros: UInt32, fadeLevel: UInt32, fadeMicros: UInt32
    /// constant: magnitude · ramp: start, end · periodic: magnitude, offset, phase, period ·
    /// condition: offset, positive/negative coefficient, positive/negative saturation, dead band.
    public var params: [Int32]
    public var iterations: UInt32
    public init(slot: Int, kind: Kind, playing: Bool = true, starts: UInt32 = 1, durationMicros: UInt32 = .max, startDelayMicros: UInt32 = 0, gain: UInt32 = 10000, coordinates: UInt32 = 0x10, axisCount: UInt32 = 1, xIndex: UInt32 = 0, direction: (Int32, Int32) = (1, 0), hasEnvelope: Bool = false, attackLevel: UInt32 = 0, attackMicros: UInt32 = 0, fadeLevel: UInt32 = 0, fadeMicros: UInt32 = 0, params: [Int32], iterations: UInt32 = 1) {
        self.slot = slot; self.kind = kind; self.playing = playing; self.starts = starts
        self.durationMicros = durationMicros; self.startDelayMicros = startDelayMicros; self.gain = gain
        self.coordinates = coordinates; self.axisCount = axisCount; self.xIndex = xIndex; self.direction = direction
        self.hasEnvelope = hasEnvelope; self.attackLevel = attackLevel; self.attackMicros = attackMicros
        self.fadeLevel = fadeLevel; self.fadeMicros = fadeMicros
        self.params = params + Array(repeating: 0, count: max(0, 6 - params.count)); self.iterations = iterations
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.slot == b.slot && a.kind == b.kind && a.playing == b.playing && a.starts == b.starts && a.params == b.params && a.gain == b.gain && a.direction == b.direction
    }
}

/// Force state published by the game side.
public struct BridgeForceState: Sendable {
    public var processID: UInt32 = 0
    public var heartbeatMilliseconds: UInt64 = 0
    public var acquired = false
    public var deviceGain: UInt32 = 10000
    public var paused = false
    public var actuatorsOff = false
    public var autocenter = false
    public var effects: [BridgeEffect] = []
    public init() {}
}

public struct BridgeInput: Sendable, Equatable {
    public var connected = false
    public var steering: UInt32 = 32768
    public var throttle: UInt32 = 65535
    public var brake: UInt32 = 65535
    public var clutch: UInt32 = 65535
    public var buttons: UInt32 = 0
    public var hat: UInt32 = 8 // 0...7 clockwise from north, 8 neutral
    public init() {}
}

/// Shared 4096-byte mapping at /tmp/crossover-ffb-<uid>/ffb-v2.bin. Wine maps the same file
/// MAP_SHARED inside the game, so both sides see each other's stores without any file I/O.
/// The file is never truncated or replaced, so a game keeps working across app restarts.
public final class SharedBridge: @unchecked Sendable {
    public enum Failure: Error { case unsafeDirectory, unsafeFile, system(Int32) }
    public static let size = 8192 // 4096 force/input + telemetry block
    public static let magic: UInt32 = 0x3242_4643 // "CFB2"
    static let input = 64, forceHeader = 256, effects = 320, effectSize = 96, effectCount = 32, telemetry = 4096
    public static var defaultPath: String { "/tmp/crossover-ffb-\(getuid())/ffb-v2.bin" }
    private let base: UnsafeMutableRawPointer
    private var inputSequence: UInt32

    public init(path: String = SharedBridge.defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw Failure.system(errno) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafeDirectory }
        chmod(directory, 0o700)
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafeFile }
        if info.st_size < Self.size, ftruncate(fd, off_t(Self.size)) != 0 { throw Failure.system(errno) }
        guard let mapped = mmap(nil, Self.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { throw Failure.system(errno) }
        base = mapped
        inputSequence = cfb_load32_acquire(base + Self.input) & ~1
        cfb_store32_relaxed(base + 4, 2)
        cfb_store32_relaxed(base + 8, UInt32(Self.size))
        cfb_store32_release(base, Self.magic)
    }
    deinit { munmap(base, Self.size) }

    public func publish(_ value: BridgeInput, unixMilliseconds: UInt64 = SharedBridge.nowMilliseconds()) {
        let block = base + Self.input
        inputSequence |= 1 // odd: write in progress
        cfb_store32_release(block, inputSequence)
        cfb_fence()
        cfb_store32_relaxed(block + 4, value.connected ? 1 : 0)
        cfb_store64_relaxed(block + 8, unixMilliseconds)
        cfb_store32_relaxed(block + 16, min(value.steering, 65535))
        cfb_store32_relaxed(block + 20, min(value.throttle, 65535))
        cfb_store32_relaxed(block + 24, min(value.brake, 65535))
        cfb_store32_relaxed(block + 28, min(value.clutch, 65535))
        cfb_store32_relaxed(block + 32, value.buttons & 0x01ff_ffff)
        cfb_store32_relaxed(block + 36, min(value.hat, 8))
        cfb_fence()
        inputSequence &+= 1 // even: consistent
        cfb_store32_release(block, inputSequence)
    }

    /// Consistent copy of the game's force state, or nil if the game is mid-write.
    public func readForce() -> BridgeForceState? {
        let header = base + Self.forceHeader
        let length = Self.effects + Self.effectSize * Self.effectCount - Self.forceHeader
        var bytes = [UInt8](repeating: 0, count: length)
        for _ in 0..<32 {
            let first = cfb_load32_acquire(header)
            if first & 1 != 0 { continue }
            bytes.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: header, count: length)) }
            cfb_fence()
            if cfb_load32_acquire(header) == first { return Self.decode(bytes) }
        }
        return nil
    }

    /// Latest raw game telemetry page (source 1 = AC/ACC acpmf_physics, 2 = AC EVO), when the DLL
    /// copied it, and the car's max rpm from the static page (0 when unknown).
    public func readTelemetry() -> (source: UInt32, unixMilliseconds: UInt64, maxRpm: UInt32, bytes: [UInt8])? {
        let block = base + Self.telemetry
        for _ in 0..<32 {
            let first = cfb_load32_acquire(block)
            if first & 1 != 0 { continue }
            let source = cfb_load32_acquire(block + 4), length = min(Int(cfb_load32_acquire(block + 8)), 2048)
            let stamp = cfb_load64_acquire(block + 16), maxRpm = cfb_load32_acquire(block + 24)
            guard source != 0, length > 0 else { return nil }
            let bytes = [UInt8](UnsafeRawBufferPointer(start: block + 32, count: length))
            cfb_fence()
            if cfb_load32_acquire(block) == first { return (source, stamp, maxRpm, bytes) }
        }
        return nil
    }

    static func decode(_ b: [UInt8]) -> BridgeForceState {
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24 }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
        var s = BridgeForceState()
        s.processID = u32(4)
        s.heartbeatMilliseconds = UInt64(u32(8)) | UInt64(u32(12)) << 32
        s.acquired = u32(16) != 0
        s.deviceGain = min(u32(20), 10000)
        let flags = u32(24)
        s.paused = flags & 1 != 0; s.actuatorsOff = flags & 2 != 0; s.autocenter = flags & 4 != 0
        for slot in 0..<effectCount {
            let o = effects - forceHeader + slot * effectSize
            guard let kind = BridgeEffect.Kind(rawValue: u32(o)) else { continue }
            s.effects.append(BridgeEffect(slot: slot, kind: kind, playing: u32(o+4) != 0, starts: u32(o+8), durationMicros: u32(o+12), startDelayMicros: u32(o+16), gain: min(u32(o+20), 10000), coordinates: u32(o+24), axisCount: u32(o+28), xIndex: u32(o+32), direction: (i32(o+36), i32(o+40)), hasEnvelope: u32(o+44) != 0, attackLevel: u32(o+48), attackMicros: u32(o+52), fadeLevel: u32(o+56), fadeMicros: u32(o+60), params: (0..<6).map { i32(o + 64 + 4 * $0) }, iterations: u32(o+88)))
        }
        return s
    }

    public static func nowMilliseconds() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }
}
