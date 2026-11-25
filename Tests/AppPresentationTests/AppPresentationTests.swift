import XCTest
import AppKit
import WheelCore
@testable import CrossoverFFBApp

final class AppPresentationTests: XCTestCase {
    func testHardwareDisabledRejectsEveryOutputModeBeforeWorkerCreation() {
        for mode: WheelOutputMode in [.appManaged, .sdkInputOnly, .passive] {
            let bridge = FFBBridge(hardwareEnabled: false, outputMode: mode)
            XCTAssertFalse(bridge.start())
            XCTAssertFalse(bridge.status.running)
            XCTAssertEqual(bridge.status.updatedAt, 0)
            bridge.requestCalibration()
            XCTAssertFalse(bridge.start())
            bridge.stop()
        }
        // Metadata-only also avoids a worker even outside demo mode.
        XCTAssertFalse(FFBBridge(hardwareEnabled: true, outputMode: .passive).start())
    }

    func testSDKInputOnlyPublishesIdentityFreshnessAndClearsTelemetryPresentation() async {
        await MainActor.run {
            let model = AppModel(preview: true)
            var sample = BridgeInput()
            sample.connected = true; sample.wheelModel = .g923; sample.steering = 40000
            var status = FFBBridge.Status()
            status.running = true; status.trueForceAvailable = true; status.tfStreaming = true
            status.telemetry = true; status.gameProcessID = 123; status.gameActive = true
            status.effectsPlaying = 5; status.output = 0.8; status.leds = 31
            status.recordSDKInput(sample, rawSteering: 41000, now: 50)
            model.status = status
            XCTAssertEqual(status.wheelModel, .g923); XCTAssertEqual(status.updatedAt, 50)
            XCTAssertEqual(status.input.steering, 40000); XCTAssertEqual(status.rawSteering, 41000)
            XCTAssertEqual(model.presentation.visibleModel, .g923)
            XCTAssertFalse(model.showsTrueForce)
            XCTAssertFalse(status.trueForceAvailable || status.tfStreaming || status.telemetry || status.gameActive)
            XCTAssertEqual(status.gameProcessID, 0); XCTAssertEqual(status.effectsPlaying, 0)
            XCTAssertEqual(status.output, 0); XCTAssertEqual(status.leds, 0)
            status.recordSDKInput(sample, rawSteering: 42000, now: 51)
            XCTAssertEqual(status.updatedAt, 51)
            status.recordDisconnect(message: "Disconnected", now: 52)
            model.status = status
            XCTAssertNil(status.wheelModel); XCTAssertFalse(status.wheelConnected)
            XCTAssertEqual(status.input, BridgeInput()); XCTAssertEqual(status.rawSteering, 32768)
            XCTAssertEqual(status.updatedAt, 52); XCTAssertEqual(status.trueForce, "TrueForce off.")
            XCTAssertFalse(model.presentation.isConnected); XCTAssertFalse(model.showsTrueForce)
            XCTAssertFalse(model.bridge.start())
        }
    }

    func testDemoLaunchFlagCannotDependOnShellArgumentsAlone() {
        XCTAssertTrue(AppRuntime.isDemo(arguments: [], bundleFlag: true))
        XCTAssertTrue(AppRuntime.isDemo(arguments: ["--demo"], bundleFlag: nil))
        XCTAssertFalse(AppRuntime.isDemo(arguments: [], bundleFlag: nil))
        XCTAssertFalse(AppRuntime.isDemo(arguments: [], bundleFlag: false))
    }

    func testInteractiveDemoTransitionsRemainHardwareDisabled() async {
        await MainActor.run {
            let model = AppModel(preview: true)
            model.setPreviewWheel(.g923)
            XCTAssertTrue(model.showsTrueForce)
            model.settingsTab = .trueForce
            model.tfStrength = 37
            model.setPreviewWheel(.g29)
            XCTAssertFalse(model.showsTrueForce)
            XCTAssertEqual(model.settingsTab, .overview)
            model.setPreviewWheel(nil)
            XCTAssertFalse(model.presentation.isConnected)
            model.setPreviewWheel(.g923)
            XCTAssertEqual(model.tfStrength, 37)
            model.bridge.start()
            model.toggleRunning()
            model.scanNow()
            model.rescan()
            model.launchAtLogin = true
            XCTAssertFalse(model.bridge.status.running)
            XCTAssertFalse(model.launchAtLogin)
            XCTAssertTrue(model.games.isEmpty)
        }
    }

    func testExperimentalInventoryDoesNotBecomeGameIdentityOrArtwork() async {
        await MainActor.run {
            for product: UInt16 in [0xc26d, 0xc26e, 0xc276, 0xc272, 0xc268, 0xffff] {
                let metadata = WheelCollection(registryID: 1, physicalID: 2, vendor: 0x046d,
                                               product: product, name: "Unaccepted wheel", usagePage: 1, usage: 4)
                XCTAssertFalse(WheelProfile.resolve([metadata]).defaultOutputAllowed)
                let gameModel = BridgeWheelModel(rawValue: UInt32(product))
                XCTAssertNil(gameModel)
                XCTAssertNil(WheelRimAssets.image(for: gameModel))
            }
        }
    }

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

    func testRimResourceLookupFindsPackagedAppResourcesAndDegradesWithoutCrashing() async throws {
        try await MainActor.run {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("cfb-rim-bundle-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            let app = tmp.appendingPathComponent("crossover-ffb.app")
            let macOS = app.appendingPathComponent("Contents/MacOS")
            let rims = app.appendingPathComponent("Contents/Resources/\(WheelRimAssets.bundleName)/Rims")
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: rims, withIntermediateDirectories: true)
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>CrossoverFFBApp</string>
            <key>CFBundleIdentifier</key><string>local.crossover.ffb.test</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
            let expected = rims.appendingPathComponent("g29-rim.png")
            try Data([0x89, 0x50, 0x4e, 0x47]).write(to: expected)

            let fakeMain = try XCTUnwrap(Bundle(url: app))
            let fakeExe = macOS.appendingPathComponent("CrossoverFFBApp")
            let found = WheelRimAssets.resourceURL(forResource: "g29-rim", withExtension: "png", subdirectory: "Rims",
                                                   main: fakeMain, codeBundle: fakeMain, executableURL: fakeExe)
            XCTAssertEqual(found?.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath())

            // Missing resource bundle falls back to nil (schematic) instead of crashing.
            let emptyApp = tmp.appendingPathComponent("empty.app")
            try fm.createDirectory(at: emptyApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(at: app.appendingPathComponent("Contents/Info.plist"),
                            to: emptyApp.appendingPathComponent("Contents/Info.plist"))
            let emptyMain = try XCTUnwrap(Bundle(url: emptyApp))
            let missing = WheelRimAssets.resourceURL(forResource: "g29-rim", withExtension: "png", subdirectory: "Rims",
                                                     main: emptyMain, codeBundle: emptyMain,
                                                     executableURL: emptyApp.appendingPathComponent("Contents/MacOS/CrossoverFFBApp"))
            XCTAssertNil(missing)
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
