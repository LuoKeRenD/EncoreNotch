import Foundation

/// Watches the spool directory, delivering each event once and deleting it.
final class EventSpool {
    private let directory: URL
    private let pidFile: URL
    private let queue = DispatchQueue(label: "ClaudeMonitorKit.EventSpool")
    private let handler: @Sendable ([HookEvent]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    /// Events older than this were left by a previous run and are not current.
    private let maxEventAge: TimeInterval = 3600

    init(directory: URL, pidFile: URL, handler: @escaping @Sendable ([HookEvent]) -> Void) {
        self.directory = directory
        self.pidFile = pidFile
        self.handler = handler
    }

    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: pidFile, options: .atomic)

        queue.async { [self] in
            guard source == nil else { return }
            let descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: .write, queue: queue
                )
                watcher.setEventHandler { [weak self] in self?.drain() }
                watcher.setCancelHandler { close(descriptor) }
                watcher.resume()
                source = watcher
            }

            // Safety net in case the directory is replaced while being watched.
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
            poll.setEventHandler { [weak self] in self?.drain() }
            poll.resume()
            timer = poll

            drain()
        }
    }

    func stop() {
        try? FileManager.default.removeItem(at: pidFile)
        queue.sync {
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
        }
    }

    private func drain() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        // APFS modification times have sub-second resolution, which orders events.
        let files = urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date())
            }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }

        guard !files.isEmpty else { return }

        let oldest = Date().addingTimeInterval(-maxEventAge)
        var events: [HookEvent] = []
        for (url, date) in files {
            defer { try? fm.removeItem(at: url) }
            guard date >= oldest, let data = try? Data(contentsOf: url) else { continue }
            if let event = HookEvent(json: data, timestamp: date) {
                events.append(event)
            }
        }
        if !events.isEmpty { handler(events) }
    }
}

private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
