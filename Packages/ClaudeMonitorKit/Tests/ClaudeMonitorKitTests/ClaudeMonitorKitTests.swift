import XCTest
@testable import ClaudeMonitorKit

final class SessionReducerTests: XCTestCase {
    private var sessions: [String: ClaudeSession] = [:]
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func send(_ name: String, tool: String? = nil, notification: String? = nil, error: String? = nil, at offset: TimeInterval = 0) {
        SessionReducer.apply(
            HookEvent(sessionID: "s", name: name, cwd: "/tmp/demo", toolName: tool, notificationType: notification, error: error, timestamp: t0.addingTimeInterval(offset)),
            to: &sessions
        )
    }

    private var state: ClaudeSessionState? { sessions["s"]?.state }

    func testTurnLifecycle() {
        send("SessionStart")
        XCTAssertEqual(state, .waitingForInput)
        XCTAssertEqual(sessions["s"]?.projectName, "demo")
        send("UserPromptSubmit", at: 1)
        XCTAssertEqual(sessions["s"]?.turnStartedAt, t0.addingTimeInterval(1))
        send("PreToolUse", tool: "Bash", at: 2)
        XCTAssertEqual(state, .working(tool: "Bash"))
        send("PermissionRequest", tool: "Bash", at: 3)
        XCTAssertEqual(state, .waitingForApproval(tool: "Bash"))
        send("PostToolUse", tool: "Bash", at: 4)
        XCTAssertEqual(state, .working(tool: nil))
        send("Stop", at: 5)
        XCTAssertEqual(state, .waitingForInput)
        XCTAssertNil(sessions["s"]?.turnStartedAt)
        send("SessionEnd", at: 6)
        XCTAssertNil(sessions["s"])
    }

    func testLatePostToolUseDoesNotRestartFinishedTurn() {
        send("UserPromptSubmit")
        send("Stop", at: 1)
        send("PostToolUse", tool: "Bash", at: 2)
        XCTAssertEqual(state, .waitingForInput)
    }

    func testPermissionNotificationKeepsToolName() {
        send("UserPromptSubmit")
        send("PermissionRequest", tool: "Edit", at: 1)
        send("Notification", notification: "permission_prompt", at: 7)
        XCTAssertEqual(state, .waitingForApproval(tool: "Edit"))
    }

    func testUnrelatedNotificationDoesNotChangeState() {
        send("UserPromptSubmit")
        send("Notification", notification: "auth_success", at: 1)
        XCTAssertEqual(state, .working(tool: nil))
    }

    func testIdlePromptDoesNotInterruptWork() {
        send("UserPromptSubmit")
        send("Notification", notification: "idle_prompt", at: 1)
        XCTAssertEqual(state, .working(tool: nil))
    }

    func testCompactionRestoresPriorState() {
        send("SessionStart")
        send("PreCompact", at: 1)
        XCTAssertEqual(state, .compacting)
        send("PostCompact", at: 2)
        XCTAssertEqual(state, .waitingForInput)
    }

    func testStopFailureThenNewPromptRecovers() {
        send("UserPromptSubmit")
        send("StopFailure", error: "rate_limit", at: 1)
        XCTAssertEqual(state, .failed(reason: "rate_limit"))
        send("UserPromptSubmit", at: 2)
        XCTAssertEqual(state, .working(tool: nil))
    }

    func testSubagentCountNeverNegative() {
        send("SubagentStop")
        XCTAssertEqual(sessions["s"]?.runningSubagents, 0)
        send("SubagentStart", at: 1)
        XCTAssertEqual(sessions["s"]?.runningSubagents, 1)
        send("Stop", at: 2)
        XCTAssertEqual(sessions["s"]?.runningSubagents, 0)
    }

    func testDecodingIgnoresSensitiveFieldsAndRejectsTruncation() throws {
        let json = #"{"session_id":"a","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"secret"},"prompt":"secret"}"#
        let event = try XCTUnwrap(HookEvent(json: Data(json.utf8), timestamp: t0))
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertFalse(String(describing: event).contains("secret"))
        XCTAssertNil(HookEvent(json: Data(json.dropLast(5).utf8), timestamp: t0))
    }
}

final class ClaudeHookInstallerTests: XCTestCase {
    private var root: URL!
    private var paths: ClaudeMonitorPaths!
    private var installer: ClaudeHookInstaller!

    override func setUpWithError() throws {
        // A path with a space and a quote, to exercise shell quoting.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude monitor's \(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        paths = ClaudeMonitorPaths(claudeConfigDirectory: config, supportDirectory: root.appendingPathComponent("support"))
        installer = ClaudeHookInstaller(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSettings(_ text: String) throws {
        try Data(text.utf8).write(to: paths.settingsFile)
    }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsFile)) as? [String: Any])
    }

    private func backups() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: paths.backupDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    func testInstallPreservesOtherSettingsAndHooksAndBacksUp() throws {
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"flag":true}"#
        try writeSettings(original)
        try installer.install()

        let result = try settings()
        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertEqual(result["flag"] as? Bool, true)
        let stop = try XCTUnwrap((result["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(ClaudeHookInstaller.events))

        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try String(contentsOf: backups()[0]), original)
    }

    func testInstallIsIdempotentAndDoesNotBackUpAgain() throws {
        try writeSettings(#"{"model":"opus"}"#)
        try installer.install()
        let once = try Data(contentsOf: paths.settingsFile)
        try installer.install()
        XCTAssertEqual(try Data(contentsOf: paths.settingsFile), once)
        XCTAssertEqual(backups().count, 1)
    }

    func testUninstallRestoresEquivalentSettingsAndKeepsOtherHooks() throws {
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try writeSettings(original)
        try installer.install()
        try installer.uninstall()

        let result = try settings() as NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
        XCTAssertEqual(result, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hookScript.path))
        XCTAssertFalse(backups().isEmpty)
    }

    func testUninstallKeepsHandlerSharingAGroup() throws {
        try installer.install()
        var result = try settings()
        var hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers.append(["type": "command", "command": "say done"])
        groups[0]["hooks"] = handlers
        hooks["Stop"] = groups
        result["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: result).write(to: paths.settingsFile)

        try installer.uninstall()
        let after = try settings()
        let stop = try XCTUnwrap((after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "say done")
    }

    func testMalformedSettingsAreNeverRewritten() throws {
        let broken = #"{"model": "opus", // comment"#
        try writeSettings(broken)
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(try String(contentsOf: paths.settingsFile), broken)
    }

    func testUnexpectedHooksShapeIsNeverRewritten() throws {
        let odd = #"{"hooks":{"Stop":"nope"}}"#
        try writeSettings(odd)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: paths.settingsFile), odd)
    }

    func testMissingSettingsFileIsCreated() throws {
        try installer.install()
        XCTAssertNotNil(try settings()["hooks"])
        XCTAssertTrue(backups().isEmpty)
    }

    func testSymlinkedSettingsStayLinked() throws {
        let real = root.appendingPathComponent("real-settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: paths.settingsFile, withDestinationURL: real)
        try installer.install()

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.settingsFile.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        XCTAssertNotNil(content["hooks"])
    }

    // MARK: - Hook script

    private func runHook(payload: String) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", installer.hookCommand]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
    }

    private func spooled() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.spoolDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    func testScriptSpoolsWhenAppIsRunningAndStaysSilent() throws {
        try installer.install()
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: paths.pidFile)

        let payload = #"{"session_id":"a","hook_event_name":"Stop"}"#
        let result = try runHook(payload: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(spooled().first)), payload)
    }

    func testScriptDoesNothingWhenAppIsNotRunning() throws {
        try installer.install()
        for pid in [nil, "999999"] {
            if let pid {
                try Data(pid.utf8).write(to: paths.pidFile)
            }
            let result = try runHook(payload: #"{"session_id":"a","hook_event_name":"Stop"}"#)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(spooled().isEmpty)
        }
    }

    func testOversizedPayloadStillExitsCleanly() throws {
        try installer.install()
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: paths.pidFile)
        let big = String(repeating: "x", count: ClaudeHookInstaller.maxPayloadBytes + 4096)
        let result = try runHook(payload: #"{"session_id":"a","hook_event_name":"Stop","x":""# + big + #""}"#)
        XCTAssertEqual(result.status, 0)
        let data = try Data(contentsOf: XCTUnwrap(spooled().first))
        XCTAssertEqual(data.count, ClaudeHookInstaller.maxPayloadBytes)
        XCTAssertNil(HookEvent(json: data, timestamp: Date()))
    }

    func testSpoolDeliversInOrderAndDeletes() throws {
        try FileManager.default.createDirectory(at: paths.spoolDirectory, withIntermediateDirectories: true)
        let fm = FileManager.default
        for (index, name) in ["UserPromptSubmit", "PreToolUse", "Stop"].enumerated() {
            let url = paths.spoolDirectory.appendingPathComponent("z\(9 - index).json")
            try Data(#"{"session_id":"a","hook_event_name":"\#(name)"}"#.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index) - 10)], ofItemAtPath: url.path)
        }
        try Data("not json".utf8).write(to: paths.spoolDirectory.appendingPathComponent("bad.json"))

        let delivered = expectation(description: "events")
        let spool = EventSpool(directory: paths.spoolDirectory, pidFile: paths.pidFile) { events in
            XCTAssertEqual(events.map(\.name), ["UserPromptSubmit", "PreToolUse", "Stop"])
            delivered.fulfill()
        }
        try spool.start()
        wait(for: [delivered], timeout: 5)
        spool.stop()
        XCTAssertTrue(spooled().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: paths.pidFile.path))
    }
}
