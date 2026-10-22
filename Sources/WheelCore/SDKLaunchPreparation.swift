import Foundation

/// Hash-bound external review, not a local Authenticode verifier. Review must establish
/// original signed Logitech provenance and full transport source/license correspondence.
public struct SDKLaunchReview: Sendable {
    public let sdkSHA256: String, transportSHA256: String
    public let signatureEvidence: String, transportProvenanceEvidence: String
    public init(sdkSHA256: String, transportSHA256: String, signatureEvidence: String, transportProvenanceEvidence: String) {
        self.sdkSHA256 = sdkSHA256; self.transportSHA256 = transportSHA256
        self.signatureEvidence = signatureEvidence; self.transportProvenanceEvidence = transportProvenanceEvidence
    }
}
public struct SDKProcessInvocation: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    /// Exact reviewed argv, never a shell command, SDK dlopen or bottle/registry mutation.
    public init(executable: URL, arguments: [String], workingDirectory: URL) {
        self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory
    }
}
public struct PreparedSDKLaunch: Sendable {
    public let plan: NativeSDKSetupPlan
    public let invocation: SDKProcessInvocation
    public let sdkSHA256: String, transportSHA256: String
    /// Pure preparation over supplied bytes; caller must revalidate immediately before launch.
    /// No launch arguments are invented: the reviewed runtime/game command is mandatory.
    public static func prepare(plan: NativeSDKSetupPlan, invocation: SDKProcessInvocation,
                               sdkBytes: Data, transportBytes: Data, review: SDKLaunchReview,
                               preflight: SDKPreflight) throws -> Self {
        guard plan.schemaVersion == 1, plan.mode == .sdkInputOnly,
              plan.transportContract == SDKPreflight.transportContract,
              preflight.blockers.isEmpty,
              invocation.executable.isFileURL, invocation.workingDirectory.isFileURL,
              invocation.executable.path == plan.transportPath,
              plan.sdkPath.hasPrefix("/"), plan.transportPath.hasPrefix("/"),
              !invocation.arguments.isEmpty,
              invocation.arguments.allSatisfy({ !$0.contains("\0") }),
              !review.signatureEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !review.transportProvenanceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionError.rejected }
        let audit = SDKArtifactAudit.inspect(sdk: sdkBytes, transport: transportBytes,
                    expectedSDKHash: review.sdkSHA256, expectedTransportHash: review.transportSHA256)
        guard audit.blockingReasons.isEmpty else { throw SessionError.rejected }
        return Self(plan: plan, invocation: invocation, sdkSHA256: audit.sdkSHA256, transportSHA256: audit.transportSHA256)
    }
    /// Prevent mock/adapter dispatch if bytes changed after preparation. A real process adapter
    /// must additionally prevent filesystem TOCTOU and supervise the complete Wine process tree.
    public func revalidate(sdkBytes: Data, transportBytes: Data) throws {
        let audit = SDKArtifactAudit.inspect(sdk: sdkBytes, transport: transportBytes,
                    expectedSDKHash: sdkSHA256, expectedTransportHash: transportSHA256)
        guard audit.blockingReasons.isEmpty else { throw SessionError.rejected }
    }
}

/// Testable execution boundary. No production executor is provided or selected implicitly.
public protocol SDKInvocationExecutor: AnyObject {
    var isRunning: Bool { get }
    func execute(_ invocation: SDKProcessInvocation) throws
    func terminateTree()
    func killTree()
}
public final class PreparedSDKProcess: SDKProcessControl {
    private let launch: PreparedSDKLaunch
    private let executor: any SDKInvocationExecutor
    private let readArtifacts: () throws -> (sdk: Data, transport: Data)
    public init(launch: PreparedSDKLaunch, executor: any SDKInvocationExecutor,
                readArtifacts: @escaping () throws -> (sdk: Data, transport: Data)) {
        self.launch = launch; self.executor = executor; self.readArtifacts = readArtifacts
    }
    public var isRunning: Bool { executor.isRunning }
    public func launch(plan: NativeSDKSetupPlan) throws {
        guard plan == launch.plan, !isRunning else { throw SessionError.rejected }
        let bytes = try readArtifacts()
        try launch.revalidate(sdkBytes: bytes.sdk, transportBytes: bytes.transport)
        try executor.execute(launch.invocation)
    }
    public func requestTermination() { executor.terminateTree() }
    public func requestKill() { executor.killTree() }
}
