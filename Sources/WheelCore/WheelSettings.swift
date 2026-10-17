import Foundation

/// The wheel options Logitech G HUB offers for the G923/G29, applied by crossover-ffb instead:
/// operating range, steering and pedal sensitivity curves, combined pedals, a centering spring,
/// and the rev lights.
public struct WheelSettings: Codable, Equatable, Sendable {
    public static let rangeLimits = 40...900

    /// Degrees lock to lock. Sent to the wheel, which then reports full steering over this
    /// angle and holds a soft stop at the ends.
    public var range = 900
    /// 0…100; 50 is linear, higher is more sensitive around centre, lower is calmer.
    public var sensitivity = 50
    /// Return-to-centre spring for games that have no force feedback of their own.
    public var centeringSpring = false
    public var centeringStrength = 50
    /// Also apply the spring while a game plays force-feedback effects.
    public var springInFFBGames = false
    /// Accelerator, brake, clutch; 50 is linear.
    public var pedalSensitivity = [50, 50, 50]
    /// Accelerator and brake on one axis (the accelerator axis), for older games.
    public var combinedPedals = false
    /// Light the G923/G29 rev LEDs from game telemetry.
    public var revLights = true

    public init() {}

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WheelSettings()
        range = max(Self.rangeLimits.lowerBound, min(Self.rangeLimits.upperBound, try c.decodeIfPresent(Int.self, forKey: .range) ?? d.range))
        sensitivity = try c.decodeIfPresent(Int.self, forKey: .sensitivity) ?? d.sensitivity
        centeringSpring = try c.decodeIfPresent(Bool.self, forKey: .centeringSpring) ?? d.centeringSpring
        centeringStrength = try c.decodeIfPresent(Int.self, forKey: .centeringStrength) ?? d.centeringStrength
        springInFFBGames = try c.decodeIfPresent(Bool.self, forKey: .springInFFBGames) ?? d.springInFFBGames
        let pedals = try c.decodeIfPresent([Int].self, forKey: .pedalSensitivity) ?? d.pedalSensitivity
        pedalSensitivity = pedals.count == 3 ? pedals : d.pedalSensitivity
        combinedPedals = try c.decodeIfPresent(Bool.self, forKey: .combinedPedals) ?? d.combinedPedals
        revLights = try c.decodeIfPresent(Bool.self, forKey: .revLights) ?? d.revLights
    }

    /// G HUB-style response curve on a 0…1 magnitude: 50 → linear, 100 → x^(1/3), 0 → x^3.
    public static func curve(_ x: Double, sensitivity: Int) -> Double {
        let exponent = pow(3, Double(50 - max(0, min(100, sensitivity))) / 50)
        return pow(max(0, min(1, x)), exponent)
    }

    /// What the game sees, from the wheel's raw input. Pedals use the HID convention
    /// (65535 released, 0 fully pressed).
    public func apply(to raw: BridgeInput) -> BridgeInput {
        var out = raw
        if sensitivity != 50 {
            let x = Double(raw.steering) / 32767.5 - 1
            let y = (x < 0 ? -1 : 1) * Self.curve(abs(x), sensitivity: sensitivity)
            out.steering = Self.axis((y + 1) / 2)
        }
        func pressed(_ v: UInt32) -> Double { 1 - Double(v) / 65535 }
        func released(_ p: Double) -> UInt32 { Self.axis(1 - p) }
        let throttle = Self.curve(pressed(raw.throttle), sensitivity: pedalSensitivity[0])
        let brake = Self.curve(pressed(raw.brake), sensitivity: pedalSensitivity[1])
        out.clutch = released(Self.curve(pressed(raw.clutch), sensitivity: pedalSensitivity[2]))
        if combinedPedals {
            // Centred at rest; accelerator pushes it toward 0, brake toward 65535.
            out.throttle = Self.axis(0.5 - throttle / 2 + brake / 2)
            out.brake = 65535
        } else {
            out.throttle = released(throttle)
            out.brake = released(brake)
        }
        return out
    }

    /// Spring force in game units (−1…1) toward centre for a steering position −1…1.
    public func centeringForce(position: Double, velocity: Double) -> Double {
        let k = Double(max(0, min(100, centeringStrength))) / 100
        let spring = max(-1, min(1, position * 2.5)) * 0.6 * k
        let damping = max(-0.15, min(0.15, velocity * 0.02)) * k
        return -(spring + damping)
    }

    private static func axis(_ fraction: Double) -> UInt32 { UInt32((max(0, min(1, fraction)) * 65535).rounded()) }
}

/// Rev lights: five LEDs that fill from 65 % to 95 % of the car's max rpm and flash at the
/// limiter. Without a max rpm from the game it uses the highest rpm seen, but never less than
/// `fallbackFloor`, so idle and the first gears stay dark until the real limiter is learned.
public struct RevLights: Sendable {
    public private(set) var learnedMax = 0.0
    public static let fallbackFloor = 7000.0
    public init() {}

    public mutating func reset() { learnedMax = 0 }

    /// LED bit mask (bit 0 = first green LED … bit 4 = last red LED).
    public mutating func mask(rpm: Double, maxRpm: Double, now: Double) -> UInt8 {
        learnedMax = max(learnedMax, rpm)
        let top = (1500...25000).contains(maxRpm) ? maxRpm : max(learnedMax, Self.fallbackFloor)
        guard rpm > 0 else { return 0 }
        let fraction = rpm / top
        if fraction >= 0.97 { return Int(now * 8) % 2 == 0 ? 0x1f : 0 }
        let lit = Int(((fraction - 0.65) / 0.3 * 5).rounded(.up))
        return lit <= 0 ? 0 : UInt8((1 << min(5, lit)) - 1)
    }
}
