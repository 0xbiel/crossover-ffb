public struct InputSample: Equatable, Sendable {
    public let page: UInt32
    public let usage: UInt32
    public let raw: Int
    public let minimum: Int
    public let maximum: Int
    public init(page: UInt32, usage: UInt32, raw: Int, minimum: Int, maximum: Int) {
        self.page = page; self.usage = usage; self.raw = raw
        self.minimum = minimum; self.maximum = maximum
    }
    public var normalized: Double? {
        guard maximum > minimum else { return nil }
        return max(0, min(1, (Double(raw) - Double(minimum)) / (Double(maximum) - Double(minimum))))
    }
    public var label: String {
        if page == 9 { return "button-\(usage)" }
        if page == 1 {
            return [0x30: "X (steering candidate)", 0x31: "Y", 0x32: "Z", 0x33: "Rx", 0x34: "Ry", 0x35: "Rz", 0x36: "slider", 0x39: "hat"][usage] ?? "generic-desktop-\(usage)"
        }
        if page == 2 { return [0xc4: "accelerator", 0xc5: "brake", 0xc6: "clutch", 0xc8: "steering"][usage] ?? "simulation-\(usage)" }
        return "usage-\(page)-\(usage)"
    }
}
