import XCTest
@testable import ClaudeMonitorKit

final class SessionIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func apply(
        _ name: String,
        session: String,
        cwd: String = "/tmp/demo",
        title: String? = nil,
        to sessions: inout [String: ClaudeSession]
    ) {
        SessionReducer.apply(
            HookEvent(sessionID: session, name: name, cwd: cwd, sessionTitle: title, timestamp: t0),
            to: &sessions
        )
    }

    func testDecodesDocumentedSessionTitle() throws {
        let json = #"{"session_id":"a","hook_event_name":"UserPromptSubmit","session_title":"Fix login"}"#
        let event = try XCTUnwrap(HookEvent(json: Data(json.utf8), timestamp: t0))
        XCTAssertEqual(event.sessionTitle, "Fix login")
    }

    func testTitleSurvivesEventsThatOmitIt() {
        var sessions: [String: ClaudeSession] = [:]
        apply("UserPromptSubmit", session: "a", title: "Fix login", to: &sessions)
        apply("PreToolUse", session: "a", to: &sessions)
        XCTAssertEqual(sessions["a"]?.title, "Fix login")
    }

    func testLoneUntitledSessionNeedsNoLabel() {
        var sessions: [String: ClaudeSession] = [:]
        apply("SessionStart", session: "a", to: &sessions)
        let all = Array(sessions.values)
        XCTAssertNil(all[0].identityLabel(among: all))
    }

    func testUntitledSessionsInSameProjectGetDistinctLabels() throws {
        var sessions: [String: ClaudeSession] = [:]
        apply("SessionStart", session: "aaaaaa111", to: &sessions)
        apply("SessionStart", session: "bbbbbb222", to: &sessions)
        let all = Array(sessions.values)

        let first = try XCTUnwrap(sessions["aaaaaa111"]?.identityLabel(among: all))
        let second = try XCTUnwrap(sessions["bbbbbb222"]?.identityLabel(among: all))
        XCTAssertTrue(first.contains("#aaaaaa"))
        XCTAssertTrue(second.contains("#bbbbbb"))
        XCTAssertNotEqual(first, second)
    }

    func testSameFolderNameInDifferentProjectsStillCountsAsDuplicate() {
        var sessions: [String: ClaudeSession] = [:]
        apply("SessionStart", session: "aaaaaa111", cwd: "/one/app", to: &sessions)
        apply("SessionStart", session: "bbbbbb222", cwd: "/two/app", to: &sessions)
        let all = Array(sessions.values)
        XCTAssertNotNil(sessions["aaaaaa111"]?.identityLabel(among: all))
    }

    func testTitleIsPreferredAndTrimmed() {
        var sessions: [String: ClaudeSession] = [:]
        apply("SessionStart", session: "a", title: "  Fix login\n", to: &sessions)
        apply("SessionStart", session: "b", to: &sessions)
        let all = Array(sessions.values)
        XCTAssertEqual(sessions["a"]?.identityLabel(among: all), "Fix login")
    }

    func testBlankTitleFallsBack() {
        var sessions: [String: ClaudeSession] = [:]
        apply("SessionStart", session: "a", title: "   ", to: &sessions)
        let all = Array(sessions.values)
        XCTAssertNil(sessions["a"]?.identityLabel(among: all))
    }
}
