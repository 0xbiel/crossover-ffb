import XCTest
@testable import WheelCore

final class EffectEngineTests: XCTestCase {
    private func state(_ effects: [BridgeEffect], gain: UInt32 = 10000) -> BridgeForceState {
        var s = BridgeForceState()
        s.processID = 1; s.acquired = true; s.deviceGain = gain; s.effects = effects
        return s
    }

    func testConstantForceFollowsMagnitudeDirectionAndGain() {
        let engine = EffectEngine()
        let e = BridgeEffect(slot: 0, kind: .constant, gain: 5000, params: [8000])
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 1), 0.4, accuracy: 1e-9)
        var left = e; left.direction = (-1, 0)
        XCTAssertEqual(engine.force(state([left]), wheel: .init(), now: 1), -0.4, accuracy: 1e-9)
        XCTAssertEqual(engine.force(state([e], gain: 5000), wheel: .init(), now: 1), 0.2, accuracy: 1e-9)
        engine.reverseDirectional = true
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 1), -0.4, accuracy: 1e-9)
    }

    func testPolarEastIsPositiveX() {
        let e = BridgeEffect(slot: 0, kind: .constant, coordinates: 0x20, axisCount: 2, direction: (9000, 0), params: [10000])
        XCTAssertEqual(EffectEngine().force(state([e]), wheel: .init(), now: 0), 1, accuracy: 1e-6)
    }

    func testFiniteDurationEndsAndRestartsOnNewStart() {
        let engine = EffectEngine()
        var e = BridgeEffect(slot: 0, kind: .constant, durationMicros: 100_000, params: [10000])
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 10), 1)
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 10.05), 1)
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 10.2), 0)
        e.starts = 2
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 10.3), 1)
    }

    func testSpringAndDamperResistMotion() {
        let engine = EffectEngine()
        let spring = BridgeEffect(slot: 0, kind: .spring, params: [0, 10000, 10000, 10000, 10000, 0])
        XCTAssertEqual(engine.force(state([spring]), wheel: .init(position: 0.5), now: 0), -0.5, accuracy: 1e-9)
        XCTAssertEqual(engine.force(state([spring]), wheel: .init(position: -0.25), now: 0), 0.25, accuracy: 1e-9)
        let damper = BridgeEffect(slot: 1, kind: .damper, params: [0, 5000, 5000, 10000, 10000, 0])
        XCTAssertLessThan(engine.force(state([damper]), wheel: .init(velocity: 1), now: 0), 0)
        XCTAssertGreaterThan(engine.force(state([damper]), wheel: .init(velocity: -1), now: 0), 0)
        // Reversing game direction must not turn a damper into an accelerator.
        engine.reverseDirectional = true
        XCTAssertLessThan(engine.force(state([damper]), wheel: .init(velocity: 1), now: 0), 0)
    }

    func testSineOscillatesAroundOffset() {
        let engine = EffectEngine()
        let e = BridgeEffect(slot: 0, kind: .sine, params: [5000, 1000, 0, 100_000])
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 0), 0.1, accuracy: 1e-6)
        XCTAssertEqual(engine.force(state([e]), wheel: .init(), now: 0.025), 0.6, accuracy: 1e-6)
    }

    func testSharedMemoryRoundTrip() throws {
        let path = NSTemporaryDirectory() + "cfb-test-\(UUID().uuidString)/ffb-v2.bin"
        let bridge = try SharedBridge(path: path)
        var input = BridgeInput(); input.connected = true; input.steering = 1234; input.hat = 2
        bridge.publish(input, unixMilliseconds: 99)
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(raw.count, 8192)
        XCTAssertEqual(raw[0..<4], Data("CFB2".utf8))
        XCTAssertEqual(raw[64] & 1, 0)
        XCTAssertEqual(raw[80], 0xd2); XCTAssertEqual(raw[81], 0x04)
        XCTAssertEqual(bridge.readForce()?.effects.count, 0)
        XCTAssertNil(bridge.readTelemetry())
        // The DLL's telemetry block: seq, source 1, length, unix ms, then the raw page.
        var block = [UInt8](repeating: 0, count: 32 + 800)
        func put(_ o: Int, _ v: UInt32) { for k in 0..<4 { block[o + k] = UInt8(v >> (8 * k) & 0xff) } }
        put(0, 2); put(4, 1); put(8, 800); put(16, 1234); put(32, 42)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.seek(toOffset: 4096); file.write(Data(block)); try file.close()
        let telemetry = try XCTUnwrap(bridge.readTelemetry())
        XCTAssertEqual(telemetry.source, 1); XCTAssertEqual(telemetry.unixMilliseconds, 1234)
        XCTAssertEqual(GameTelemetry.acPhysics(telemetry.bytes)?.packet, 42)
    }

    func testDecodeEffectRecord() {
        var b = [UInt8](repeating: 0, count: 64 + 96 * 32)
        func put(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put(4, 77); put(16, 1); put(20, 6000)
        let r = 64 + 96
        put(r, 1); put(r + 4, 1); put(r + 8, 3); put(r + 12, .max); put(r + 20, 10000); put(r + 64, UInt32(bitPattern: -2500)); put(r + 88, 1)
        let s = SharedBridge.decode(b)
        XCTAssertEqual(s.processID, 77)
        XCTAssertEqual(s.deviceGain, 6000)
        XCTAssertEqual(s.effects.count, 1)
        XCTAssertEqual(s.effects[0].slot, 1)
        XCTAssertEqual(s.effects[0].params[0], -2500)
        XCTAssertEqual(s.effects[0].starts, 3)
    }

    func testLogitechConstantCodes() {
        XCTAssertEqual(LogitechWheelCommand.constant(0)[2], 0x80)
        XCTAssertEqual(LogitechWheelCommand.constant(1)[2], 255)
        XCTAssertEqual(LogitechWheelCommand.constant(-1)[2], 1)
        XCTAssertEqual(LogitechWheelCommand.constant(0.5, length: 16).count, 16)
        XCTAssertEqual(LogitechWheelCommand.range(900), [0xf8, 0x81, 0x84, 0x03, 0, 0, 0])
    }
}
