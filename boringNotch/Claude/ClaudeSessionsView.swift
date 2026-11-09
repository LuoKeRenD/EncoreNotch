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

    private func identity(ofSession id: String) -> String? {
        monitor.sessions.first { $0.id == id }?.identityLabel(among: monitor.sessions)
    }

    var body: some View {
        if monitor.sessions.isEmpty && monitor.pendingApprovals.isEmpty {
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
                    ForEach(monitor.pendingApprovals) { request in
                        ClaudeApprovalCard(request: request, identity: identity(ofSession: request.sessionID)) { decision in
                            monitor.resolve(request, decision: decision)
                        }
                    }
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

private struct ClaudeApprovalCard: View {
    let request: ClaudeApprovalRequest
    let identity: String?
    let onDecision: (ClaudeApprovalDecision) -> Void

    /// The notch opens on hover, so a card must not accept a click the moment it appears.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ClaudeActivityDot(activity: .needsAttention)
                Text("\(identity.map { "\(request.projectName) · \($0)" } ?? request.projectName) wants to use \(request.toolName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ScrollView {
                Text(request.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 44)

            HStack(spacing: 8) {
                Spacer()
                decisionButton("Deny", fill: Color.white.opacity(0.14), decision: .deny)
                decisionButton("Allow once", fill: Color.green.opacity(0.75), decision: .allow)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
        .task(id: request.id) {
            armed = false
            try? await Task.sleep(for: .milliseconds(800))
            armed = !Task.isCancelled
        }
    }

    private func decisionButton(_ title: String, fill: Color, decision: ClaudeApprovalDecision) -> some View {
        Button {
            onDecision(decision)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!armed)
        .opacity(armed ? 1 : 0.45)
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
                if !monitor.isEnabled { Defaults[.claudeApprovalsEnabled] = false }
            }
        )
    }

    private var approvals: Binding<Bool> {
        Binding(
            get: { monitor.approvalsEnabled },
            set: { on in
                monitor.setApprovalsEnabled(on)
                Defaults[.claudeApprovalsEnabled] = monitor.approvalsEnabled
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show live Claude Code sessions", isOn: enabled)
                Toggle("Approve permission requests from the notch", isOn: approvals)
                    .disabled(!monitor.isEnabled)
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
                Text("With notch approvals off, hooks only report session activity and never approve or block anything. Hooks do nothing while this app is not running.")
                Text("With notch approvals on, a permission request waits up to 90 seconds for your answer in the notch and opens it automatically. Clicking Allow once runs the action shown. Without an answer, Claude Code's normal permission prompt takes over. Deny rules still apply.")
            } header: {
                Text("What this changes")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Claude Code")
    }
}
