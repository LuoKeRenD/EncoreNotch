//
//  ClaudeSessionsView.swift
//  LyricsIsland
//

import ClaudeMonitorKit
import Defaults
import SwiftUI

struct ClaudeSessionsView: View {
    @ObservedObject private var monitor = ClaudeMonitor.app

    private func identity(ofSession id: String) -> String? {
        monitor.sessions.first { $0.id == id }?.identityLabel(among: monitor.sessions)
    }

    @ViewBuilder
    private func card(for request: ClaudeApprovalRequest, embedded: Bool) -> some View {
        let identity = identity(ofSession: request.sessionID)
        if request.questions.isEmpty {
            ClaudeApprovalCard(request: request, identity: identity, embedded: embedded) { decision in
                monitor.resolve(request, decision: decision)
            }
        } else {
            ClaudeQuestionCard(request: request, identity: identity, embedded: embedded) { decision in
                monitor.resolve(request, decision: decision)
            }
        }
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
                    // Requests from a session not seen yet have nowhere else to go.
                    let known = Set(monitor.sessions.map(\.id))
                    ForEach(monitor.pendingApprovals.filter { !known.contains($0.sessionID) }) { request in
                        card(for: request, embedded: false)
                    }
                    ForEach(monitor.sessions) { session in
                        let requests = monitor.pendingApprovals.filter { $0.sessionID == session.id }
                        if requests.isEmpty {
                            ClaudeSessionRow(session: session, identity: session.identityLabel(among: monitor.sessions))
                        } else {
                            // A request belongs to its session, so it opens inside that row.
                            VStack(alignment: .leading, spacing: 8) {
                                ClaudeSessionRow(session: session, identity: session.identityLabel(among: monitor.sessions))
                                ForEach(requests) { request in
                                    card(for: request, embedded: true)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                        }
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
    /// Shown inside its session's row, which already names the session.
    var embedded = false
    let onDecision: (ClaudeApprovalDecision) -> Void

    /// The notch opens on hover, so a card must not accept a click the moment it appears.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !embedded {
                    ClaudeSpinner(state: .waitingForApproval(tool: request.toolName))
                        .frame(width: 14)
                }
                Group {
                    if embedded { Text("Wants to use \(request.toolName)") } else { Text("\(identity.map { "\(request.projectName) · \($0)" } ?? request.projectName) wants to use \(request.toolName)") }
                }
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
        // Embedded, the text lines up with the session's title above it.
        .padding(embedded ? EdgeInsets(top: 0, leading: ClaudeSessionRow.titleInset, bottom: 0, trailing: 4) : EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(embedded ? 0 : 0.08)))
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

/// Answers Claude's AskUserQuestion from the notch.
private struct ClaudeQuestionCard: View {
    let request: ClaudeApprovalRequest
    let identity: String?
    /// Shown inside its session's row, which already names the session.
    var embedded = false
    let onDecision: (ClaudeApprovalDecision) -> Void

    /// Chosen option labels per question text.
    @State private var chosen: [String: Set<String>] = [:]
    /// The notch opens on hover, so a card must not accept a click the moment it appears.
    @State private var armed = false

    private var isComplete: Bool {
        request.questions.allSatisfy { !(chosen[$0.question] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !embedded {
                    ClaudeSpinner(state: .waitingForApproval(tool: request.toolName))
                        .frame(width: 14)
                }
                Group {
                    if embedded { Text("Claude asks") } else { Text("\(identity.map { "\(request.projectName) · \($0)" } ?? request.projectName) asks") }
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let header = question.header, !header.isEmpty {
                            Text(header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color(red: 0.85, green: 0.47, blue: 0.34)))
                        }
                        Text(question.question)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if question.multiSelect {
                            Text("Choose any")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(question.options, id: \.label) { option in
                                optionButton(option, in: question)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    onDecision(.pass)
                } label: {
                    capsule("Answer in terminal", fill: Color.white.opacity(0.14))
                }
                .buttonStyle(.plain)
                .disabled(!armed)
                .opacity(armed ? 1 : 0.45)

                Button {
                    onDecision(.answer(answers))
                } label: {
                    capsule("Submit", fill: Color.green.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(!armed || !isComplete)
                .opacity(armed && isComplete ? 1 : 0.45)
            }
        }
        // Embedded, the text lines up with the session's title above it.
        .padding(embedded ? EdgeInsets(top: 0, leading: ClaudeSessionRow.titleInset, bottom: 0, trailing: 4) : EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(embedded ? 0 : 0.08)))
        .task(id: request.id) {
            armed = false
            chosen = [:]
            try? await Task.sleep(for: .milliseconds(800))
            armed = !Task.isCancelled
        }
    }

    /// Labels in the order Claude offered them, joined as Claude Code expects.
    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: request.questions.map { question in
            let picked = chosen[question.question] ?? []
            let labels = question.options.map(\.label).filter(picked.contains)
            return (question.question, labels.joined(separator: ", "))
        })
    }

    private func optionButton(_ option: ClaudeQuestion.Option, in question: ClaudeQuestion) -> some View {
        let selected = chosen[question.question]?.contains(option.label) ?? false
        return Button {
            var picked = chosen[question.question] ?? []
            if question.multiSelect {
                if selected { picked.remove(option.label) } else { picked.insert(option.label) }
            } else {
                picked = [option.label]
            }
            chosen[question.question] = picked
        } label: {
            Text(option.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color(red: 0.95, green: 0.62, blue: 0.48) : Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(option.description ?? "")
        .disabled(!armed)
    }

    private func capsule(_ title: LocalizedStringKey, fill: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let identity: String?

    /// Where the title starts: row padding, spinner and spacing.
    static let titleInset: CGFloat = 4 + 14 + 10

    private var status: String {
        switch session.state {
        case .waitingForInput: return String(localized: "Ready")
        case .working(let tool): return tool.map { String(localized: "Running \($0)") } ?? String(localized: "Working")
        case .waitingForApproval(let tool): return tool.map { String(localized: "Needs approval for \($0)") } ?? String(localized: "Needs your input")
        case .compacting: return String(localized: "Compacting conversation")
        case .failed(let reason): return reason.map { String(localized: "Failed: \($0)") } ?? String(localized: "Failed")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ClaudeSpinner(state: session.state)
                .frame(width: 14)

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
    @Default(.claudeMusicIndicator) private var musicIndicator

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
                Picker("While music plays, show", selection: $musicIndicator) {
                    ForEach(ClaudeMusicIndicator.allCases) { option in
                        Text(LocalizedStringKey(option.rawValue)).tag(option)
                    }
                }
            } header: {
                Text("Closed notch")
            } footer: {
                Text("With Clawd, he works in the spectrum's place and puts it back when a session completes. With the spinner, Clawd takes the whole island only to ask for permission or announce a completed session.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Adds hook entries to \(monitor.paths.settingsFile.path). Your other settings and hooks are kept, but the file is rewritten with sorted keys.")
                Text("The original file is backed up to \(monitor.paths.backupDirectory.path) before each change. Turning this off removes only the entries added here.")
                Text("With notch approvals off, hooks only report session activity and never approve or block anything. Hooks do nothing while this app is not running.")
                Text("With notch approvals on, a permission request waits up to 90 seconds for your answer. The island grows to announce it; click it to answer. Claude's multiple-choice questions can be answered there too. Clicking Allow once runs the action shown. Without an answer, Claude Code's normal permission prompt takes over. Deny rules still apply.")
            } header: {
                Text("What this changes")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Claude Code")
    }
}
