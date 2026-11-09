import XCTest
@testable import ClaudeMonitorKit

final class EventSpoolPidTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSpool() -> (EventSpool, URL) {
        let pidFile = root.appendingPathComponent("monitor.pid")
        return (EventSpool(directory: root.appendingPathComponent("events"), pidFile: pidFile) { _ in }, pidFile)
    }

    func testStopRemovesItsOwnPidFile() throws {
        let (spool, pidFile) = makeSpool()
        try spool.start()
        spool.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    /// A relaunching app can start the new process before the old one exits.
    func testStopLeavesAPidFileWrittenByANewerProcess() throws {
        let (spool, pidFile) = makeSpool()
        try spool.start()
        try Data("999999".utf8).write(to: pidFile)
        spool.stop()
        XCTAssertEqual(try String(contentsOf: pidFile), "999999")
    }
}
