//
//  ClaudeSessionsView.swift
//  LyricsIsland
//

import ClaudeMonitorKit
import Defaults
import SwiftUI

struct ClaudeActivityDot: View {
    let activity: ClaudeActivity
    var size: CGFloat = 7
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(activity == .needsAttention ? Color.red : Color.orange)
            .frame(width: size, height: size)
            .opacity(activity == .working && dimmed ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

struct ClaudeSessionsView: View {
    @ObservedObject private var monitor = ClaudeMonitor.app

    var body: some View {
        if monitor.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.title2)
                Text("No active Claude Code sessions")
                    .font(.subheadline)
            }
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(monitor.sessions) { session in
                        ClaudeSessionRow(session: session, identity: session.identityLabel(among: monitor.sessions))
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let identity: String?

    private var activity: ClaudeActivity {
        switch session.state {
        case .working, .compacting: return .working
        case .waitingForApproval, .failed: return .needsAttention
        case .waitingForInput: return .none
        }
    }

    private var status: String {
        switch session.state {
        case .waitingForInput: return "Ready"
        case .working(let tool): return tool.map { "Running \($0)" } ?? "Working"
        case .waitingForApproval(let tool): return tool.map { "Needs approval for \($0)" } ?? "Needs your input"
        case .compacting: return "Compacting conversation"
        case .failed(let reason): return reason.map { "Failed: \($0)" } ?? "Failed"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if activity == .none {
                    Circle().fill(.gray.opacity(0.5)).frame(width: 7, height: 7)
                } else {
                    ClaudeActivityDot(activity: activity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let identity {
                        Text(identity)
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if session.runningSubagents > 0 {
                Label("\(session.runningSubagents)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            if let started = session.turnStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: started, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ClaudeSettings: View {
    @ObservedObject private var monitor = ClaudeMonitor.app
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    private var enabled: Binding<Bool> {
        Binding(
            get: { monitor.isEnabled },
            set: { on in
                if on {
                    monitor.enable()
                } else {
                    monitor.disable()
                    if coordinator.currentView == .claude { coordinator.currentView = .home }
                }
                Defaults[.claudeMonitorEnabled] = monitor.isEnabled
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show live Claude Code sessions", isOn: enabled)
                if let error = monitor.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Monitoring")
            }

            Section {
                Text("Adds hook entries to \(monitor.paths.settingsFile.path). Your other settings and hooks are kept, but the file is rewritten with sorted keys.")
                Text("The original file is backed up to \(monitor.paths.backupDirectory.path) before each change. Turning this off removes only the entries added here.")
                Text("Hooks only report session activity to this app. They never approve or block anything, and do nothing while this app is not running.")
            } header: {
                Text("What this changes")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Claude Code")
    }
}
