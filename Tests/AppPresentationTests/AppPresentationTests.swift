import XCTest
import WheelCore
@testable import CrossoverFFBApp

final class AppPresentationTests: XCTestCase {
    func testPreviewCannotStartHardwareAndHidingRetainsPreferences() async {
        await MainActor.run {
            let model = AppModel(preview: true)
            XCTAssertTrue(model.isPreview)
            model.bridge.start()
            model.toggleRunning()
            XCTAssertFalse(model.bridge.status.running)
            XCTAssertTrue(model.games.isEmpty)
            model.tfEnabled = false
            model.tfStrength = 37
            model.tfEngine = 22
            model.status.running = true
            model.status.wheelConnected = true
            model.status.wheelModel = .g923
            model.status.trueForceAvailable = true
            XCTAssertTrue(model.showsTrueForce)
            model.status.wheelModel = .g29
            XCTAssertFalse(model.showsTrueForce)
            model.status.wheelConnected = false
            model.status.wheelModel = .g923 // stale model/stream flags
            model.status.tfStreaming = true
            XCTAssertFalse(model.showsTrueForce)
            model.status.wheelConnected = true
            XCTAssertTrue(model.showsTrueForce)
            XCTAssertFalse(model.tfEnabled)
            XCTAssertEqual(model.tfStrength, 37)
            XCTAssertEqual(model.tfEngine, 22)
            model.status.trueForceAvailable = false
            XCTAssertFalse(model.showsTrueForce)
            XCTAssertFalse(model.bridge.status.running)
        }
    }
}
