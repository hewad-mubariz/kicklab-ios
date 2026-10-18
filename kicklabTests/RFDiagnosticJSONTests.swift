import XCTest
@testable import kicklab
final class RFDiagnosticJSONTests: XCTestCase {
    func testUnavailableTimingIsNullWithRecordedPath() throws {
        let data = try RFDiagnosticJSON.data(["rows": [["age": Double.infinity, "score": 0.4], ["age": -Double.infinity], ["age": Double.nan]], "count": 20, "quality_failed": false])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["age"] is NSNull })
        XCTAssertEqual(rows[0]["score"] as? Double, 0.4)
        XCTAssertEqual(object["count"] as? Int, 20)
        XCTAssertEqual(object["quality_failed"] as? Bool, false)
        XCTAssertEqual(object["nonfinite_diagnostic_paths"] as? [String], ["report.rows[0].age", "report.rows[1].age", "report.rows[2].age"])
    }
    func testUnsupportedValueThrowsBeforeObjectiveCWriter() {
        XCTAssertThrowsError(try RFDiagnosticJSON.data(["invalid": Date()]))
    }
}
