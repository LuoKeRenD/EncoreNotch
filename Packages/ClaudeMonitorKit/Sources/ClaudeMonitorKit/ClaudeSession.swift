import Foundation

public enum ClaudeSessionState: Equatable, Sendable {
    case waitingForInput
    case working(tool: String?)
    case waitingForApproval(tool: String?)
    case compacting
    case failed(reason: String?)
}

public struct ClaudeSession: Identifiable, Equatable, Sendable {
    public let id: String
    public var cwd: String?
    public var transcriptPath: String?
    public var state: ClaudeSessionState
    public var turnStartedAt: Date?
    public var lastActivity: Date
    public var runningSubagents: Int
    var stateBeforeCompact: ClaudeSessionState?

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    init(id: String, timestamp: Date) {
        self.id = id
        self.state = .waitingForInput
        self.lastActivity = timestamp
        self.runningSubagents = 0
    }
}

/// Folds hook events into session state. Pure, so it can be tested directly.
public enum SessionReducer {
    public static func apply(_ event: HookEvent, to sessions: inout [String: ClaudeSession]) {
        if event.name == "SessionEnd" {
            sessions[event.sessionID] = nil
            return
        }

        var session = sessions[event.sessionID] ?? ClaudeSession(id: event.sessionID, timestamp: event.timestamp)
        session.lastActivity = max(session.lastActivity, event.timestamp)
        session.cwd = event.cwd ?? session.cwd
        session.transcriptPath = event.transcriptPath ?? session.transcriptPath

        switch event.name {
        case "UserPromptSubmit":
            session.state = .working(tool: nil)
            session.turnStartedAt = event.timestamp
        case "PreToolUse":
            session.state = .working(tool: event.toolName)
            session.turnStartedAt = session.turnStartedAt ?? event.timestamp
        case "PermissionRequest":
            session.state = .waitingForApproval(tool: event.toolName)
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            // A background task can report after the turn already ended.
            if session.turnStartedAt != nil {
                session.state = .working(tool: nil)
            }
        case "Notification":
            applyNotification(event, to: &session)
        case "Stop":
            endTurn(&session, state: .waitingForInput)
        case "StopFailure":
            endTurn(&session, state: .failed(reason: event.error))
        case "SubagentStart":
            session.runningSubagents += 1
        case "SubagentStop":
            session.runningSubagents = max(0, session.runningSubagents - 1)
        case "PreCompact":
            session.stateBeforeCompact = session.state
            session.state = .compacting
        case "PostCompact":
            session.state = session.stateBeforeCompact ?? .waitingForInput
            session.stateBeforeCompact = nil
        default:
            break
        }

        sessions[event.sessionID] = session
    }

    private static func applyNotification(_ event: HookEvent, to session: inout ClaudeSession) {
        switch event.notificationType {
        case "permission_prompt":
            // PermissionRequest normally arrived first and already named the tool.
            if case .waitingForApproval = session.state { return }
            session.state = .waitingForApproval(tool: nil)
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            session.state = .waitingForApproval(tool: nil)
        case "idle_prompt":
            if session.turnStartedAt == nil { session.state = .waitingForInput }
        default:
            break
        }
    }

    private static func endTurn(_ session: inout ClaudeSession, state: ClaudeSessionState) {
        session.state = state
        session.turnStartedAt = nil
        session.runningSubagents = 0
        session.stateBeforeCompact = nil
    }
}
