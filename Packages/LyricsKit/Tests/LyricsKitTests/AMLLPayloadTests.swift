import XCTest
@testable import LyricsKit

final class AMLLPayloadTests: XCTestCase {
    private func words(_ line: [String: Any]) -> [[String: Any]] {
        line["words"] as? [[String: Any]] ?? []
    }

    private func milliseconds(_ dictionary: [String: Any], _ key: String) -> Double {
        dictionary[key] as? Double ?? .nan
    }

    func testLineTimingBecomesOneWordEndingAtNextLine() {
        let result = AMLLPayload.lines(from: [LyricLine(start: 1, text: "a"), LyricLine(start: 3, text: "b")])
        XCTAssertEqual(milliseconds(result[0], "startTime"), 1000)
        XCTAssertEqual(milliseconds(result[0], "endTime"), 3000)
        XCTAssertEqual(words(result[0]).map { $0["word"] as? String }, ["a"])
        XCTAssertEqual(milliseconds(words(result[0])[0], "endTime"), 3000)
    }

    func testLastLineGetsFallbackEnd() {
        let result = AMLLPayload.lines(from: [LyricLine(start: 1, text: "a")])
        XCTAssertEqual(milliseconds(result[0], "endTime"), 6000)
    }

    func testWordTimingIsPreserved() {
        let line = LyricLine(start: 1, text: "a b", end: 3, words: [
            LyricWord(start: 1, end: 2, text: "a "),
            LyricWord(start: 2, end: 3, text: "b"),
        ])
        let result = AMLLPayload.lines(from: [line])
        XCTAssertEqual(words(result[0]).map { $0["word"] as? String }, ["a ", "b"])
        XCTAssertEqual(milliseconds(words(result[0])[1], "startTime"), 2000)
    }

    func testGapsAreDroppedButStillEndThePreviousLine() {
        let result = AMLLPayload.lines(from: [
            LyricLine(start: 1, text: "a"),
            LyricLine(start: 2, text: ""),
            LyricLine(start: 9, text: "b"),
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(milliseconds(result[0], "endTime"), 2000)
    }

    func testValuesAmllRejectsAreClamped() {
        let line = LyricLine(start: -1, text: "a b", end: 0.5, words: [
            LyricWord(start: -2, end: -3, text: "a "),
            LyricWord(start: 1, end: 0.5, text: "b"),
        ])
        let result = AMLLPayload.lines(from: [line])[0]
        XCTAssertEqual(milliseconds(result, "startTime"), 0)
        XCTAssertGreaterThanOrEqual(milliseconds(result, "endTime"), milliseconds(result, "startTime"))
        for word in words(result) {
            XCTAssertGreaterThanOrEqual(milliseconds(word, "startTime"), 0)
            XCTAssertGreaterThanOrEqual(milliseconds(word, "endTime"), milliseconds(word, "startTime"))
        }
    }

    func testLineEndCoversItsWords() {
        let line = LyricLine(start: 1, text: "a", end: 2, words: [LyricWord(start: 1, end: 4, text: "a"), LyricWord(start: 4, end: 5, text: "b")])
        XCTAssertEqual(milliseconds(AMLLPayload.lines(from: [line])[0], "endTime"), 5000)
    }
}
