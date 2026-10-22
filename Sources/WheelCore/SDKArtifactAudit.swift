import Foundation
import CryptoKit

public struct SDKArtifactAudit: Equatable, Sendable {
    public let sdkSHA256: String
    public let transportSHA256: String
    public let sdkIsX64DLL: Bool
    public let hashesMatch: Bool
    /// These checks cannot establish Authenticode trust, source correspondence or hardware acceptance.
    public var blockingReasons: [String] {
        var reasons: [String] = []
        if !sdkIsX64DLL { reasons.append("SDK is not a recognized x64 PE DLL header") }
        if !hashesMatch { reasons.append("Artifact hashes differ from the independently reviewed manifest") }
        return reasons
    }
    public static func inspect(sdk: Data, transport: Data, expectedSDKHash: String, expectedTransportHash: String) -> Self {
        let sdkHash = hash(sdk), transportHash = hash(transport)
        return Self(sdkSHA256: sdkHash, transportSHA256: transportHash, sdkIsX64DLL: isX64DLL(sdk),
                    hashesMatch: !sdk.isEmpty && !transport.isEmpty && sdkHash == expectedSDKHash.lowercased() && transportHash == expectedTransportHash.lowercased())
    }
    /// Read only; never dlopen, execute, copy or modify the supplied files.
    public static func inspect(sdkURL: URL, transportURL: URL, expectedSDKHash: String, expectedTransportHash: String) throws -> Self {
        try inspect(sdk: Data(contentsOf: sdkURL), transport: Data(contentsOf: transportURL),
                    expectedSDKHash: expectedSDKHash, expectedTransportHash: expectedTransportHash)
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isX64DLL(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 64, bytes[0] == 0x4d, bytes[1] == 0x5a else { return false }
        let pe = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[60 + $1]) << (8 * $1) }
        let offset = Int(pe)
        guard offset >= 64, offset <= bytes.count - 26 else { return false }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        let optionalLength = Int(u16(offset + 20))
        return Array(bytes[offset..<offset + 4]) == [0x50, 0x45, 0, 0]
            && u16(offset + 4) == 0x8664 && u16(offset + 22) & 0x2000 != 0
            && optionalLength >= 112 && optionalLength <= bytes.count - offset - 24
            && u16(offset + 24) == 0x20b
    }
}

public extension SDKPreflight {
    /// Apply local artifact facts without promoting them to signature or hardware acceptance.
    mutating func applyArtifactAudit(_ audit: SDKArtifactAudit) {
        transportHashVerified = audit.hashesMatch
        if !audit.hashesMatch || !audit.sdkIsX64DLL { originalSDKSignatureVerified = false }
    }
}
