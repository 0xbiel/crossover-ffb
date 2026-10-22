import Foundation

/// Presentation only. Capability never enables a driver or changes a saved setting.
public struct WheelPresentation: Equatable, Sendable {
    public var running: Bool
    public var connected: Bool
    public var model: BridgeWheelModel?
    public var trueForceInterfaceAvailable: Bool
    public var age: TimeInterval

    public init(running: Bool, connected: Bool, model: BridgeWheelModel?, trueForceInterfaceAvailable: Bool, age: TimeInterval) {
        self.running = running; self.connected = connected; self.model = model
        self.trueForceInterfaceAvailable = trueForceInterfaceAvailable; self.age = age
    }
    public var isConnected: Bool { running && connected && age >= 0 && age <= 1 }
    public var visibleModel: BridgeWheelModel? { isConnected ? model : nil }
    public var showsTrueForce: Bool { isConnected && model == .g923 && trueForceInterfaceAvailable }
    public var title: String {
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
