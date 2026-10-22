import Foundation

public enum WheelProtocolError: Error, Equatable { case malformed, busy, timeout, disconnected, unsupported, device(UInt8), invalidState }
public struct HIDPPMessage: Equatable, Sendable {
    public let device: UInt8
    public let feature: UInt8
    public let functionAndClient: UInt8
    public let payload: [UInt8]
    public init(report: [UInt8]) throws {
        guard let id = report.first, let length = [UInt8(0x10): 7, 0x11: 20, 0x12: 64][id], report.count == length else { throw WheelProtocolError.malformed }
        device = report[1]; feature = report[2]; functionAndClient = report[3]; payload = Array(report.dropFirst(4))
    }
}

/// Offline request/reply engine. No hardware adapter is exposed in this release.
/// Serial caller required. Timed-out sessions are poisoned so late replies cannot be reused.
public struct HIDPPDiscovery: Sendable {
    private struct Pending: Sendable { let client: UInt8; let deadline: Double; let started: Double }
    private var pending: Pending?
    private var nextClient: UInt8 = 1
    private var poisoned = false
    public private(set) var forceFeatureIndex: UInt8?
    public init() {}
    /// ROOT.GetFeature(0x8123), big endian feature ID, never a hard-coded feature index.
    public mutating func begin(now: Double, timeout: Double = 0.25) throws -> [UInt8] {
        guard !poisoned else { throw WheelProtocolError.disconnected }
        guard pending == nil else { throw WheelProtocolError.busy }
        guard now.isFinite, timeout.isFinite, timeout > 0, timeout <= 1, nextClient <= 15 else { throw WheelProtocolError.invalidState }
        let client = nextClient; nextClient += 1
        pending = Pending(client: client, deadline: now + timeout, started: now)
        return [0x11, 0xff, 0, client, 0x81, 0x23] + Array(repeating: 0, count: 14)
    }
    /// False means unrelated asynchronous input; it must not complete the pending transaction.
    public mutating func receive(_ report: [UInt8], now: Double) throws -> Bool {
        try poll(now: now)
        guard let request = pending else { return false }
        let message = try HIDPPMessage(report: report)
        guard message.device == 0xff else { return false }
        if message.feature == 0xff || message.feature == 0x8f {
            guard message.functionAndClient == 0, message.payload[0] == request.client else { return false }
            pending = nil; poisoned = true
            throw WheelProtocolError.device(message.payload[1])
        }
        guard message.feature == 0, message.functionAndClient == request.client else { return false }
        pending = nil
        guard message.payload[0] != 0, message.payload[0] != 0xff else { throw WheelProtocolError.unsupported }
        forceFeatureIndex = message.payload[0]
        return true
    }
    public mutating func poll(now: Double) throws {
        if let request = pending, !now.isFinite || now < request.started || now >= request.deadline {
            disconnect(); throw WheelProtocolError.timeout
        }
        guard !poisoned else { throw WheelProtocolError.disconnected }
    }
    public mutating func disconnect() { pending = nil; forceFeatureIndex = nil; poisoned = true }
}

/// Abstract acknowledged effect lifecycle. Wire encoders remain unavailable pending Xbox captures.
/// One operation at a time; failures invalidate every slot instead of guessing hardware state.
public struct HIDPPEffectLifecycle: Sendable {
    public enum Operation: Equatable, Sendable { case allocate, start(UInt8), stop(UInt8), erase(UInt8) }
    public enum Slot: Sendable { case stopped, playing }
    public private(set) var slots: [UInt8: Slot] = [:]
    private var pending: Operation?
    private var deadline = 0.0
    private var started = 0.0
    private var faulted = false
    public init() {}
    public mutating func begin(_ operation: Operation, now: Double) throws {
        guard !faulted, now.isFinite else { throw WheelProtocolError.invalidState }
        guard pending == nil else { throw WheelProtocolError.busy }
        switch operation {
        case .allocate: guard slots.count < 16 else { throw WheelProtocolError.busy }
        case .start(let id), .stop(let id), .erase(let id): guard slots[id] != nil else { throw WheelProtocolError.invalidState }
        }
        pending = operation; started = now; deadline = now + 0.25
    }
    public mutating func acknowledge(allocatedSlot: UInt8? = nil, now: Double) throws {
        try poll(now: now)
        guard let operation = pending else { throw WheelProtocolError.invalidState }
        switch operation {
        case .allocate:
            guard let id = allocatedSlot, id > 0, slots[id] == nil else { disconnect(); throw WheelProtocolError.malformed }
            slots[id] = .stopped
        case .start(let id): slots[id] = .playing
        case .stop(let id): slots[id] = .stopped
        case .erase(let id): slots.removeValue(forKey: id)
        }
        pending = nil
    }
    public mutating func poll(now: Double) throws {
        if pending != nil, !now.isFinite || now < started || now >= deadline { disconnect(); throw WheelProtocolError.timeout }
        guard !faulted else { throw WheelProtocolError.disconnected }
    }
    public mutating func disconnect() { slots.removeAll(); pending = nil; faulted = true }
}

public protocol ExperimentalWheelBackend {
    var model: WheelModel { get }
    var outputEnabled: Bool { get }
    mutating func disconnect()
}
public struct XboxWheelBackend: ExperimentalWheelBackend, Sendable {
    public let model: WheelModel = .g923XboxPC
    public let outputEnabled = false
    public var discovery = HIDPPDiscovery()
    public var effects = HIDPPEffectLifecycle()
    public init() {}
    public mutating func disconnect() { discovery.disconnect(); effects.disconnect() }
    public func forceReport() throws -> [UInt8] { throw WheelProtocolError.unsupported }
}
public struct DirectDriveBackend: ExperimentalWheelBackend, Sendable {
    public let model: WheelModel
    public let outputEnabled = false
    public init(model: WheelModel) throws {
        guard [.rs50, .gProPS, .gProXbox].contains(model) else { throw WheelProtocolError.unsupported }
        self.model = model
    }
    public mutating func disconnect() {}
    /// Descriptor-stripped 30-byte joystick payload from the pinned protocol specification.
    /// This does not infer report ID framing or accessory/sub-device layouts.
    public func decodeInputPayload(_ bytes: [UInt8]) throws -> BridgeInput {
        guard bytes.count == 30 else { throw WheelProtocolError.malformed }
        func u16(_ offset: Int) -> UInt32 { UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 }
        var input = BridgeInput()
        input.connected = true; input.steering = u16(4); input.throttle = u16(6)
        input.brake = u16(8); input.clutch = u16(10)
        input.hat = UInt32(bytes[0] & 15); if input.hat > 7 { input.hat = 8 }
        // Button bindings require model-specific capture acceptance; do not publish guessed bits.
        return input
    }
    public func forceReport() throws -> [UInt8] { throw WheelProtocolError.unsupported }
}

/// Concurrent callers use this actor, rather than sharing the offline value-state engines.
/// Discovery and abstract effect operations share one outstanding transaction budget.
/// There is intentionally no IOHID output adapter until model acceptance.
public actor XboxProtocolSession {
    private enum Pending { case discovery, effect }
    private var pending: Pending?
    private var backend = XboxWheelBackend()
    public init() {}
    public func discoverForceFeature(now: Double) throws -> [UInt8] {
        guard pending == nil else { throw WheelProtocolError.busy }
        let request = try backend.discovery.begin(now: now)
        pending = .discovery
        return request
    }
    public func receiveDiscovery(_ report: [UInt8], now: Double) throws -> UInt8? {
        guard pending == .discovery else { return nil }
        do {
            if try backend.discovery.receive(report, now: now) {
                pending = nil
                return backend.discovery.forceFeatureIndex
            }
            return nil
        } catch {
            disconnect()
            throw error
        }
    }
    public func beginEffect(_ operation: HIDPPEffectLifecycle.Operation, now: Double) throws {
        guard pending == nil else { throw WheelProtocolError.busy }
        guard backend.discovery.forceFeatureIndex != nil else { throw WheelProtocolError.unsupported }
        try backend.effects.begin(operation, now: now)
        pending = .effect
    }
    /// For offline harnesses only: a future accepted encoder must correlate the wire reply first.
    public func acknowledgeEffect(allocatedSlot: UInt8? = nil, now: Double) throws {
        guard pending == .effect else { throw WheelProtocolError.invalidState }
        do {
            try backend.effects.acknowledge(allocatedSlot: allocatedSlot, now: now)
            pending = nil
        } catch { disconnect(); throw error }
    }
    public func poll(now: Double) throws {
        do { try backend.discovery.poll(now: now); try backend.effects.poll(now: now) }
        catch { disconnect(); throw error }
    }
    public func disconnect() { backend.disconnect(); pending = nil }
}
