//
//  ClawdStage.swift
//  EncoreNotch
//

import ClaudeMonitorKit
import Combine
import Defaults
import Foundation

/// What the closed notch shows for Claude Code while music plays.
enum ClaudeMusicIndicator: String, CaseIterable, Identifiable, Defaults.Serializable {
    case clawd = "Clawd"
    case spinner = "Spinner"

    var id: String { rawValue }
}

extension Defaults.Keys {
    static let claudeMusicIndicator = Key<ClaudeMusicIndicator>("claudeMusicIndicator", default: .clawd)
}

/// What Clawd is doing in the closed notch, most urgent first.
enum ClawdPhase: Equatable {
    case none
    case working(typing: Bool)
    case attention(question: Bool)
    case celebrating

    /// The island grows and shows a caption.
    var isAnnouncing: Bool {
        switch self {
        case .attention, .celebrating: return true
        case .none, .working: return false
        }
    }

    var caption: String? {
        switch self {
        case .attention(question: true): return String(localized: "Clawd has a question")
        case .attention(question: false): return String(localized: "Clawd needs permission")
        case .celebrating: return String(localized: "Clawd session complete")
        case .none, .working: return nil
        }
    }
}

/// Notices sessions finishing a turn, so Clawd can celebrate for a moment.
@MainActor
final class ClawdStage: ObservableObject {
    static let shared = ClawdStage()

    @Published private(set) var isCelebrating = false

    private var previousStates: [String: ClaudeSessionState] = [:]
    private var cancellable: AnyCancellable?
    private var endTask: Task<Void, Never>?

    private init() {
        cancellable = ClaudeMonitor.app.$sessions.sink { [weak self] sessions in
            self?.observe(sessions)
        }
    }

    func phase(for monitor: ClaudeMonitor) -> ClawdPhase {
        for session in monitor.sessions {
            if case .waitingForApproval(let tool) = session.state {
                return .attention(question: tool == "AskUserQuestion")
            }
        }
        if isCelebrating { return .celebrating }
        switch monitor.activity {
        case .working: return .working(typing: true)
        case .needsAttention: return .working(typing: false)
        case .none: return .none
        }
    }

    private func observe(_ sessions: [ClaudeSession]) {
        var finished = false
        for session in sessions {
            guard session.state == .waitingForInput, let previous = previousStates[session.id] else { continue }
            switch previous {
            case .working, .compacting, .waitingForApproval: finished = true
            case .waitingForInput, .failed: break
            }
        }
        previousStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        if finished { celebrate() }
    }

    private func celebrate() {
        endTask?.cancel()
        isCelebrating = true
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ClawdTiming.celebration))
            guard !Task.isCancelled else { return }
            self?.isCelebrating = false
        }
    }
}
