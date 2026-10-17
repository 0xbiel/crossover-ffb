import XCTest
@testable import WheelCore

final class WheelSettingsTests: XCTestCase {
    func testCurveIsLinearAtFiftyAndBendsEitherWay() {
        XCTAssertEqual(WheelSettings.curve(0.25, sensitivity: 50), 0.25, accuracy: 1e-9)
        XCTAssertGreaterThan(WheelSettings.curve(0.25, sensitivity: 80), 0.25)
        XCTAssertLessThan(WheelSettings.curve(0.25, sensitivity: 20), 0.25)
        for s in [0, 50, 100] {
            XCTAssertEqual(WheelSettings.curve(0, sensitivity: s), 0)
            XCTAssertEqual(WheelSettings.curve(1, sensitivity: s), 1, accuracy: 1e-9)
        }
    }

    func testDefaultsPassInputThrough() {
        var raw = BridgeInput(); raw.steering = 12000; raw.throttle = 20000; raw.brake = 65535; raw.clutch = 0
        XCTAssertEqual(WheelSettings().apply(to: raw), raw)
    }

    func testSteeringCurveKeepsCentreAndEnds() {
        var w = WheelSettings(); w.sensitivity = 90
        var raw = BridgeInput()
        for (value, expected) in [(UInt32(0), UInt32(0)), (65535, 65535)] {
            raw.steering = value
            XCTAssertEqual(w.apply(to: raw).steering, expected)
        }
        raw.steering = 40000 // right of centre: more sensitive moves it further out
        XCTAssertGreaterThan(w.apply(to: raw).steering, 40000)
        raw.steering = 25000
        XCTAssertLessThan(w.apply(to: raw).steering, 25000)
    }

    func testCombinedPedals() {
        var w = WheelSettings(); w.combinedPedals = true
        var raw = BridgeInput() // all released
        XCTAssertEqual(w.apply(to: raw).throttle, 32768, accuracy: 1)
        XCTAssertEqual(w.apply(to: raw).brake, 65535)
        raw.throttle = 0 // accelerator floored
        XCTAssertEqual(w.apply(to: raw).throttle, 0)
        raw.throttle = 65535; raw.brake = 0 // brake floored
        XCTAssertEqual(w.apply(to: raw).throttle, 65535)
    }

    func testCenteringPullsTowardCentre() {
        let w = WheelSettings()
        XCTAssertLessThan(w.centeringForce(position: 0.3, velocity: 0), 0)
        XCTAssertGreaterThan(w.centeringForce(position: -0.3, velocity: 0), 0)
        XCTAssertEqual(w.centeringForce(position: 0, velocity: 0), 0)
        XCTAssertLessThanOrEqual(abs(w.centeringForce(position: 1, velocity: 100)), 1)
    }

    func testDecodesOlderSettingsWithMissingKeys() throws {
        let w = try JSONDecoder().decode(WheelSettings.self, from: Data(#"{"range": 2000, "sensitivity": 70}"#.utf8))
        XCTAssertEqual(w.range, 900) // clamped
        XCTAssertEqual(w.sensitivity, 70)
        XCTAssertTrue(w.revLights)
        let round = try JSONDecoder().decode(WheelSettings.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(round, w)
    }

    func testRevLightsFillAndFlash() {
        var leds = RevLights()
        XCTAssertEqual(leds.mask(rpm: 4000, maxRpm: 8000, now: 0), 0)
        XCTAssertEqual(leds.mask(rpm: 5500, maxRpm: 8000, now: 0), 0b00001)
        XCTAssertEqual(leds.mask(rpm: 7500, maxRpm: 8000, now: 0), 0b11111)
        XCTAssertEqual(leds.mask(rpm: 7900, maxRpm: 8000, now: 0), 0b11111)
        XCTAssertEqual(leds.mask(rpm: 7900, maxRpm: 8000, now: 0.125), 0) // limiter flash
    }

    func testRevLightsStayDarkAtIdleWithoutMaxRpm() {
        var leds = RevLights()
        for _ in 0..<100 { XCTAssertEqual(leds.mask(rpm: 900, maxRpm: 0, now: 0), 0) }
        XCTAssertEqual(leds.mask(rpm: 4000, maxRpm: 0, now: 0), 0)
        XCTAssertEqual(leds.mask(rpm: 6700, maxRpm: 0, now: 0), 0b11111) // 7000 floor
    }

    func testRevLightsLearnMaxWithoutStaticPage() {
        var leds = RevLights()
        _ = leds.mask(rpm: 9000, maxRpm: 0, now: 0)
        XCTAssertEqual(leds.learnedMax, 9000)
        XCTAssertEqual(leds.mask(rpm: 6000, maxRpm: 0, now: 0), 0b00001)
        leds.reset()
        XCTAssertEqual(leds.learnedMax, 0)
    }

    func testCommands() {
        XCTAssertEqual(LogitechWheelCommand.leds(0b10101), [0xf8, 0x12, 0x15, 0, 0, 0, 0])
        XCTAssertEqual(LogitechWheelCommand.range(540), [0xf8, 0x81, 0x1c, 0x02, 0, 0, 0])
        XCTAssertEqual(LogitechWheelCommand.range(5000), [0xf8, 0x81, 0x84, 0x03, 0, 0, 0])
    }
}
