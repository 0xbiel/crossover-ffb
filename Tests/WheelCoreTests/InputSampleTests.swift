import XCTest
@testable import WheelCore

final class InputSampleTests: XCTestCase {
    private func sample(_ raw: Int, minimum: Int = -100, maximum: Int = 100) -> InputSample {
        InputSample(page: 1, usage: 0x30, raw: raw, minimum: minimum, maximum: maximum)
    }

    func testNormalizationIncludesEndpointsAndMidpoint() {
        XCTAssertEqual(sample(-100).normalized, 0)
        XCTAssertEqual(sample(0).normalized, 0.5)
        XCTAssertEqual(sample(100).normalized, 1)
        XCTAssertEqual(sample(25, minimum: 0, maximum: 100).normalized, 0.25)
    }

    func testNormalizationClampsOutOfRangeSamples() {
        XCTAssertEqual(sample(-101).normalized, 0)
        XCTAssertEqual(sample(101).normalized, 1)
        XCTAssertEqual(sample(Int.min).normalized, 0)
        XCTAssertEqual(sample(Int.max).normalized, 1)
    }

    func testInvalidLogicalRangesHaveNoNormalizedValue() {
        XCTAssertNil(sample(10, minimum: 10, maximum: 10).normalized)
        XCTAssertNil(sample(10, minimum: 20, maximum: 0).normalized)
    }

    func testNormalizationAvoidsIntegerOverflowForFullWidthRanges() {
        XCTAssertEqual(sample(Int.min, minimum: Int.min, maximum: Int.max).normalized, 0)
        XCTAssertEqual(sample(0, minimum: Int.min, maximum: Int.max).normalized, 0.5)
        XCTAssertEqual(sample(Int.max, minimum: Int.min, maximum: Int.max).normalized, 1)
    }

    func testKnownUsageLabels() {
        let cases: [(UInt32, UInt32, String)] = [
            (9, 1, "button-1"), (9, 32, "button-32"),
            (1, 0x30, "X (steering candidate)"), (1, 0x31, "Y"),
            (1, 0x32, "Z"), (1, 0x33, "Rx"), (1, 0x34, "Ry"),
            (1, 0x35, "Rz"), (1, 0x36, "slider"), (1, 0x39, "hat"),
            (2, 0xc4, "accelerator"), (2, 0xc5, "brake"),
            (2, 0xc6, "clutch"), (2, 0xc8, "steering")
        ]
        for (page, usage, expected) in cases {
            XCTAssertEqual(InputSample(page: page, usage: usage, raw: 0, minimum: 0, maximum: 1).label, expected)
        }
    }

    func testUnknownUsageLabelsPreservePageAndUsageIdentity() {
        let cases: [(UInt32, UInt32, String)] = [
            (1, 255, "generic-desktop-255"),
            (2, 255, "simulation-255"),
            (0xff00, 48, "usage-65280-48")
        ]
        for (page, usage, expected) in cases {
            XCTAssertEqual(InputSample(page: page, usage: usage, raw: 0, minimum: 0, maximum: 1).label, expected)
        }
    }
}
