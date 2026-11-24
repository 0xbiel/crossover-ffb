import XCTest
@testable import WheelCore

final class WheelPresentationTests: XCTestCase {
    func testTrueForceRequiresFreshSupportedConnectedInterface() {
        var state = WheelPresentation(running: true, connected: true, model: .g923, trueForceInterfaceAvailable: true, age: 0)
        XCTAssertTrue(state.showsTrueForce)
        state.model = .g29
        XCTAssertFalse(state.showsTrueForce)
        XCTAssertEqual(state.title, "Logitech G29")
        state.model = nil
        XCTAssertFalse(state.showsTrueForce)
        state.model = .g923
        state.trueForceInterfaceAvailable = false
        XCTAssertFalse(state.showsTrueForce)
        state.trueForceInterfaceAvailable = true
        state.connected = false // stale model/interface flags must not leak controls
        XCTAssertFalse(state.showsTrueForce)
        XCTAssertNil(state.visibleModel)
        state.connected = true
        state.age = 1.01
        XCTAssertFalse(state.showsTrueForce)
        XCTAssertEqual(state.title, "No wheel connected")
        state.age = -0.01
        XCTAssertFalse(state.showsTrueForce)
        state.age = 0
        XCTAssertTrue(state.showsTrueForce) // reconnect without changing preferences
        state.running = false
        XCTAssertFalse(state.showsTrueForce)
    }

    func testUnsupportedWheelIsNamedButNeverConnected() {
        var state = WheelPresentation(running: true, connected: false, model: nil, trueForceInterfaceAvailable: true, age: 0, detected: .rs50)
        XCTAssertEqual(state.unsupportedModel, .rs50)
        XCTAssertEqual(state.title, "Logitech RS50")
        XCTAssertFalse(state.isConnected)
        XCTAssertFalse(state.showsTrueForce)
        XCTAssertNil(state.visibleModel)
        state.detected = .ambiguousC272
        XCTAssertEqual(state.title, "Logitech RS50 or G PRO")
        state.detected = .g923PS // supported models are never shown as unsupported
        XCTAssertNil(state.unsupportedModel)
        state.detected = .gProPS
        state.age = 1.01
        XCTAssertNil(state.unsupportedModel)
        state.age = 0; state.running = false
        XCTAssertNil(state.unsupportedModel)
        state.running = true; state.connected = true; state.model = .g29
        XCTAssertNil(state.unsupportedModel) // a driven wheel takes precedence
        XCTAssertEqual(state.title, "Logitech G29")
    }

    func testRimAngleKeepsCentreAndRange() {
        XCTAssertEqual(WheelPresentation.angle(steering: 0, range: 900), -450)
        XCTAssertEqual(WheelPresentation.angle(steering: 65535, range: 900), 450)
        XCTAssertEqual(WheelPresentation.angle(steering: 32768, range: 900), 0, accuracy: 0.01)
        XCTAssertEqual(WheelPresentation.angle(steering: 65535, range: 360), 180)
    }
}
