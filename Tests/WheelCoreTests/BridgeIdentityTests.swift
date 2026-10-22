import Foundation
import XCTest
@testable import WheelCore

final class BridgeIdentityTests: XCTestCase {
    func testIdentityPublicationAndReconnect() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cfb-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ffb-v2.bin").path
        let bridge = try SharedBridge(path: path)
        func words() throws -> [UInt32] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            return stride(from: 0, to: 112, by: 4).map { offset in
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
            }
        }
        var input = BridgeInput()
        bridge.publish(input, unixMilliseconds: 100)
        var raw = try words()
        XCTAssertEqual(raw[0], SharedBridge.magic)
        XCTAssertEqual(raw[1], 2) // additive v2 extension; no layout/version break
        XCTAssertEqual(raw[17], 0)
        XCTAssertEqual(raw[26], 0)
        var sequence = raw[16]
        for (model, identity) in [(BridgeWheelModel.g29, UInt32(0xc24f046d)), (.g923, 0xc266046d), (.g29, 0xc24f046d)] {
            input.connected = true
            input.wheelModel = model
            input.steering = 1234
            let processed = WheelSettings().apply(to: input)
            XCTAssertEqual(processed.wheelModel, model)
            bridge.publish(processed, unixMilliseconds: 200)
            raw = try words()
            XCTAssertEqual(raw[17], 3) // still nonzero for old DLLs; bit 1 validates +40
            XCTAssertEqual(raw[26], identity)
            XCTAssertEqual(raw[18], 200)
            XCTAssertEqual(raw[16] & 1, 0)
            XCTAssertGreaterThan(raw[16], sequence)
            sequence = raw[16]
            bridge.publish(BridgeInput(), unixMilliseconds: 300)
            raw = try words()
            XCTAssertEqual(raw[17], 0)
            XCTAssertEqual(raw[26], 0)
        }
        // A restart reuses the file; its first disconnected publication clears the extension.
        let restarted = try SharedBridge(path: path)
        restarted.publish(BridgeInput(), unixMilliseconds: 400)
        raw = try words()
        XCTAssertEqual(raw[17], 0)
        XCTAssertEqual(raw[26], 0)
        XCTAssertGreaterThan(raw[16], sequence)
    }

    func testOnlySupportedUSBModels() {
        XCTAssertEqual(BridgeWheelModel(rawValue: 0xc24f), .g29)
        XCTAssertEqual(BridgeWheelModel(rawValue: 0xc266), .g923)
        for product: UInt32 in [0, 0xc26d, 0xc26e, 0xc262, 0xc260] {
            XCTAssertNil(BridgeWheelModel(rawValue: product))
        }
    }
}
