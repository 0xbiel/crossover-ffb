import Foundation
import XCTest
@testable import WheelCore

final class CompletionAuditTests: XCTestCase {
    func testPublishedEffectWireFixtures() {
        let envelope = HIDPPForceEffect.Envelope(attackLevel: 3, attackMilliseconds: 0x1234, fadeLevel: 5, fadeMilliseconds: 0x5678)
        XCTAssertEqual(HIDPPForceEffect.constant(level: -2, envelope: envelope).payload(durationMilliseconds: 0x102, delayMilliseconds: 0x304),
                       [0, 0, 1, 2, 3, 4, 255, 254, 3, 0x12, 0x34, 5, 0x56, 0x78])
        XCTAssertEqual(HIDPPForceEffect.ramp(start: .min, end: .max, envelope: .init()).payload(slot: 4, durationMilliseconds: 20),
                       [4, 10, 0, 20, 0, 0, 128, 0, 127, 255, 0, 0, 0, 0, 0, 0])
        let periodic = HIDPPForceEffect.periodic(wave: .sine, magnitude: 0x102, offset: -1, period: 0x304, phase: 0x506, envelope: .init())
        XCTAssertEqual(periodic.payload(durationMilliseconds: 0), [0, 1, 0, 0, 0, 0, 1, 2, 255, 255, 3, 4, 5, 6, 0, 0, 0, 0, 0, 0])
        let condition = HIDPPForceEffect.condition(kind: .damper, leftSaturation: 1, leftCoefficient: -2, deadband: 3, center: -4, rightCoefficient: 5, rightSaturation: 6)
        XCTAssertEqual(condition.payload(durationMilliseconds: 7), [0, 7, 0, 7, 0, 0, 0, 1, 255, 254, 0, 3, 255, 252, 0, 5, 0, 6])
    }
    // Mock transport echoes the exact request correlation header, not the requested effect state.
    func reply(to request: [UInt8], firstParameter: UInt8 = 0) -> [UInt8] {
        Array(request.prefix(4)) + [firstParameter] + Array(repeating: 0, count: request.count - 5)
    }
    func configured() throws -> HIDPPForceSession {
        var session = HIDPPForceSession()
        let discovery = try session.begin(.discover, now: 0)
        XCTAssertEqual(Array(discovery.prefix(6)), [0x11, 255, 0, 1, 0x81, 0x23])
        XCTAssertTrue(try session.receive(reply(to: discovery, firstParameter: 9), now: 0.1))
        let info = try session.begin(.getInfo, now: 1)
        XCTAssertTrue(try session.receive(reply(to: info, firstParameter: 5), now: 1.1))
        XCTAssertEqual(session.usableSlots, 4)
        return session
    }
    func testWireLifecycleThroughMockTransport() throws {
        var session = try configured()
        let effect = HIDPPForceEffect.constant(level: -100, envelope: .init())
        let download = try session.begin(.download(slot: 0, effect: effect, duration: 500, delay: 0), now: 2)
        XCTAssertEqual(download.count, 20)
        XCTAssertEqual(Array(download.prefix(6)), [0x11, 255, 9, 0x23, 0, 0])
        XCTAssertThrowsError(try session.begin(.getInfo, now: 2))
        var unrelated = reply(to: download, firstParameter: 2); unrelated[3] = 0x24
        XCTAssertFalse(try session.receive(unrelated, now: 2.1))
        XCTAssertTrue(session.slots.isEmpty)
        XCTAssertTrue(try session.receive(reply(to: download, firstParameter: 2), now: 2.1))
        let play = try session.begin(.play(2), now: 3)
        XCTAssertEqual(Array(play.prefix(6)), [0x11, 255, 9, 0x34, 2, 2])
        XCTAssertTrue(try session.receive(reply(to: play), now: 3.1)); XCTAssertEqual(session.slots[2], .playing)
        XCTAssertThrowsError(try session.begin(.download(slot: 2, effect: effect, duration: 10, delay: 0), now: 3.2))
        let stop = try session.begin(.stop(2), now: 4)
        XCTAssertEqual(stop[5], 1)
        XCTAssertTrue(try session.receive(reply(to: stop), now: 4.1)); XCTAssertEqual(session.slots[2], .stopped)
        let erase = try session.begin(.erase(2), now: 5)
        XCTAssertEqual(erase[3], 0x46)
        XCTAssertTrue(try session.receive(reply(to: erase), now: 5.1)); XCTAssertTrue(session.slots.isEmpty)
        let periodic = HIDPPForceEffect.periodic(wave: .square, magnitude: 1, offset: 0, period: 10, phase: 0, envelope: .init())
        let large = try session.begin(.download(slot: 0, effect: periodic, duration: 100, delay: 0), now: 6)
        XCTAssertEqual(large[0], 0x12); XCTAssertEqual(large.count, 64)
        XCTAssertThrowsError(try session.poll(now: 6.25))
        XCTAssertThrowsError(try session.receive(reply(to: large, firstParameter: 1), now: 7))
        XCTAssertTrue(session.slots.isEmpty)
    }
    @MainActor
    func testWireActorRejectsOverlappingRequests() async throws {
        let session = XboxWireSession()
        let request = try await session.begin(.discover, now: 0)
        do { _ = try await session.begin(.discover, now: 0); XCTFail("overlap") }
        catch { XCTAssertEqual(error as? WheelProtocolError, .busy) }
        let accepted = try await session.receive(reply(to: request, firstParameter: 8), now: 0.1)
        XCTAssertTrue(accepted)
        await session.disconnect()
        do { _ = try await session.begin(.getInfo, now: 1); XCTFail("disconnect") }
        catch { XCTAssertEqual(error as? WheelProtocolError, .disconnected) }
    }
    func testWireErrorsAndInvalidSlotPoisonSession() throws {
        var session = try configured()
        let request = try session.begin(.download(slot: 0, effect: .constant(level: 0, envelope: .init()), duration: 1, delay: 0), now: 2)
        XCTAssertThrowsError(try session.receive(reply(to: request, firstParameter: 5), now: 2.1))
        XCTAssertNil(session.featureIndex)
        session = try configured()
        let info = try session.begin(.getInfo, now: 2)
        XCTAssertThrowsError(try session.receive([0x10, 255, 255, info[2], info[3], 7, 0], now: 2.1)) {
            XCTAssertEqual($0 as? WheelProtocolError, .device(7))
        }
    }
    func testInventoryExportHasOnlyMetadataCapability() throws {
        final class Spy: WheelMetadataSource {
            var reads = 0, opens = 0, getReports = 0, outputs = 0
            func readCachedMetadata() -> [WheelCollection] {
                reads += 1
                return [WheelCollection(registryID: 2, physicalID: 10, vendor: 0x046d, product: 0xc26e,
                                        name: "Synthetic Xbox", usagePage: 1, usage: 4, reportDescriptor: Data([5, 1, 9, 4]))]
            }
            func open() { opens += 1 }
            func getReport() { getReports += 1 }
            func setReport() { outputs += 1 }
        }
        let spy = Spy()
        let export = try WheelInventoryExport.capture(from: spy)
        XCTAssertEqual(spy.reads, 1); XCTAssertEqual(spy.opens + spy.getReports + spy.outputs, 0)
        XCTAssertEqual(export.collections[0].reportDescriptor, Data([5, 1, 9, 4]))
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try export.save(to: file)
        XCTAssertEqual(try JSONDecoder().decode(WheelInventoryExport.self, from: Data(contentsOf: file)), export)
        XCTAssertThrowsError(try export.save(to: file))
        XCTAssertEqual(spy.opens + spy.getReports + spy.outputs, 0)
    }
    func testArtifactAuditDoesNotTrustHashesAsSignatures() {
        var pe = Data(repeating: 0, count: 200)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64
        pe[64] = 0x50; pe[65] = 0x45; pe[68] = 0x64; pe[69] = 0x86
        pe[84] = 112; pe[87] = 0x20; pe[88] = 0x0b; pe[89] = 2
        let wine = Data("synthetic transport".utf8)
        let good = SDKArtifactAudit.inspect(sdk: pe, transport: wine, expectedSDKHash: SDKArtifactAudit.hash(pe), expectedTransportHash: SDKArtifactAudit.hash(wine))
        XCTAssertTrue(good.sdkIsX64DLL); XCTAssertTrue(good.hashesMatch)
        XCTAssertFalse(SDKPreflight().blockers.isEmpty)
        pe[69] = 0
        let bad = SDKArtifactAudit.inspect(sdk: pe, transport: wine, expectedSDKHash: good.sdkSHA256, expectedTransportHash: good.transportSHA256)
        XCTAssertFalse(bad.sdkIsX64DLL); XCTAssertFalse(bad.hashesMatch)
        var preflight = SDKPreflight(); preflight.originalSDKSignatureVerified = true
        preflight.applyArtifactAudit(bad)
        XCTAssertFalse(preflight.originalSDKSignatureVerified); XCTAssertFalse(preflight.transportHashVerified)
        preflight.applyArtifactAudit(good)
        XCTAssertTrue(preflight.transportHashVerified); XCTAssertFalse(preflight.originalSDKSignatureVerified)
        for count in 0..<64 {
            XCTAssertFalse(SDKArtifactAudit.inspect(sdk: Data(repeating: 0, count: count), transport: wine, expectedSDKHash: "", expectedTransportHash: "").sdkIsX64DLL)
        }
    }
    final class ProcessMock: SDKProcessControl {
        var isRunning = false, launches = 0, terminations = 0, kills = 0
        var failAfterSpawn = false
        func launch(plan: NativeSDKSetupPlan) throws {
            launches += 1; isRunning = true
            if failAfterSpawn { throw SessionError.invalidTransition }
        }
        func requestTermination() { terminations += 1 }
        func requestKill() { kills += 1 }
    }
    final class LeaseMock: SDKSessionLease { var releases = 0; func releaseAfterConfirmedExit() { releases += 1 } }
    func preflightFixture() -> SDKPreflight {
        var p = SDKPreflight()
        p.model = .g923PS; p.explicitOptIn = true; p.originalSDKSignatureVerified = true; p.sdkVersion = "1.3.12"
        p.crossoverVersion = "27.0.0.41069"; p.transportContract = SDKPreflight.transportContract
        p.transportHashVerified = true; p.physicalContainerVerified = true; p.physicalPathVerified = true
        p.inputOnlyLeaseHeld = true; p.competingWritersStopped = true; p.hardwareAcceptanceRecorded = true
        return p
    }
    func testFailedLaunchAndDisconnectRetainOwnership() throws {
        let process = ProcessMock(), lease = LeaseMock()
        process.failAfterSpawn = true
        let coordinator = SDKSessionCoordinator(process: process, lease: lease)
        let plan = NativeSDKSetupPlan(sdkPath: "never loaded", transportPath: "never executed")
        XCTAssertThrowsError(try coordinator.start(plan: plan, preflight: preflightFixture(), now: 0))
        XCTAssertEqual(process.terminations, 1); XCTAssertEqual(lease.releases, 0)
        coordinator.disconnected(now: 0.1)
        XCTAssertEqual(process.terminations, 1)
        process.isRunning = false; coordinator.tick(now: 0.2)
        XCTAssertEqual(lease.releases, 1)
    }
    func testStartupReadinessDeadlineUsesStopPath() throws {
        let process = ProcessMock(), lease = LeaseMock()
        let coordinator = SDKSessionCoordinator(process: process, lease: lease)
        _ = try coordinator.start(plan: NativeSDKSetupPlan(sdkPath: "never loaded", transportPath: "never executed"), preflight: preflightFixture(), now: 0)
        coordinator.tick(now: 2)
        XCTAssertEqual(process.terminations, 1); XCTAssertEqual(lease.releases, 0)
        coordinator.tick(now: 2.5)
        XCTAssertEqual(process.kills, 1)
        process.isRunning = false; coordinator.tick(now: 3)
        XCTAssertEqual(lease.releases, 1)
    }
    func testSupervisorKeepsLeaseUntilMockProcessExit() throws {
        let process = ProcessMock(), lease = LeaseMock()
        let coordinator = SDKSessionCoordinator(process: process, lease: lease)
        var p = SDKPreflight()
        let plan = NativeSDKSetupPlan(sdkPath: "unexecuted", transportPath: "unexecuted")
        XCTAssertThrowsError(try coordinator.start(plan: plan, preflight: p, now: 0))
        XCTAssertEqual(process.launches, 0)
        p.model = .g923PS; p.explicitOptIn = true; p.originalSDKSignatureVerified = true; p.sdkVersion = "1.3.12"
        p.crossoverVersion = "27.0.0.41069"; p.transportContract = SDKPreflight.transportContract
        p.transportHashVerified = true; p.physicalContainerVerified = true; p.physicalPathVerified = true
        p.inputOnlyLeaseHeld = true; p.competingWritersStopped = true; p.hardwareAcceptanceRecorded = true
        let epoch = try coordinator.start(plan: plan, preflight: p, now: 1)
        try coordinator.ready(epoch: epoch, now: 1.1)
        coordinator.tick(now: 1.7)
        XCTAssertEqual(process.terminations, 1); XCTAssertEqual(lease.releases, 0)
        coordinator.tick(now: 2.3)
        XCTAssertEqual(process.kills, 1); XCTAssertTrue(coordinator.leaseHeld)
        coordinator.tick(now: 5)
        XCTAssertEqual(process.kills, 1); XCTAssertEqual(lease.releases, 0)
        process.isRunning = false; coordinator.tick(now: 6)
        XCTAssertEqual(lease.releases, 1); XCTAssertFalse(coordinator.leaseHeld)
        coordinator.tick(now: 7); XCTAssertEqual(lease.releases, 1)
    }
}
