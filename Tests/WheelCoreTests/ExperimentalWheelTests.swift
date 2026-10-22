import Foundation
import XCTest
@testable import WheelCore

final class ExperimentalWheelTests: XCTestCase {
    func collection(_ pid: UInt16, parent: UInt64? = 10, id: UInt64 = 1, page: UInt32 = 1, usage: UInt32 = 4) -> WheelCollection {
        WheelCollection(registryID: id, physicalID: parent, vendor: 0x046d, product: pid, name: "G PRO", usagePage: page, usage: usage)
    }
    func testGroupingDoesNotMixIdenticalWheelsOrGuessMissingParents() {
        let groups = WheelInventory.groups([collection(0xc266), collection(0xc266, parent: 20), collection(0xc266, parent: nil), collection(0xc266, parent: nil, id: 2)])
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(WheelProfile.resolve([collection(0xc266, parent: nil)]).model, .unknown)
        XCTAssertEqual(WheelProfile.resolve([collection(0xc266), collection(0xc266, parent: 20)]).model, .unknown)
    }
    func testProfilesAndNoOutputDefaults() {
        for pid: UInt16 in [0xc26d, 0xc26e, 0xc276, 0xc272, 0xc268, 0xffff] {
            XCTAssertFalse(WheelProfile.resolve([collection(pid)]).defaultOutputAllowed)
        }
        XCTAssertEqual(WheelProfile.resolve([collection(0xc272)]).model, .ambiguousC272)
        XCTAssertEqual(WheelProfile.resolve([collection(0xc26d)]).backend, .readOnly)
        XCTAssertEqual(WheelProfile.resolve([collection(0xc26e)]).backend, .xboxHIDPP)
        XCTAssertTrue(WheelProfile.resolve([collection(0xc24f)]).defaultOutputAllowed)
        XCTAssertTrue(WheelProfile.resolve([collection(0xc266)]).defaultOutputAllowed)
        let ps = [collection(0xc266), collection(0xc266, id: 2, page: 0xfffd, usage: 0xfd01)]
        XCTAssertTrue(WheelProfile.resolve(ps).supportsNativeSDKCandidate)
        XCTAssertFalse(WheelProfile.resolve(ps + [ps[1]]).supportsNativeSDKCandidate)
        XCTAssertFalse(WheelProfile.resolve([collection(0xc266), collection(0xc266, id: 2)]).hasInput)
        XCTAssertEqual(WheelModel.rs50.ratedTorqueNm, 8)
        XCTAssertEqual(WheelModel.gProXbox.ratedTorqueNm, 11)
    }
    func testPedalsAreSeparateLayouts() {
        var ps = BridgeInput(), xbox = BridgeInput()
        for (usage, raw) in [(0x31, 10), (0x32, 20), (0x35, 30)] {
            let sample = InputSample(page: 1, usage: UInt32(usage), raw: raw, minimum: 0, maximum: 65535)
            WheelInputDecoder.apply(sample, model: .g923PS, to: &ps)
            WheelInputDecoder.apply(sample, model: .g923XboxPC, to: &xbox)
        }
        XCTAssertEqual([ps.throttle, ps.brake, ps.clutch], [20, 30, 10])
        XCTAssertEqual([xbox.throttle, xbox.brake, xbox.clutch], [10, 20, 30])
        var unknown = BridgeInput()
        let before = unknown
        WheelInputDecoder.apply(InputSample(page: 1, usage: 0x30, raw: 9, minimum: 0, maximum: 10), model: .unknown, to: &unknown)
        XCTAssertEqual(unknown, before)
    }
    func testFeatureDiscoverySerializesAndCorrelates() throws {
        var discovery = HIDPPDiscovery()
        let request = try discovery.begin(now: 10)
        XCTAssertEqual(Array(request.prefix(6)), [0x11, 0xff, 0, 1, 0x81, 0x23])
        XCTAssertEqual(request.count, 20)
        XCTAssertThrowsError(try discovery.begin(now: 10))
        var reply = [UInt8](repeating: 0, count: 20)
        reply[0] = 0x11; reply[1] = 0xff; reply[3] = 2; reply[4] = 0x17
        XCTAssertFalse(try discovery.receive(reply, now: 10.1))
        reply[3] = 1
        XCTAssertTrue(try discovery.receive(reply, now: 10.1))
        XCTAssertEqual(discovery.forceFeatureIndex, 0x17)
        XCTAssertFalse(try discovery.receive(reply, now: 10.1))
        let second = try discovery.begin(now: 11)
        XCTAssertEqual(second[3], 2)
        XCTAssertThrowsError(try discovery.poll(now: 11.25))
        XCTAssertNil(discovery.forceFeatureIndex)
        XCTAssertThrowsError(try discovery.receive(reply, now: 12))
        XCTAssertThrowsError(try discovery.begin(now: 12))
    }
    func testProtocolMalformedUnsupportedErrorAndDisconnect() throws {
        for length in [0, 1, 6, 8, 19, 21, 63, 65] {
            XCTAssertThrowsError(try HIDPPMessage(report: Array(repeating: 0x11, count: length)))
        }
        var discovery = HIDPPDiscovery()
        _ = try discovery.begin(now: 1)
        let error: [UInt8] = [0x10, 0xff, 0xff, 0, 1, 9, 0]
        XCTAssertThrowsError(try discovery.receive(error, now: 1.1)) { XCTAssertEqual($0 as? WheelProtocolError, .device(9)) }
        var absent = HIDPPDiscovery()
        _ = try absent.begin(now: 1)
        XCTAssertThrowsError(try absent.receive([0x10, 0xff, 0, 1, 0, 0, 0], now: 1.1))
        absent.disconnect()
        XCTAssertThrowsError(try absent.begin(now: 2))
    }
    func testEffectLifecycleAndFaultInvalidation() throws {
        var effects = HIDPPEffectLifecycle()
        XCTAssertThrowsError(try effects.begin(.start(1), now: 0))
        try effects.begin(.allocate, now: 0)
        XCTAssertThrowsError(try effects.begin(.allocate, now: 0))
        try effects.acknowledge(allocatedSlot: 3, now: 0.1)
        try effects.begin(.start(3), now: 1)
        try effects.acknowledge(now: 1.1)
        XCTAssertEqual(effects.slots[3], .playing)
        try effects.begin(.stop(3), now: 2)
        try effects.acknowledge(now: 2.1)
        XCTAssertEqual(effects.slots[3], .stopped)
        try effects.begin(.erase(3), now: 3)
        try effects.acknowledge(now: 3.1)
        XCTAssertTrue(effects.slots.isEmpty)
        try effects.begin(.allocate, now: 4)
        XCTAssertThrowsError(try effects.poll(now: 4.25))
        XCTAssertThrowsError(try effects.acknowledge(allocatedSlot: 2, now: 5))
        XCTAssertTrue(effects.slots.isEmpty)
    }
    func testDirectDriveInputAndNoOutput() throws {
        var bytes = [UInt8](repeating: 0, count: 30)
        bytes[0] = 0x28; bytes[4] = 0x34; bytes[5] = 0x12
        bytes[6] = 1; bytes[8] = 2; bytes[10] = 3
        for model: WheelModel in [.rs50, .gProPS, .gProXbox] {
            let backend = try DirectDriveBackend(model: model)
            let input = try backend.decodeInputPayload(bytes)
            XCTAssertEqual(input.steering, 0x1234)
            XCTAssertEqual([input.throttle, input.brake, input.clutch], [1, 2, 3])
            XCTAssertEqual(input.hat, 8)
            XCTAssertFalse(backend.outputEnabled)
            XCTAssertThrowsError(try backend.forceReport())
            XCTAssertThrowsError(try backend.decodeInputPayload(Array(bytes.dropLast())))
        }
        XCTAssertThrowsError(try DirectDriveBackend(model: .ambiguousC272))
        XCTAssertThrowsError(try XboxWheelBackend().forceReport())
        var xbox = XboxWheelBackend()
        _ = try xbox.discovery.begin(now: 1)
        xbox.disconnect()
        XCTAssertThrowsError(try xbox.discovery.begin(now: 2))
        XCTAssertThrowsError(try xbox.effects.begin(.allocate, now: 2))
    }
    func acceptedFixture() -> SDKPreflight {
        var p = SDKPreflight()
        p.model = .g923PS; p.explicitOptIn = true; p.originalSDKSignatureVerified = true
        p.sdkVersion = "1.3.12"; p.crossoverVersion = "27.0.0.41069"
        p.transportContract = SDKPreflight.transportContract; p.transportHashVerified = true
        p.physicalContainerVerified = true; p.physicalPathVerified = true; p.inputOnlyLeaseHeld = true
        p.competingWritersStopped = true; p.hardwareAcceptanceRecorded = true
        return p
    }
    func testPreflightFailsClosedAndLifecycleNeverFallsBack() throws {
        XCTAssertFalse(SDKPreflight().blockers.isEmpty)
        var p = acceptedFixture(); XCTAssertTrue(p.blockers.isEmpty)
        p.model = .g923XboxPC; XCTAssertFalse(p.blockers.isEmpty)
        p = acceptedFixture(); p.transportHashVerified = false; XCTAssertFalse(p.blockers.isEmpty)
        XCTAssertFalse(WheelOutputMode.sdkInputOnly.appMayWrite)
        XCTAssertFalse(WheelOutputMode.passive.appMayWrite)
        var session = NativeSDKSupervisor()
        XCTAssertThrowsError(try session.arm(preflight: SDKPreflight(), now: 0))
        let epoch = try session.arm(preflight: acceptedFixture(), now: 0)
        try session.started(epoch: epoch, now: 1)
        try session.heartbeat(epoch: epoch, now: 1.2)
        session.poll(now: 1.7)
        XCTAssertEqual(session.state, .faulted)
        XCTAssertThrowsError(try session.heartbeat(epoch: epoch, now: 1.8))
        XCTAssertThrowsError(try session.reset(processConfirmedDead: false))
        try session.reset(processConfirmedDead: true)
        _ = try session.arm(preflight: acceptedFixture(), now: 2)
        session.processExited(); XCTAssertEqual(session.state, .faulted)
        try session.reset(processConfirmedDead: true)
        _ = try session.arm(preflight: acceptedFixture(), now: 3)
        session.disconnected(); XCTAssertEqual(session.state, .faulted)
    }
    @MainActor
    func testActorSharesTransactionBudgetAndDisconnects() async throws {
        let session = XboxProtocolSession()
        _ = try await session.discoverForceFeature(now: 0)
        do { try await session.beginEffect(.allocate, now: 0); XCTFail("overlapping transaction") }
        catch { XCTAssertEqual(error as? WheelProtocolError, .busy) }
        let index = try await session.receiveDiscovery([0x10, 0xff, 0, 1, 0x17, 0, 0], now: 0.1)
        XCTAssertEqual(index, 0x17)
        try await session.beginEffect(.allocate, now: 1)
        do { _ = try await session.discoverForceFeature(now: 1); XCTFail("overlapping discovery") }
        catch { XCTAssertEqual(error as? WheelProtocolError, .busy) }
        try await session.acknowledgeEffect(allocatedSlot: 3, now: 1.1)
        await session.disconnect()
        do { _ = try await session.discoverForceFeature(now: 2); XCTFail("disconnected") }
        catch { XCTAssertEqual(error as? WheelProtocolError, .disconnected) }
    }
    func testSingleWriterLeaseAndReversiblePlan() throws {
        var lease: MotorProcessLease? = try MotorProcessLease()
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try MotorProcessLease())
        lease = nil
        let next = try MotorProcessLease()
        withExtendedLifetime(next) {}
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let plan = NativeSDKSetupPlan(sdkPath: "/user/supplied.dll", transportPath: "/separate/wine")
        try plan.save(to: path)
        XCTAssertThrowsError(try plan.save(to: path))
        XCTAssertThrowsError(try NativeSDKSetupPlan(sdkPath: "/other", transportPath: "/other").remove(from: path))
        try plan.remove(from: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
