import Combine
import Foundation

public enum ClaudeActivity: Equatable, Sendable {
    case none
    case working
    case needsAttention
}

/// Monitors Claude Code sessions through its documented hooks.
@MainActor
public final class ClaudeMonitor: ObservableObject {
    @Published public private(set) var sessions: [ClaudeSession] = []
    @Published public private(set) var isEnabled = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var approvalsEnabled = false
    @Published public private(set) var pendingApprovals: [ClaudeApprovalRequest] = []

    public let paths: ClaudeMonitorPaths
    private let installer: ClaudeHookInstaller
    private var spool: EventSpool?
    private var approvals: ApprovalQueue?
    private var pruneTimer: Timer?
    private var byID: [String: ClaudeSession] = [:]

    /// A session with neither hook events nor transcript writes for this long
    /// is assumed gone. If it is still alive, its next event brings it back.
    private let staleAfter: TimeInterval = 30 * 60

    public init(paths: ClaudeMonitorPaths) {
        self.paths = paths
        self.installer = ClaudeHookInstaller(paths: paths)
    }

    public var activity: ClaudeActivity {
        var result = ClaudeActivity.none
        for session in sessions {
            switch session.state {
            case .waitingForApproval, .failed:
                return .needsAttention
            case .working, .compacting:
                result = .working
            case .waitingForInput:
                break
            }
        }
        return result
    }

    /// Installs the hooks and starts watching. Failures are left in `lastError`.
    public func enable(approvals allowApprovals: Bool = false) {
        do {
            try installer.install(approvals: allowApprovals)
            try startWatching()
            try setApprovalQueueRunning(allowApprovals)
            isEnabled = true
            lastError = nil
        } catch {
            stopWatching()
            isEnabled = false
            lastError = error.localizedDescription
        }
    }

    /// Adds or removes the approval hook while monitoring stays on.
    public func setApprovalsEnabled(_ enabled: Bool) {
        guard isEnabled else { return }
        do {
            // Stopping first returns anything still waiting to Claude Code.
            if !enabled { try setApprovalQueueRunning(false) }
            try installer.install(approvals: enabled)
            if enabled { try setApprovalQueueRunning(true) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Answers one request. Expired requests are ignored.
    public func resolve(_ request: ClaudeApprovalRequest, decision: ClaudeApprovalDecision) {
        approvals?.respond(id: request.id, decision: decision)
        pendingApprovals.removeAll { $0.id == request.id }
        if decision != .pass, var session = byID[request.sessionID] {
            session.state = .working(tool: nil)
            byID[request.sessionID] = session
            publish()
        }
    }

    /// Stops watching and removes only this app's hook entries.
    public func disable() {
        stopWatching()
        isEnabled = false
        do {
            try installer.uninstall()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        byID = [:]
        publish()
    }

    /// Stops watching but leaves the hooks installed. They do nothing until the app runs again.
    public func suspend() {
        stopWatching()
    }

    private func startWatching() throws {
        guard spool == nil else { return }
        let spool = EventSpool(directory: paths.spoolDirectory, pidFile: paths.pidFile) { [weak self] events in
            Task { @MainActor in self?.receive(events) }
        }
        try spool.start()
        self.spool = spool

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStaleSessions() }
        }
    }

    private func stopWatching() {
        try? setApprovalQueueRunning(false)
        spool?.stop()
        spool = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func setApprovalQueueRunning(_ running: Bool) throws {
        if running {
            guard approvals == nil else { return }
            let queue = ApprovalQueue(
                directory: paths.approvalDirectory,
                waitSeconds: TimeInterval(installer.approvalWaitSeconds)
            ) { [weak self] pending in
                Task { @MainActor in self?.pendingApprovals = pending }
            }
            try queue.start()
            approvals = queue
            approvalsEnabled = true
        } else {
            approvals?.stop()
            approvals = nil
            approvalsEnabled = false
            pendingApprovals = []
        }
    }

    private func receive(_ events: [HookEvent]) {
        for event in events {
            SessionReducer.apply(event, to: &byID)
            dismissApprovalsSettled(by: event)
        }
        publish()
    }

    /// If the request was answered elsewhere, its card must not stay on screen.
    private func dismissApprovalsSettled(by event: HookEvent) {
        let matchesTool: Bool
        switch event.name {
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            matchesTool = true
        case "Stop", "StopFailure", "SessionEnd", "UserPromptSubmit":
            matchesTool = false
        default:
            return
        }
        for request in pendingApprovals
        where request.sessionID == event.sessionID
            && request.receivedAt <= event.timestamp
            && (!matchesTool || request.toolName == event.toolName) {
            resolve(request, decision: .pass)
        }
    }

    private func pruneStaleSessions() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let before = byID.count
        byID = byID.filter { _, session in
            if session.lastActivity >= cutoff { return true }
            guard let path = session.transcriptPath,
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { return false }
            return modified >= cutoff
        }
        if byID.count != before { publish() }
    }

    private func publish() {
        func rank(_ state: ClaudeSessionState) -> Int {
            switch state {
            case .waitingForApproval, .failed: return 0
            case .working, .compacting: return 1
            case .waitingForInput: return 2
            }
        }
        sessions = byID.values.sorted {
            let (a, b) = (rank($0.state), rank($1.state))
            return a == b ? $0.lastActivity > $1.lastActivity : a < b
        }
    }
}
