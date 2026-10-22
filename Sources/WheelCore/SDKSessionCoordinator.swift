import Foundation

/// Adapter contract for the future accepted runtime. No concrete Wine/SDK launcher is supplied:
/// the original SDK must stay in its documented game process, not a guessed host ABI.
public protocol SDKProcessControl: AnyObject {
    var isRunning: Bool { get }
    func launch(plan: NativeSDKSetupPlan) throws
    func requestTermination()
    func requestKill()
}
public protocol SDKSessionLease: AnyObject { func releaseAfterConfirmedExit() }

/// Offline-testable orchestration. Lease remains held after a failed stop/kill until exit is
/// confirmed. Tick is externally scheduled and never blocks waiting for a subprocess.
public final class SDKSessionCoordinator {
    public private(set) var supervisor = NativeSDKSupervisor()
    public private(set) var leaseHeld = true
    private let process: any SDKProcessControl
    private let lease: any SDKSessionLease
    private var terminateAt: Double?
    private var killRequested = false
    public init(process: any SDKProcessControl, lease: any SDKSessionLease) {
        self.process = process; self.lease = lease
    }
    public func start(plan: NativeSDKSetupPlan, preflight: SDKPreflight, now: Double) throws -> UInt64 {
        guard leaseHeld, !process.isRunning, plan.schemaVersion == 1,
              plan.mode == .sdkInputOnly, plan.transportContract == SDKPreflight.transportContract else { throw SessionError.rejected }
        let epoch = try supervisor.arm(preflight: preflight, now: now)
        do {
            try process.launch(plan: plan)
            guard process.isRunning else { throw SessionError.invalidTransition }
            // A real adapter must signal readiness after input-only attachment, not just spawn.
            return epoch
        } catch {
            supervisor.processExited()
            stop(now: now)
            throw error
        }
    }
    public func ready(epoch: UInt64, now: Double) throws {
        do { try supervisor.started(epoch: epoch, now: now) }
        catch { stop(now: now); throw error }
    }
    public func heartbeat(epoch: UInt64, now: Double) throws {
        do { try supervisor.heartbeat(epoch: epoch, now: now) }
        catch { stop(now: now); throw error }
    }
    public func disconnected(now: Double) { supervisor.disconnected(); stop(now: now) }
    public func stop(now: Double) {
        supervisor.processExited()
        guard leaseHeld else { return }
        if !process.isRunning { release(); return }
        if terminateAt == nil {
            process.requestTermination()
            terminateAt = now.isFinite ? now : 0
        }
    }
    public func tick(now: Double) {
        guard leaseHeld else { return }
        if !process.isRunning {
            supervisor.processExited(); release(); return
        }
        supervisor.poll(now: now)
        if supervisor.state == .faulted { stop(now: now) }
        if let start = terminateAt, !killRequested, !now.isFinite || now < start || now >= start + 0.5 {
            process.requestKill(); killRequested = true
        }
        if !process.isRunning { release() }
    }
    private func release() {
        guard leaseHeld else { return }
        lease.releaseAfterConfirmedExit(); leaseHeld = false
    }
}
