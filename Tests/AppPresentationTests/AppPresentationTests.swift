import XCTest
import AppKit
import WheelCore
@testable import CrossoverFFBApp

final class AppPresentationTests: XCTestCase {
    func testModelRimResourcesHaveTransparencyAndPaddles() async throws {
        try await MainActor.run {
            XCTAssertNil(WheelRimAssets.image(for: nil))
            for model in [BridgeWheelModel.g29, .g923] {
                let image = try XCTUnwrap(WheelRimAssets.image(for: model))
                let bytes = try XCTUnwrap(image.tiffRepresentation)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
                XCTAssertEqual(bitmap.pixelsWide, 1254)
                XCTAssertEqual(bitmap.pixelsHigh, 1254)
                XCTAssertTrue(bitmap.hasAlpha)
                for (x, y) in [(0, 0), (1253, 0), (0, 1253), (1253, 1253), (627, 300), (420, 1000), (840, 1000)] {
                    XCTAssertEqual(bitmap.colorAt(x: x, y: y)?.alphaComponent, 0, "Background and wheel openings must be transparent")
                }
                for (x, y) in [(627, 640), (280, 470), (975, 470)] {
                    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.alphaComponent), 0.9, "Keep the hub and both paddles")
                }
            }
        }
    }

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
