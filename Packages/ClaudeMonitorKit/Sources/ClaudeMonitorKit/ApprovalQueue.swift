import Foundation

/// One multiple-choice question from Claude Code's AskUserQuestion tool.
public struct ClaudeQuestion: Identifiable, Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String?
    }

    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    public var id: String { question }

    init?(_ object: Any) {
        guard let object = object as? [String: Any],
              let question = object["question"] as? String, !question.isEmpty,
              let options = object["options"] as? [[String: Any]]
        else { return nil }
        let parsed = options.compactMap { option -> Option? in
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            return Option(label: label, description: option["description"] as? String)
        }
        guard !parsed.isEmpty, parsed.count == options.count else { return nil }
        self.question = question
        self.header = object["header"] as? String
        self.options = parsed
        self.multiSelect = object["multiSelect"] as? Bool ?? false
    }
}

public struct ClaudeApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let cwd: String?
    public let toolName: String
    /// The complete action being approved. Requests too long to show in full
    /// are handed back to Claude Code instead of being shown truncated.
    public let detail: String
    /// For AskUserQuestion: the questions to answer. Empty for other tools.
    public let questions: [ClaudeQuestion]
    /// The tool's input exactly as received, echoed back alongside answers.
    let toolInput: Data
    public let receivedAt: Date
    public let expiresAt: Date

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Returns nil for anything the notch should not answer.
    init?(json: Data, id: String, receivedAt: Date, expiresAt: Date) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let sessionID = root["session_id"] as? String,
              let toolName = root["tool_name"] as? String,
              !Self.interactiveTools.contains(toolName),
              let input = root["tool_input"] as? [String: Any]
        else { return nil }

        var questions: [ClaudeQuestion] = []
        let detail: String
        if toolName == Self.questionTool {
            guard let list = input["questions"] as? [Any], !list.isEmpty else { return nil }
            questions = list.compactMap(ClaudeQuestion.init)
            guard questions.count == list.count,
                  Set(questions.map(\.question)).count == questions.count
            else { return nil }
            detail = questions.map(\.question).joined(separator: "\n")
        } else if toolName == "Bash", let command = input["command"] as? String {
            detail = command
        } else {
            guard let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else { return nil }
            detail = String(decoding: data, as: UTF8.self)
        }
        guard !detail.isEmpty, detail.count <= Self.maxDetailLength,
              let toolInput = try? JSONSerialization.data(withJSONObject: input)
        else { return nil }

        self.id = id
        self.sessionID = sessionID
        self.cwd = root["cwd"] as? String
        self.toolName = toolName
        self.detail = detail
        self.questions = questions
        self.toolInput = toolInput
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }

    static let questionTool = "AskUserQuestion"
    /// Plan approval needs more than a simple allow and is left to Claude Code.
    private static let interactiveTools: Set<String> = ["ExitPlanMode"]
    private static let maxDetailLength = 20_000
}

public enum ClaudeApprovalDecision: Equatable, Sendable {
    case allow
    case deny
    /// Hand the request back to Claude Code's normal permission flow.
    case pass
    /// Answers an AskUserQuestion request: question text to the chosen
    /// option label, with several labels joined by commas.
    case answer([String: String])

    func responseBody(for request: ClaudeApprovalRequest?) -> Data {
        func output(_ decision: String) -> Data {
            Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":\#(decision)}}"#.utf8)
        }
        switch self {
        case .allow: return output(#"{"behavior":"allow"}"#)
        case .deny: return output(#"{"behavior":"deny","message":"Denied from the LyricsIsland notch."}"#)
        case .pass: return Data()
        case .answer(let answers):
            // Documented for AskUserQuestion: allow with the original input plus `answers`.
            guard let request, !request.questions.isEmpty,
                  Set(answers.keys) == Set(request.questions.map(\.question)),
                  var input = (try? JSONSerialization.jsonObject(with: request.toolInput)) as? [String: Any]
            else { return Data() }
            input["answers"] = answers
            let body: [String: Any] = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": input],
            ]]
            return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        }
    }
}

/// Tracks requests published by the approval hook and writes back answers.
/// A request file exists only while its hook is still waiting.
final class ApprovalQueue {
    private let directory: URL
    private let waitSeconds: TimeInterval
    private let queue = DispatchQueue(label: "ClaudeMonitorKit.ApprovalQueue")
    private let handler: @Sendable ([ClaudeApprovalRequest]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var known: [String: ClaudeApprovalRequest] = [:]
    private var answered: Set<String> = []
    private var lastDelivered: [ClaudeApprovalRequest] = []

    init(directory: URL, waitSeconds: TimeInterval, handler: @escaping @Sendable ([ClaudeApprovalRequest]) -> Void) {
        self.directory = directory
        self.waitSeconds = waitSeconds
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        queue.async { [self] in
            guard source == nil else { return }
            let descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: .write, queue: queue
                )
                watcher.setEventHandler { [weak self] in self?.scan() }
                watcher.setCancelHandler { close(descriptor) }
                watcher.resume()
                source = watcher
            }
            // Also drives expiry, which produces no file system event.
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            poll.setEventHandler { [weak self] in self?.scan() }
            poll.resume()
            timer = poll
            scan()
        }
    }

    /// Stops watching and returns every waiting request to Claude Code.
    func stop() {
        queue.sync {
            for id in known.keys where !answered.contains(id) {
                write(.pass, id: id, request: nil)
            }
            known = [:]
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
        }
    }

    func respond(id: String, decision: ClaudeApprovalDecision) {
        queue.async { [self] in
            guard let request = known[id], !answered.contains(id), request.expiresAt > Date() else { return }
            if case .answer = decision, request.questions.isEmpty { return }
            write(decision, id: id, request: request)
            answered.insert(id)
            deliver()
        }
    }

    private func write(_ decision: ClaudeApprovalDecision, id: String, request: ClaudeApprovalRequest?) {
        // Renamed into place so the hook never reads a partial answer.
        let temporary = directory.appendingPathComponent(".resp.\(UUID().uuidString)")
        let destination = directory.appendingPathComponent("\(id).response.json")
        guard (try? decision.responseBody(for: request).write(to: temporary)) != nil else { return }
        if rename(temporary.path, destination.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private func scan() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        let now = Date()
        let suffix = ".request.json"
        var present = Set<String>()

        for url in urls where url.lastPathComponent.hasSuffix(suffix) {
            let id = String(url.lastPathComponent.dropLast(suffix.count))
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? now
            let expiry = date.addingTimeInterval(waitSeconds)

            // A hook that was killed outright cannot clean up after itself.
            if now > expiry.addingTimeInterval(30) {
                try? fm.removeItem(at: url)
                continue
            }
            present.insert(id)
            guard known[id] == nil, !answered.contains(id) else { continue }

            if let data = try? Data(contentsOf: url),
               let request = ClaudeApprovalRequest(json: data, id: id, receivedAt: date, expiresAt: expiry) {
                known[id] = request
            } else {
                write(.pass, id: id, request: nil)
                answered.insert(id)
            }
        }

        known = known.filter { present.contains($0.key) }
        answered.formIntersection(present)
        deliver()
    }

    private func deliver() {
        let now = Date()
        let pending = known.values
            .filter { !answered.contains($0.id) && $0.expiresAt > now }
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt }
        guard pending != lastDelivered else { return }
        lastDelivered = pending
        handler(pending)
    }
}
