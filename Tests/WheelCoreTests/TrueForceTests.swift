import XCTest
@testable import WheelCore

final class TrueForceTests: XCTestCase {
    func testInitPassMatchesCapturedSequence() {
        let pass = TrueForceProtocol.initPass()
        XCTAssertEqual(pass.count, 68)
        XCTAssertTrue(pass.allSatisfy { $0.count == 64 && $0[0] == 1 && $0[1...3].allSatisfy { $0 == 0 } })
        XCTAssertEqual(pass.map { $0[5] }, (1...68).map(UInt8.init))
        let queries = pass.prefix(48)
        XCTAssertTrue(queries.allSatisfy { $0[4] == 0x05 && $0[7...].allSatisfy { $0 == 0 } })
        XCTAssertEqual(queries.prefix(3).map { $0[6] }, [0x00, 0x30, 0x01])
        XCTAssertEqual(queries.last?[6], 0x3c)
        XCTAssertEqual(Set(queries.map { $0[6] }).count, 48)
        XCTAssertEqual(pass[48][4], 0x01); XCTAssertEqual(Array(pass[48][6...9]), [0, 0x80, 0, 0x80])
        XCTAssertEqual(Array(pass[49][4...9]), [0x0e, 50, 0x00, 0xc0, 0x28, 0x45])
        XCTAssertEqual(pass[51][4], 0x07)
        XCTAssertEqual(Array(pass[53][4...8]), [0x06, 54, 0x01, 0x01, 0x00])
        XCTAssertEqual(Array(pass[59][4...15]), [0x09, 60, 0x02, 0x02, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0xaf, 0x43])
        XCTAssertEqual(Array(pass[65][4...8]), [0x06, 66, 0x01, 0x06, 0x01])
        XCTAssertEqual(pass[66][4], 0x04); XCTAssertEqual(pass[67][4], 0x03)
        let neutrals = [48, 50, 52, 54, 56, 58, 60, 62, 64]
        XCTAssertTrue(neutrals.allSatisfy { pass[$0][4] == 0x01 })
    }

    func testStreamPacketCarriesTorqueAndRollingWindow() {
        var s = TrueForceStreamer()
        let a = s.packet(torque: 1, samples: [0, 1, -1, 0.5])
        XCTAssertEqual(a[4], 0x01); XCTAssertEqual(a[5], 1)
        XCTAssertEqual(Array(a[6...11]), [0xff, 0xff, 0xff, 0xff, 4, 0x0d])
        func slot(_ p: [UInt8], _ i: Int) -> UInt16 {
            let o = 12 + 4 * i
            XCTAssertEqual(p[o], p[o + 2]); XCTAssertEqual(p[o + 1], p[o + 3])
            return UInt16(p[o]) | UInt16(p[o + 1]) << 8
        }
        XCTAssertEqual((0..<13).map { slot(a, $0) }, [UInt16](repeating: 0x8000, count: 9) + [0x8000, 0xffff, 0x0001, 0xc000])
        let b = s.packet(torque: -1, samples: [])
        XCTAssertEqual(b[5], 2)
        XCTAssertEqual(Array(b[6...11]), [0x01, 0x00, 0x01, 0x00, 0, 0x00])
        let c = s.packet(torque: 0, samples: [Double](repeating: 1, count: 20))
        XCTAssertEqual(c[10], 12)
        XCTAssertEqual(slot(c, 0), 0xc000)
        XCTAssertEqual(Array(c[6...9]), [0x00, 0x80, 0x00, 0x80])
    }

    func testACPhysicsParsing() {
        var b = [UInt8](repeating: 0, count: 800)
        func put(_ i: Int, _ v: UInt32) { for k in 0..<4 { b[4 * i + k] = UInt8(v >> (8 * k) & 0xff) } }
        put(0, 77); put(1, Float(0.75).bitPattern); put(5, 6500); put(7, Float(180).bitPattern)
        put(46, Float(0.05).bitPattern); put(195, 1); put(196, Float(0.4).bitPattern); put(199, Float(1).bitPattern)
        let t = GameTelemetry.acPhysics(b)!
        XCTAssertEqual(t.packet, 77); XCTAssertEqual(t.gas, 0.75); XCTAssertEqual(t.rpm, 6500); XCTAssertEqual(t.speedKmh, 180)
        XCTAssertEqual(t.suspension[0], 0.05, accuracy: 1e-6); XCTAssertTrue(t.engineRunning)
        XCTAssertEqual(t.kerb, 0.4, accuracy: 1e-6); XCTAssertEqual(t.abs, 1)
        XCTAssertNil(GameTelemetry.acPhysics([0]))
        put(198, Float(0.3).bitPattern)
        XCTAssertEqual(GameTelemetry.acPhysics(b)!.g, 0.3, accuracy: 1e-6)
        let evo = GameTelemetry.acPhysics(b, evo: true)!
        XCTAssertEqual(evo.road, 0.3, accuracy: 1e-6); XCTAssertEqual(evo.g, 0); XCTAssertEqual(evo.rpm, 6500)
    }

    func testSynthIsSilentWithoutTelemetryAndBoundedWithIt() {
        let synth = HapticSynth()
        synth.update(nil, now: 0)
        XCTAssertTrue(synth.render(count: 400).allSatisfy { $0 == 0 })
        var t = GameTelemetry(); t.rpm = 7000; t.gas = 1; t.kerb = 1; t.abs = 1; t.slip = 1; t.g = 1; t.speedKmh = 200
        var now = 0.0, peak = 0.0
        for frame in 1...400 { // 400 frames at 333 Hz
            t.packet = Int32(frame); now += 0.003
            synth.update(t, now: now)
            let out = synth.render(count: 12)
            XCTAssertTrue(out.allSatisfy { abs($0) <= 1 && $0.isFinite })
            peak = max(peak, out.map(abs).max()!)
        }
        XCTAssertGreaterThan(peak, 0.3)
        // Telemetry freezes (pause): the signal fades away.
        for _ in 0..<400 { now += 0.003; synth.update(t, now: now); _ = synth.render(count: 12) }
        XCTAssertLessThan(synth.render(count: 12).map(abs).max()!, 0.01)
    }
}
