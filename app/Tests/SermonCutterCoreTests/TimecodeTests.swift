import XCTest
@testable import SermonCutterCore

final class TimecodeTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(Timecode.format(4296), "1:11:36")
        XCTAssertEqual(Timecode.format(96.55, tenths: true), "1:36.5")
        XCTAssertEqual(Timecode.span(497), "8 min 17 s")
    }

    func testParse() {
        XCTAssertEqual(Timecode.parse("1:11:36"), 4296)
        XCTAssertEqual(Timecode.parse("71:36"), 4296)
        XCTAssertEqual(Timecode.parse("1:11:36.5"), 4296.5)
        XCTAssertEqual(Timecode.parse("4296"), 4296)
        XCTAssertNil(Timecode.parse("1:75:00"))
        XCTAssertNil(Timecode.parse("abc"))
    }
}
