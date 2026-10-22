import Foundation

/// Offline RS50/G PRO protocol values. Raw offset-binary words are not Nm or game gain.
/// Original serialization of the pinned TRUEFORCE_PROTOCOL.md; no HID transport or init table.
public struct DirectDriveStreamCodec: Sendable {
    public private(set) var sequence: UInt8
    public private(set) var window = Array(repeating: UInt16(0x8000), count: 13)
    public init(sequence: UInt8 = 0) { self.sequence = sequence }

    public enum Control: Sendable {
        case start, stop, handshake, parameterQuery(UInt8), operatingRange(Float)
    }
    /// Encoding a control does not assert that it is safe or accepted on attached hardware.
    /// Parameter queries intentionally carry zero payload, not guessed DSP coefficients.
    public mutating func control(_ control: Control) throws -> [UInt8] {
        let type: UInt8, payload: [UInt8]
        switch control {
        case .start: type = 3; payload = []
        case .stop: type = 4; payload = []
        case .handshake: type = 7; payload = []
        case .parameterQuery(let index):
            guard index <= 0x1d || (0x2b...0x3c).contains(index) else { throw WheelProtocolError.unsupported }
            type = 5; payload = [index]
        case .operatingRange(let degrees):
            guard degrees.isFinite, degrees > 0 else { throw WheelProtocolError.malformed }
            type = 0x0e
            payload = Self.littleEndian(degrees.bitPattern)
        }
        return packet(type: type, payload: payload)
    }
    /// Accepts 0...13 fresh samples; never silently drops excess data. Zero count clears the
    /// valid flag while retaining history. Torque and audio window remain independent.
    public mutating func stream(rawTorque: UInt16, newSamples: [UInt16]) throws -> [UInt8] {
        guard newSamples.count <= 13 else { throw WheelProtocolError.malformed }
        window = Array(window.dropFirst(newSamples.count)) + newSamples
        let payload = Self.pair(rawTorque) + [UInt8(newSamples.count), newSamples.isEmpty ? 0 : 13] + window.flatMap(Self.pair)
        return packet(type: 1, payload: payload)
    }
    /// Explicit reset of local history, not a command or an assertion that hardware stopped.
    public mutating func clearHistory() { window = Array(repeating: 0x8000, count: 13) }
    private mutating func packet(type: UInt8, payload: [UInt8]) -> [UInt8] {
        sequence &+= 1
        return [1, 0, 0, 0, type, sequence] + payload + Array(repeating: 0, count: 58 - payload.count)
    }
    private static func pair(_ word: UInt16) -> [UInt8] {
        let bytes = [UInt8(word & 255), UInt8(word >> 8)]
        return bytes + bytes
    }
    private static func littleEndian(_ word: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }
}

public struct DirectDriveStreamFrame: Equatable, Sendable {
    public let sequence: UInt8
    public let rawTorque: UInt16
    public let newSampleCount: UInt8
    public let window: [UInt16]
    public init(report: [UInt8]) throws {
        guard report.count == 64, Array(report.prefix(5)) == [1, 0, 0, 0, 1],
              report[10] <= 13, report[11] == (report[10] == 0 ? 0 : 13) else { throw WheelProtocolError.malformed }
        func word(_ at: Int) -> UInt16 { UInt16(report[at]) | UInt16(report[at + 1]) << 8 }
        guard word(6) == word(8) else { throw WheelProtocolError.malformed }
        var samples: [UInt16] = []
        for offset in stride(from: 12, to: 64, by: 4) {
            guard word(offset) == word(offset + 2) else { throw WheelProtocolError.malformed }
            samples.append(word(offset))
        }
        sequence = report[5]; rawTorque = word(6); newSampleCount = report[10]; window = samples
    }
}

public enum DirectDriveReply: Equatable, Sendable {
    /// rawState is undecoded, specifically NOT motor current or temperature.
    case status(sequence: UInt8, rawState: UInt16, status: UInt8, position: UInt16, previousPosition: UInt16, counter: UInt32)
    case parameter(sequence: UInt8, index: UInt8, value: Float, trailing: UInt8)
    case handshake(sequence: UInt8, flags: [UInt8], trailing: UInt8)
    public init(report: [UInt8]) throws {
        guard report.count == 64, Array(report.prefix(4)) == [1, 0, 0, 0] else { throw WheelProtocolError.malformed }
        func word(_ at: Int) -> UInt16 { UInt16(report[at]) | UInt16(report[at + 1]) << 8 }
        func dword(_ at: Int) -> UInt32 { UInt32(word(at)) | UInt32(word(at + 2)) << 16 }
        switch report[4] {
        case 2:
            self = .status(sequence: report[5], rawState: word(6), status: report[8], position: word(9), previousPosition: word(11), counter: dword(13))
        case 5:
            guard report[7] == 9, report[6] == report[8] else { throw WheelProtocolError.malformed }
            self = .parameter(sequence: report[5], index: report[6], value: Float(bitPattern: dword(9)), trailing: report[13])
        case 7:
            guard report[6] == 6 else { throw WheelProtocolError.malformed }
            var flags: [UInt8] = []
            for slot in 0..<6 {
                let offset = 7 + slot * 3
                guard report[offset] == UInt8(slot + 1), report[offset + 1] == 1 else { throw WheelProtocolError.malformed }
                flags.append(report[offset + 2])
            }
            self = .handshake(sequence: report[5], flags: flags, trailing: report[25])
        default: throw WheelProtocolError.unsupported
        }
    }
}
