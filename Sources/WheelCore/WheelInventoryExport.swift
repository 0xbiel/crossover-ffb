import Foundation

/// Capability boundary: inventory receives no open/get-report/set-report transport.
public protocol WheelMetadataSource {
    func readCachedMetadata() throws -> [WheelCollection]
}
public struct NativeWheelMetadataSource: WheelMetadataSource {
    public init() {}
    public func readCachedMetadata() -> [WheelCollection] { WheelInventory.readNativeMetadata() }
}
public struct WheelInventoryExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let collections: [WheelCollection]
    public let notes: String
    public static func capture(from source: any WheelMetadataSource) throws -> Self {
        let records = try source.readCachedMetadata().sorted { $0.registryID < $1.registryID }
        return Self(schemaVersion: 1, collections: records,
                    notes: "Cached metadata only; descriptors are base64. Registry IDs identify this boot, not a permanent device. Missing descriptors stay null. No serial numbers collected. No hardware acceptance implied.")
    }
    public func save(to newFile: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: newFile, options: .withoutOverwriting)
    }
}
