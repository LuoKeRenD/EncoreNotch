import Foundation

/// A Claude Code lifecycle event. Only the fields the monitor displays are
/// decoded, so prompts, tool input and tool output never reach memory here.
public struct HookEvent: Equatable, Sendable {
    public var sessionID: String
    public var name: String
    public var cwd: String?
    public var transcriptPath: String?
    public var toolName: String?
    public var notificationType: String?
    public var error: String?
    public var timestamp: Date

    public init(
        sessionID: String,
        name: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        error: String? = nil,
        timestamp: Date
    ) {
        self.sessionID = sessionID
        self.name = name
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.notificationType = notificationType
        self.error = error
        self.timestamp = timestamp
    }

    private struct Payload: Decodable {
        let session_id: String
        let hook_event_name: String
        let cwd: String?
        let transcript_path: String?
        let tool_name: String?
        let notification_type: String?
        let error: String?
    }

    /// Returns nil for malformed or truncated payloads.
    public init?(json: Data, timestamp: Date) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(
            sessionID: payload.session_id,
            name: payload.hook_event_name,
            cwd: payload.cwd,
            transcriptPath: payload.transcript_path,
            toolName: payload.tool_name,
            notificationType: payload.notification_type,
            error: payload.error,
            timestamp: timestamp
        )
    }
}
