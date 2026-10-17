import XCTest
@testable import WheelCore
final class HatDirectionTests: XCTestCase {
    func testAllEightDirections() {
        let expected: [HatDirection] = [.north, .northEast, .east, .southEast, .south, .southWest, .west, .northWest]
        for i in 0...7 { XCTAssertEqual(HatDirection.decode(raw: i, minimum: 0, maximum: 7, hasNullState: true), expected[i]) }
    }
    func testNeutralDoesNotBecomeNorthWest() {
        XCTAssertEqual(HatDirection.decode(raw: 8, minimum: 0, maximum: 7, hasNullState: true), .neutral)
        XCTAssertEqual(HatDirection.decode(raw: 8, minimum: 0, maximum: 7, hasNullState: false), .unknown)
    }
    func testShiftedRangeAndUnknownLayout() {
        XCTAssertEqual(HatDirection.decode(raw: 1, minimum: 1, maximum: 8, hasNullState: true), .north)
        XCTAssertEqual(HatDirection.decode(raw: 0, minimum: 1, maximum: 8, hasNullState: true), .neutral)
        XCTAssertEqual(HatDirection.decode(raw: 0, minimum: 0, maximum: 3, hasNullState: true), .unknown)
    }
}
