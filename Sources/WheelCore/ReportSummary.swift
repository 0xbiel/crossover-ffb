/// Bounded memory summary of incoming bytes; report ID is separate metadata.
public struct ReportSummary {
    public private(set) var count = 0
    public private(set) var first: [UInt8] = []
    public private(set) var last: [UInt8] = []
    public private(set) var lengths: Set<Int> = []
    public private(set) var changedOffsets: Set<Int> = []
    public init() {}
    public mutating func record(_ bytes: [UInt8]) {
        if count == 0 { first = bytes }
        else {
            for i in 0..<max(last.count, bytes.count) {
                if i >= last.count || i >= bytes.count || last[i] != bytes[i] { changedOffsets.insert(i) }
            }
        }
        count += 1; lengths.insert(bytes.count); last = bytes
    }
}
