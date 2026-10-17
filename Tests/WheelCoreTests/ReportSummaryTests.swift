import XCTest
@testable import WheelCore
final class ReportSummaryTests: XCTestCase {
    func testChangesAndStableReports() {
        var s = ReportSummary()
        s.record([0, 1]); s.record([0, 1]); s.record([0, 2])
        XCTAssertEqual(s.count, 3); XCTAssertEqual(s.first, [0, 1]); XCTAssertEqual(s.last, [0, 2])
        XCTAssertEqual(s.changedOffsets, [1]); XCTAssertEqual(s.lengths, [2])
    }
    func testLengthChangesAndEmptyReports() {
        var s = ReportSummary()
        s.record([]); s.record([5, 6]); s.record([5]); s.record([])
        XCTAssertEqual(s.count, 4); XCTAssertEqual(s.first, []); XCTAssertEqual(s.last, [])
        XCTAssertEqual(s.changedOffsets, [0, 1]); XCTAssertEqual(s.lengths, [0, 1, 2])
    }
}
