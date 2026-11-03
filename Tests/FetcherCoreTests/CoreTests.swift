import XCTest
@testable import FetcherCore

final class CoreTests: XCTestCase {
    func testPlanCoversWholeFileWithoutGaps() {
        let total: Int64 = 10_000_001
        let segs = DownloadTask.plan(total: total, ranges: true, connections: 8)
        XCTAssertEqual(segs.count, 8)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, total - 1)
        for i in 1..<segs.count { XCTAssertEqual(segs[i].start, segs[i - 1].end + 1) }
        XCTAssertEqual(segs.reduce(0) { $0 + $1.length }, total)
    }

    func testPlanSmallFileUsesOneSegment() {
        XCTAssertEqual(DownloadTask.plan(total: 100_000, ranges: true, connections: 8).count, 1)
    }

    func testPlanWithoutRangesIsSingleStream() {
        let s = DownloadTask.plan(total: 5_000_000, ranges: false, connections: 8)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].end, 4_999_999)
        XCTAssertEqual(DownloadTask.plan(total: -1, ranges: false, connections: 8)[0].end, -1)
    }

    func testContentDisposition() {
        XCTAssertEqual(FileNaming.parseDisposition(#"attachment; filename="a b.zip""#), "a b.zip")
        XCTAssertEqual(FileNaming.parseDisposition("attachment; filename=report.pdf"), "report.pdf")
        XCTAssertEqual(FileNaming.parseDisposition("attachment; filename*=UTF-8''na%C3%AFve.txt"), "naïve.txt")
        XCTAssertNil(FileNaming.parseDisposition("inline"))
    }

    func testSanitizeAndCategory() {
        XCTAssertEqual(FileNaming.sanitize("a/b:c"), "a_b_c")
        XCTAssertEqual(FileCategory.forFileName("x.MKV"), .video)
        XCTAssertEqual(FileCategory.forFileName("x.dmg"), .programs)
        XCTAssertEqual(FileCategory.forFileName("x.unknown"), .other)
    }
}
