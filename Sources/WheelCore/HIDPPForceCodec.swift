import Foundation

/// Original serializer of published 0x8123 wire facts. All values are already in
/// protocol units: this layer deliberately performs no DirectInput/torque conversion.
public enum HIDPPForceEffect: Equatable, Sendable {
    public struct Envelope: Equatable, Sendable {
        public var attackLevel: UInt8, attackMilliseconds: UInt16
        public var fadeLevel: UInt8, fadeMilliseconds: UInt16
        public init(attackLevel: UInt8 = 0, attackMilliseconds: UInt16 = 0,
                    fadeLevel: UInt8 = 0, fadeMilliseconds: UInt16 = 0) {
            self.attackLevel = attackLevel; self.attackMilliseconds = attackMilliseconds
            self.fadeLevel = fadeLevel; self.fadeMilliseconds = fadeMilliseconds
        }
        fileprivate var bytes: [UInt8] { [attackLevel] + be(attackMilliseconds) + [fadeLevel] + be(fadeMilliseconds) }
    }
    public enum Wave: UInt8, Sendable { case sine = 1, square, triangle, sawUp, sawDown }
    public enum Condition: UInt8, Sendable { case spring = 6, damper, friction, inertia }
    case constant(level: Int16, envelope: Envelope)
    case ramp(start: Int16, end: Int16, envelope: Envelope)
    case periodic(wave: Wave, magnitude: UInt16, offset: Int16, period: UInt16, phase: UInt16, envelope: Envelope)
    /// Saturation/deadband are pre-encoded protocol values, not physical units.
    case condition(kind: Condition, leftSaturation: UInt16, leftCoefficient: Int16,
                   deadband: UInt16, center: Int16, rightCoefficient: Int16, rightSaturation: UInt16)
    fileprivate var type: UInt8 {
        switch self {
        case .constant: 0
        case .ramp: 10
        case .periodic(let wave, _, _, _, _, _): wave.rawValue
        case .condition(let kind, _, _, _, _, _, _): kind.rawValue
        }
    }
    public func payload(slot: UInt8 = 0, durationMilliseconds: UInt16, delayMilliseconds: UInt16 = 0) -> [UInt8] {
        let prefix = [slot, type] + be(durationMilliseconds) + be(delayMilliseconds)
        switch self {
        case .constant(let level, let envelope): return prefix + be(UInt16(bitPattern: level)) + envelope.bytes
        case .ramp(let start, let end, let envelope): return prefix + be(UInt16(bitPattern: start)) + be(UInt16(bitPattern: end)) + envelope.bytes
        case .periodic(_, let magnitude, let offset, let period, let phase, let envelope):
            return prefix + be(magnitude) + be(UInt16(bitPattern: offset)) + be(period) + be(phase) + envelope.bytes
        case .condition(_, let left, let leftCoefficient, let deadband, let center, let rightCoefficient, let right):
            return prefix + be(left) + be(UInt16(bitPattern: leftCoefficient)) + be(deadband) + be(UInt16(bitPattern: center)) + be(UInt16(bitPattern: rightCoefficient)) + be(right)
        }
    }
}
private func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

/// Offline transport engine. This type cannot open or write a physical device.
/// A caller submits returned bytes to a mock/capture comparator, then feeds replies here.
/// No automatic retry after timeout: state is unknown and all slots are invalidated.
public struct HIDPPForceSession: Sendable {
    public enum Command: Equatable, Sendable {
        case discover, getInfo
        case download(slot: UInt8, effect: HIDPPForceEffect, duration: UInt16, delay: UInt16)
        case play(UInt8), stop(UInt8), erase(UInt8)
    }
    private struct Request: Sendable {
        let command: Command, feature: UInt8, functionClient: UInt8
        let started: Double, deadline: Double
    }
    public private(set) var featureIndex: UInt8?
    public private(set) var usableSlots: UInt8?
    public private(set) var slots: [UInt8: HIDPPEffectLifecycle.Slot] = [:]
    private var request: Request?
    private var client: UInt8 = 1
    private var faulted = false
    public init() {}
    public mutating func begin(_ command: Command, now: Double) throws -> [UInt8] {
        guard !faulted else { throw WheelProtocolError.disconnected }
        guard request == nil else { throw WheelProtocolError.busy }
        guard now.isFinite, client <= 15 else { throw WheelProtocolError.invalidState }
        let feature: UInt8, function: UInt8, payload: [UInt8]
        switch command {
        case .discover:
            guard featureIndex == nil else { throw WheelProtocolError.invalidState }
            feature = 0; function = 0; payload = [0x81, 0x23]
        case .getInfo:
            guard let index = featureIndex, slots.isEmpty else { throw WheelProtocolError.invalidState }
            feature = index; function = 0; payload = []
        case .download(let slot, let effect, let duration, let delay):
            guard let index = featureIndex, let capacity = usableSlots,
                  slot == 0 ? slots.count < Int(capacity) : slots[slot] == .stopped else { throw WheelProtocolError.invalidState }
            feature = index; function = 2
            payload = effect.payload(slot: slot, durationMilliseconds: duration, delayMilliseconds: delay)
        case .play(let slot), .stop(let slot), .erase(let slot):
            guard let index = featureIndex, slots[slot] != nil else { throw WheelProtocolError.invalidState }
            feature = index
            switch command {
            case .play: function = 3; payload = [slot, 2]
            case .stop: function = 3; payload = [slot, 1]
            default: function = 4; payload = [slot]
            }
        }
        let functionClient = function << 4 | client
        client += 1
        request = Request(command: command, feature: feature, functionClient: functionClient, started: now, deadline: now + 0.25)
        let length = payload.count <= 16 ? 20 : 64
        return [length == 20 ? 0x11 : 0x12, 0xff, feature, functionClient] + payload + Array(repeating: 0, count: length - 4 - payload.count)
    }
    /// Returns true only for a matching acknowledged transaction. Unrelated input is ignored.
    public mutating func receive(_ bytes: [UInt8], now: Double) throws -> Bool {
        try poll(now: now)
        guard let pending = request else { return false }
        do {
            let reply = try HIDPPMessage(report: bytes)
            guard reply.device == 0xff else { return false }
            if reply.feature == 0xff || reply.feature == 0x8f {
                guard reply.functionAndClient == pending.feature, reply.payload[0] == pending.functionClient else { return false }
                throw WheelProtocolError.device(reply.payload[1])
            }
            guard reply.feature == pending.feature, reply.functionAndClient == pending.functionClient else { return false }
            switch pending.command {
            case .discover:
                guard reply.payload[0] > 0, reply.payload[0] < 0xff else { throw WheelProtocolError.unsupported }
                featureIndex = reply.payload[0]
            case .getInfo:
                // Published 0x8123 contract reserves one slot for autocenter. Do not initialize it.
                guard reply.payload[0] > 1 else { throw WheelProtocolError.unsupported }
                usableSlots = reply.payload[0] - 1
            case .download(let previous, _, _, _):
                let slot = reply.payload[0]
                guard let capacity = usableSlots, slot > 0, slot <= capacity,
                      previous == 0 ? slots[slot] == nil : slot == previous else { throw WheelProtocolError.malformed }
                slots[slot] = .stopped
            case .play(let slot): slots[slot] = .playing
            case .stop(let slot): slots[slot] = .stopped
            case .erase(let slot): slots.removeValue(forKey: slot)
            }
            request = nil
            return true
        } catch { disconnect(); throw error }
    }
    public mutating func poll(now: Double) throws {
        guard !faulted else { throw WheelProtocolError.disconnected }
        if let pending = request, !now.isFinite || now < pending.started || now >= pending.deadline {
            disconnect(); throw WheelProtocolError.timeout
        }
    }
    public mutating func disconnect() { request = nil; slots.removeAll(); featureIndex = nil; usableSlots = nil; faulted = true }
}

/// Thread-safe entry point for offline Xbox protocol work; deliberately no physical transport.
public actor XboxWireSession {
    private var session = HIDPPForceSession()
    public init() {}
    public func begin(_ command: HIDPPForceSession.Command, now: Double) throws -> [UInt8] { try session.begin(command, now: now) }
    public func receive(_ report: [UInt8], now: Double) throws -> Bool { try session.receive(report, now: now) }
    public func poll(now: Double) throws { try session.poll(now: now) }
    public func disconnect() { session.disconnect() }
}
