import Foundation

/// Logitech TrueForce stream on USB interface 2 (vendor page 0xFFFD, usage 0xFD01, report 1,
/// 64-byte reports). Wire facts from the public reverse-engineering notes of
/// github.com/mescon/logitech-trueforce-linux-driver (docs/TRUEFORCE_PROTOCOL.md); original code.
///
/// While a stream runs, the wheel steers by the packet's 16-bit `cur` torque target and plays the
/// 13-slot sample window additively on top as high-frequency haptics. On the G923 the classic
/// constant-force commands are ignored for the duration, so the FFB must ride in `cur`.
public enum TrueForceProtocol {
    public static let reportID: UInt8 = 1
    public static let length = 64
    public static let sampleRate = 4000.0
    public static let windowSlots = 13
    public static let maxNewSamples = 12

    public static func packet(_ type: UInt8, sequence: UInt8, payload: [UInt8] = []) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: length)
        p[0] = reportID
        p[4] = type
        p[5] = sequence
        for (i, byte) in payload.prefix(length - 6).enumerated() { p[6 + i] = byte }
        return p
    }

    private static func float(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

    /// One bring-up pass: 48 parameter queries, a neutral prime, operating range, handshake,
    /// six effect-slot configurations (neutral samples in between), runtime parameters,
    /// then stop and start. The caller sends it twice, restarting the sequence at 1 each pass.
    public static func initPass() -> [[UInt8]] {
        let neutral: [UInt8] = [0x00, 0x80, 0x00, 0x80]
        var types: [(UInt8, [UInt8])] = []
        let indices: [UInt8] = [0x00, 0x30] + Array(0x01...0x1d) + Array(0x2b...0x3c).filter { $0 != 0x30 }
        for index in indices { types.append((0x05, [index])) }
        types.append((0x01, neutral))
        types.append((0x0e, float(2700)))
        types.append((0x01, neutral))
        types.append((0x07, []))
        types.append((0x01, neutral))
        for slot in UInt8(1)...6 {
            if slot == 4 {
                types.append((0x09, [0x02, 0x02] + float(1) + float(350)))
                types.append((0x01, neutral))
            }
            types.append((0x06, slot <= 3 ? [0x01, slot] : [0x01, slot, 0x01]))
            if slot < 6 { types.append((0x01, neutral)) }
        }
        types.append((0x04, []))
        types.append((0x03, []))
        return types.enumerated().map { packet($1.0, sequence: UInt8(truncatingIfNeeded: $0 + 1), payload: $1.1) }
    }

    public static func stop(sequence: UInt8) -> [UInt8] { packet(0x04, sequence: sequence) }
}

/// Builds type-0x01 stream packets with the rolling 13-sample window.
public struct TrueForceStreamer {
    public private(set) var sequence: UInt8
    private var window = [UInt16](repeating: 0x8000, count: TrueForceProtocol.windowSlots)
    public init(sequence: UInt8 = 0) { self.sequence = sequence }

    static func code(_ v: Double) -> UInt16 { UInt16(max(0, min(65535, (32768 + max(-1, min(1, v)) * 32767).rounded()))) }

    /// `torque` −1…+1 is the motor target (0xFFFF full right); `samples` are new haptic samples.
    public mutating func packet(torque: Double, samples: [Double]) -> [UInt8] {
        sequence &+= 1
        let fresh = samples.suffix(TrueForceProtocol.maxNewSamples).map(Self.code)
        window = Array((window + fresh).suffix(TrueForceProtocol.windowSlots))
        let cur = Self.code(torque)
        var payload: [UInt8] = [UInt8(cur & 0xff), UInt8(cur >> 8), UInt8(cur & 0xff), UInt8(cur >> 8),
                                UInt8(fresh.count), fresh.isEmpty ? 0x00 : 0x0d]
        for s in window { payload += [UInt8(s & 0xff), UInt8(s >> 8), UInt8(s & 0xff), UInt8(s >> 8)] }
        return TrueForceProtocol.packet(0x01, sequence: sequence, payload: payload)
    }
    public mutating func nextSequence() -> UInt8 { sequence &+= 1; return sequence }
}

/// The parts of a game's telemetry that drive simulated TrueForce.
public struct GameTelemetry: Sendable, Equatable {
    public var packet: Int32 = 0
    public var rpm = 0.0, gas = 0.0, speedKmh = 0.0
    public var suspension = [Double](repeating: 0, count: 4)
    public var wheelSlip = [Double](repeating: 0, count: 4)
    public var kerb = 0.0, slip = 0.0, g = 0.0, abs = 0.0, road = 0.0
    public var engineRunning = true
    public init() {}

    /// Kunos `SPageFilePhysics` (all fields 4 bytes; offsets are word indices), shared by
    /// Assetto Corsa, ACC and AC EVO. The four *Vibrations fields exist only in ACC 1.8+ and
    /// AC EVO, the page is zero-padded otherwise; word 198 is g vibration in ACC and road
    /// vibration in AC EVO.
    public static func acPhysics(_ b: [UInt8], evo: Bool = false) -> GameTelemetry? {
        guard b.count >= 200 * 4 else { return nil }
        func word(_ i: Int) -> UInt32 { UInt32(b[4*i]) | UInt32(b[4*i+1]) << 8 | UInt32(b[4*i+2]) << 16 | UInt32(b[4*i+3]) << 24 }
        func f(_ i: Int) -> Double { let v = Double(Float(bitPattern: word(i))); return v.isFinite ? v : 0 }
        var t = GameTelemetry()
        t.packet = Int32(bitPattern: word(0))
        t.gas = f(1)
        t.rpm = Double(Int32(bitPattern: word(5)))
        t.speedKmh = f(7)
        t.wheelSlip = (14...17).map(f)
        t.suspension = (46...49).map(f)
        t.engineRunning = word(195) != 0 || t.rpm > 300
        t.kerb = f(196); t.slip = f(197); t.abs = f(199)
        if evo { t.road = f(198) } else { t.g = f(198) }
        return t
    }
}

/// Turns telemetry into a 4 kHz haptic signal: engine note, road/kerb texture, tyre slip, ABS.
public final class HapticSynth {
    public var engineGain = 0.5, roadGain = 0.6, slipGain = 0.6
    private var target = GameTelemetry(), current = GameTelemetry()
    private var lastSuspension: [Double]? , suspensionVelocity = 0.0, lastUpdate = 0.0
    private var level = 0.0 // fades the whole signal in/out when telemetry starts/stops
    private var live = false
    private var enginePhase = 0.0, kerbPhase = 0.0, slipPhase = 0.0, absPhase = 0.0
    private var noise: UInt32 = 0x1234_5678, lowNoise = 0.0
    public init() {}

    public func update(_ t: GameTelemetry?, now: Double) {
        guard let t else { live = false; return }
        if t.packet != target.packet || lastSuspension == nil {
            let dt = max(0.001, now - lastUpdate)
            if let last = lastSuspension {
                let v = zip(t.suspension.prefix(2), last.prefix(2)).map { ($0 - $1) / dt }.reduce(0, +) / 2
                suspensionVelocity = v.isFinite ? max(-2, min(2, v)) : 0
            }
            lastSuspension = t.suspension
            lastUpdate = now
            target = t
        }
        live = now - lastUpdate < 0.3 // paused or quit: packet stops advancing
    }

    private func random() -> Double {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
        return Double(noise) / Double(UInt32.max) * 2 - 1
    }

    public func render(count: Int) -> [Double] {
        let dt = 1 / TrueForceProtocol.sampleRate
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let k = 0.004 // ~6 Hz smoothing of control values
            current.rpm += (target.rpm - current.rpm) * k
            current.gas += (target.gas - current.gas) * k
            current.speedKmh += (target.speedKmh - current.speedKmh) * k
            current.kerb += (min(1, max(0, target.kerb)) - current.kerb) * k * 4
            current.slip += (min(1, max(0, target.slip)) - current.slip) * k * 4
            current.abs += (min(1, max(0, target.abs)) - current.abs) * k * 4
            current.g += (min(1, max(0, target.g)) - current.g) * k * 8
            current.road += (min(1, max(0, target.road)) - current.road) * k * 4
            level += ((live ? 1 : 0) - level) * 0.002

            // Engine: firing frequency of a four-stroke four (two pulses per revolution).
            let fe = max(5, min(300, current.rpm / 60 * 2))
            enginePhase = (enginePhase + fe * dt).truncatingRemainder(dividingBy: 1)
            let engineAmp = target.engineRunning ? engineGain * (0.12 + 0.3 * current.gas) : 0
            var s = engineAmp * (sin(2 * .pi * enginePhase) + 0.35 * sin(4 * .pi * enginePhase))

            // Road: suspension motion plus speed-scaled fine grain; kerbs as a ~40 Hz rumble.
            lowNoise += (random() - lowNoise) * 0.15
            let speed = min(1, current.speedKmh / 250)
            s += roadGain * (0.6 * suspensionVelocity + (0.08 * speed + 0.8 * current.road) * lowNoise)
            kerbPhase = (kerbPhase + (30 + 25 * speed) * dt).truncatingRemainder(dividingBy: 1)
            s += roadGain * current.kerb * (kerbPhase < 0.5 ? 0.5 : -0.5) + roadGain * current.g * 0.6 * random()

            // Tyres: slip as a coarse ~28 Hz judder, ABS as ~16 Hz pulses.
            slipPhase = (slipPhase + 28 * dt).truncatingRemainder(dividingBy: 1)
            absPhase = (absPhase + 16 * dt).truncatingRemainder(dividingBy: 1)
            s += slipGain * (current.slip * 0.5 * sin(2 * .pi * slipPhase) + current.abs * (absPhase < 0.3 ? 0.6 : -0.15))

            out[i] = max(-1, min(1, s * level))
        }
        return out
    }
}
