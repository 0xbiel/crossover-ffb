import Foundation
import XCTest
@testable import WheelCore

final class DirectDriveCompletionTests: XCTestCase {
    func testRawStreamGoldenAndWindowRollover() throws {
        var codec = DirectDriveStreamCodec(sequence: 254)
        let first = try codec.stream(rawTorque: 0x1234, newSamples: [0, 0xffff, 0x8000, 0x4321])
        let expected: [UInt8] = [1, 0, 0, 0, 1, 255, 0x34, 0x12, 0x34, 0x12, 4, 13]
            + Array(repeating: [UInt8](arrayLiteral: 0, 128, 0, 128), count: 9).flatMap { $0 }
            + [0, 0, 0, 0, 255, 255, 255, 255, 0, 128, 0, 128, 0x21, 0x43, 0x21, 0x43]
        XCTAssertEqual(first, expected)
        let second = try codec.stream(rawTorque: 0x8000, newSamples: [1, 2, 3, 4, 5])
        let frame = try DirectDriveStreamFrame(report: second)
        XCTAssertEqual(frame.sequence, 0); XCTAssertEqual(frame.newSampleCount, 5)
        XCTAssertEqual(frame.window, Array(repeating: 0x8000, count: 4) + [0, 0xffff, 0x8000, 0x4321, 1, 2, 3, 4, 5])
        let idle = try DirectDriveStreamFrame(report: codec.stream(rawTorque: 0, newSamples: []))
        XCTAssertEqual(idle.newSampleCount, 0); XCTAssertEqual(idle.rawTorque, 0); XCTAssertEqual(idle.window, frame.window)
        XCTAssertThrowsError(try codec.stream(rawTorque: 0, newSamples: Array(repeating: 1, count: 14)))
        XCTAssertEqual(codec.sequence, 1) // rejected packet does not advance state
        let full = try DirectDriveStreamFrame(report: codec.stream(rawTorque: 0xffff, newSamples: Array(0...12)))
        XCTAssertEqual(full.window, Array(0...12)); XCTAssertEqual(full.newSampleCount, 13)
        codec.clearHistory(); XCTAssertEqual(codec.window, Array(repeating: 0x8000, count: 13))
    }
    func testControlsGoldenAndSharedSequence() throws {
        var codec = DirectDriveStreamCodec(sequence: 0x45)
        let range = try codec.control(.operatingRange(90))
        XCTAssertEqual(range, [1, 0, 0, 0, 0x0e, 0x46, 0, 0, 0xb4, 0x42] + Array(repeating: 0, count: 54))
        let start = try codec.control(.start)
        XCTAssertEqual(start, [1, 0, 0, 0, 3, 0x47] + Array(repeating: 0, count: 58))
        let stop = try codec.control(.stop)
        XCTAssertEqual(Array(stop.prefix(6)), [1, 0, 0, 0, 4, 0x48])
        XCTAssertEqual(try codec.control(.handshake)[4], 7)
        XCTAssertEqual(Array(try codec.control(.parameterQuery(0x30)).prefix(7)), [1, 0, 0, 0, 5, 0x4a, 0x30])
        XCTAssertThrowsError(try codec.control(.parameterQuery(0x20)))
        for value: Float in [.nan, .infinity, -.infinity, 0, -1] { XCTAssertThrowsError(try codec.control(.operatingRange(value))) }
    }
    func testMalformedFramesAndStatusAreNotMotorTelemetry() throws {
        var codec = DirectDriveStreamCodec()
        let valid = try codec.stream(rawTorque: 0x8000, newSamples: [1])
        for offset in [0, 1, 4, 8, 11, 14] {
            var bad = valid; bad[offset] ^= 1
            XCTAssertThrowsError(try DirectDriveStreamFrame(report: bad))
        }
        var tooMany = valid; tooMany[10] = 14
        XCTAssertThrowsError(try DirectDriveStreamFrame(report: tooMany))
        XCTAssertThrowsError(try DirectDriveStreamFrame(report: Array(valid.dropLast())))
        // Documented setup status prefix; remaining uninterpreted fields padded for this fixture.
        let status: [UInt8] = [1, 0, 0, 0, 2, 0x43, 0xca, 0xbf, 3, 0, 128, 0, 128, 0xb4, 0x30, 0x1e, 0x0a]
        XCTAssertEqual(try DirectDriveReply(report: status + Array(repeating: 0, count: 47)),
                       .status(sequence: 0x43, rawState: 0xbfca, status: 3, position: 0x8000, previousPosition: 0x8000, counter: 0x0a1e30b4))
        let parameter: [UInt8] = [1, 0, 0, 0, 5, 1, 0, 9, 0, 0, 0, 0, 0x40, 0xb1]
        XCTAssertEqual(try DirectDriveReply(report: parameter + Array(repeating: 0, count: 50)), .parameter(sequence: 1, index: 0, value: 2, trailing: 0xb1))
        var handshake: [UInt8] = [1, 0, 0, 0, 7, 0x34, 6]
        for slot in UInt8(1)...6 { handshake += [slot, 1, slot == 5 ? 0 : 1] }
        handshake += [0x9f] + Array(repeating: 0, count: 38)
        XCTAssertEqual(try DirectDriveReply(report: handshake), .handshake(sequence: 0x34, flags: [1, 1, 1, 1, 0, 1], trailing: 0x9f))
        handshake[7] = 2; XCTAssertThrowsError(try DirectDriveReply(report: handshake))
    }
    func sdkFixture() -> Data {
        var pe = Data(repeating: 0, count: 200)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64; pe[64] = 0x50; pe[65] = 0x45
        pe[68] = 0x64; pe[69] = 0x86; pe[84] = 112; pe[87] = 0x20; pe[88] = 0x0b; pe[89] = 2
        return pe
    }
    func acceptedFixture() -> SDKPreflight {
        var p = SDKPreflight()
        p.model = .g923PS; p.explicitOptIn = true; p.originalSDKSignatureVerified = true; p.sdkVersion = "1.3.12"
        p.crossoverVersion = "27.0.0.41069"; p.transportContract = SDKPreflight.transportContract
        p.transportHashVerified = true; p.physicalContainerVerified = true; p.physicalPathVerified = true
        p.inputOnlyLeaseHeld = true; p.competingWritersStopped = true; p.hardwareAcceptanceRecorded = true
        return p
    }
    final class Executor: SDKInvocationExecutor {
        var isRunning = false, invocations: [SDKProcessInvocation] = [], terminations = 0, kills = 0
        func execute(_ invocation: SDKProcessInvocation) { invocations.append(invocation); isRunning = true }
        func terminateTree() { terminations += 1 }
        func killTree() { kills += 1 }
    }
    func testLaunchPreparationBindsArtifactsAndDoesNotInventSDKABI() throws {
        let sdk = sdkFixture(), transport = Data("mock runtime".utf8)
        let plan = NativeSDKSetupPlan(sdkPath: "/reviewed/original.dll", transportPath: "/reviewed/wine")
        let invocation = SDKProcessInvocation(executable: URL(fileURLWithPath: plan.transportPath), arguments: ["game with spaces.exe", "literal$(text)"], workingDirectory: URL(fileURLWithPath: "/reviewed"))
        let review = SDKLaunchReview(sdkSHA256: SDKArtifactAudit.hash(sdk), transportSHA256: SDKArtifactAudit.hash(transport), signatureEvidence: "mock signature review", transportProvenanceEvidence: "mock source/license manifest")
        XCTAssertThrowsError(try PreparedSDKLaunch.prepare(plan: plan, invocation: invocation, sdkBytes: sdk, transportBytes: transport, review: review, preflight: SDKPreflight()))
        let prepared = try PreparedSDKLaunch.prepare(plan: plan, invocation: invocation, sdkBytes: sdk, transportBytes: transport, review: review, preflight: acceptedFixture())
        let executor = Executor()
        let process = PreparedSDKProcess(launch: prepared, executor: executor) { (sdk, transport) }
        try process.launch(plan: plan)
        XCTAssertEqual(executor.invocations, [invocation]) // argv stays literal; no shell expansion
        XCTAssertThrowsError(try process.launch(plan: plan))
        process.requestTermination(); process.requestKill()
        XCTAssertEqual(executor.terminations, 1); XCTAssertEqual(executor.kills, 1)
        let changed = Executor()
        let changedProcess = PreparedSDKProcess(launch: prepared, executor: changed) { (sdk, Data("changed".utf8)) }
        XCTAssertThrowsError(try changedProcess.launch(plan: plan)); XCTAssertTrue(changed.invocations.isEmpty)
        let missingReview = SDKLaunchReview(sdkSHA256: review.sdkSHA256, transportSHA256: review.transportSHA256, signatureEvidence: " ", transportProvenanceEvidence: "review")
        XCTAssertThrowsError(try PreparedSDKLaunch.prepare(plan: plan, invocation: invocation, sdkBytes: sdk, transportBytes: transport, review: missingReview, preflight: acceptedFixture()))
        XCTAssertThrowsError(try PreparedSDKLaunch.prepare(plan: plan, invocation: .init(executable: URL(fileURLWithPath: "/other/wine"), arguments: ["game"], workingDirectory: invocation.workingDirectory), sdkBytes: sdk, transportBytes: transport, review: review, preflight: acceptedFixture()))
    }
}
