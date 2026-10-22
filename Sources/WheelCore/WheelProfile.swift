import Foundation

/// Discovery facts only. Never open, initialize or write a device while classifying it.
public struct WheelCollection: Equatable, Sendable {
    public let registryID: UInt64
    /// USB device ancestor (not the HID collection or interface ancestor). Nil is ungroupable.
    public let physicalID: UInt64?
    public let vendor: UInt16
    public let product: UInt16
    public let name: String
    public let usagePage: UInt32
    public let usage: UInt32
    public init(registryID: UInt64, physicalID: UInt64?, vendor: UInt16, product: UInt16,
                name: String, usagePage: UInt32, usage: UInt32) {
        self.registryID = registryID; self.physicalID = physicalID; self.vendor = vendor
        self.product = product; self.name = name; self.usagePage = usagePage; self.usage = usage
    }
    public var isJoystick: Bool { usagePage == 1 && [4, 5, 8].contains(usage) }
    public var isTrueForce: Bool { usagePage == 0xfffd && usage == 0xfd01 }
}

public enum WheelModel: String, CaseIterable, Sendable {
    case g29, g923PS, g923XboxPC, g923XboxConsole, rs50, gProPS, gProXbox
    case ambiguousC272, unknown
    public var experimental: Bool { self != .g29 && self != .g923PS }
    public var ratedTorqueNm: Double? {
        switch self { case .rs50: 8; case .gProPS, .gProXbox: 11; default: nil }
    }
}
public enum WheelBackendKind: String, Sendable { case readOnly, classicLogitech, xboxHIDPP, directDrive }
public struct WheelProfile: Equatable, Sendable {
    public let model: WheelModel
    public let backend: WheelBackendKind
    public let hasInput: Bool
    public let hasTrueForceCollection: Bool
    /// Hardware capability does not imply permission or accepted output transport.
    public var defaultOutputAllowed: Bool { !model.experimental && hasInput }
    public var supportsNativeSDKCandidate: Bool { model == .g923PS && hasInput && hasTrueForceCollection }
    public static func resolve(_ collections: [WheelCollection]) -> Self {
        let products = Set(collections.map(\.product))
        let parents = Set(collections.compactMap(\.physicalID))
        guard !collections.isEmpty, collections.allSatisfy({ $0.vendor == 0x046d }),
              products.count == 1, parents.count == 1,
              collections.allSatisfy({ $0.physicalID != nil }) else {
            return Self(model: .unknown, backend: .readOnly, hasInput: false, hasTrueForceCollection: false)
        }
        let model: WheelModel
        switch products.first! {
        case 0xc24f: model = .g29
        case 0xc266: model = .g923PS
        case 0xc26d: model = .g923XboxConsole
        case 0xc26e: model = .g923XboxPC
        case 0xc276: model = .rs50
        case 0xc268: model = .gProPS
        case 0xc272:
            // Product string is a hint only. Compatibility identity needs an independent capture.
            model = .ambiguousC272
        default: model = .unknown
        }
        let backend: WheelBackendKind
        switch model {
        case .g29, .g923PS: backend = .classicLogitech
        case .g923XboxPC: backend = .xboxHIDPP
        case .rs50, .gProPS, .gProXbox: backend = .directDrive
        default: backend = .readOnly
        }
        return Self(model: model, backend: backend,
                    hasInput: collections.filter(\.isJoystick).count == 1,
                    hasTrueForceCollection: collections.filter(\.isTrueForce).count == 1)
    }
}
public enum WheelInventory {
    /// Missing USB ancestry is never guessed from PID, serial, name or interface number.
    public static func groups(_ collections: [WheelCollection]) -> [[WheelCollection]] {
        var grouped: [UInt64: [WheelCollection]] = [:]
        var ungrouped: [[WheelCollection]] = []
        for item in collections {
            if let parent = item.physicalID { grouped[parent, default: []].append(item) }
            else { ungrouped.append([item]) }
        }
        return grouped.keys.sorted().map { grouped[$0]! } + ungrouped
    }
}

/// Input layouts are model-specific; values remain raw HID polarity (65535 = pedal released).
public enum WheelInputDecoder {
    public static func apply(_ sample: InputSample, model: WheelModel, to input: inout BridgeInput) {
        guard [.g29, .g923PS, .g923XboxPC].contains(model), sample.page == 1, let value = sample.normalized else { return }
        let scaled = UInt32((value * 65535).rounded())
        if sample.usage == 0x30 { input.steering = scaled; return }
        switch model {
        case .g923XboxPC:
            switch sample.usage { case 0x31: input.throttle = scaled; case 0x32: input.brake = scaled; case 0x35: input.clutch = scaled; default: break }
        case .g29, .g923PS:
            switch sample.usage { case 0x31: input.clutch = scaled; case 0x32: input.throttle = scaled; case 0x35: input.brake = scaled; default: break }
        default: break
        }
    }
}
