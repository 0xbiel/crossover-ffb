import Foundation

/// Presentation only. Capability never enables a driver or changes a saved setting.
public struct WheelPresentation: Equatable, Sendable {
    public var running: Bool
    public var connected: Bool
    public var model: BridgeWheelModel?
    public var trueForceInterfaceAvailable: Bool
    public var age: TimeInterval
    /// A recognised Logitech wheel the bridge does not drive. It is never attached or written to.
    public var detected: WheelModel?

    public init(running: Bool, connected: Bool, model: BridgeWheelModel?, trueForceInterfaceAvailable: Bool, age: TimeInterval, detected: WheelModel? = nil) {
        self.running = running; self.connected = connected; self.model = model
        self.trueForceInterfaceAvailable = trueForceInterfaceAvailable; self.age = age; self.detected = detected
    }
    public var isConnected: Bool { running && connected && age >= 0 && age <= 1 }
    public var visibleModel: BridgeWheelModel? { isConnected ? model : nil }
    public var showsTrueForce: Bool { isConnected && model == .g923 && trueForceInterfaceAvailable }
    /// Shown only while no supported wheel is connected and the status is fresh.
    public var unsupportedModel: WheelModel? {
        guard running, !isConnected, age >= 0, age <= 1, let detected, detected.experimental else { return nil }
        return detected
    }
    public var title: String {
        if let unsupportedModel { return unsupportedModel.displayName }
        guard isConnected else { return "No wheel connected" }
        switch model {
        case .g29: return "Logitech G29"
        case .g923: return "Logitech G923"
        case nil: return "Unknown wheel"
        }
    }
    public static func angle(steering: UInt32, range: Int) -> Double {
        (Double(min(steering, 65535)) / 32767.5 - 1) * Double(range) / 2
    }
}

public extension WheelModel {
    var displayName: String {
        switch self {
        case .g29: "Logitech G29"
        case .g923PS: "Logitech G923"
        case .g923XboxPC: "Logitech G923 for Xbox"
        case .g923XboxConsole: "Logitech G923 (Xbox console mode)"
        case .rs50: "Logitech RS50"
        case .gProPS: "Logitech G PRO"
        case .gProXbox: "Logitech G PRO for Xbox"
        // c272 is shared by RS50 compatibility mode and G PRO Xbox/PC; do not guess.
        case .ambiguousC272: "Logitech RS50 or G PRO"
        case .unknown: "Unknown Logitech wheel"
        }
    }
}
