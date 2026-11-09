import Foundation

public struct ClaudeMonitorPaths: Equatable, Sendable {
    public let settingsFile: URL
    public let hookScript: URL
    public let spoolDirectory: URL
    public let pidFile: URL
    public let backupDirectory: URL

    public init(claudeConfigDirectory: URL, supportDirectory: URL) {
        settingsFile = claudeConfigDirectory.appendingPathComponent("settings.json")
        hookScript = supportDirectory.appendingPathComponent("claude-hook.sh")
        spoolDirectory = supportDirectory.appendingPathComponent("claude-events", isDirectory: true)
        pidFile = supportDirectory.appendingPathComponent("monitor.pid")
        backupDirectory = supportDirectory.appendingPathComponent("settings-backups", isDirectory: true)
    }

    public static func standard(
        appSupportName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeMonitorPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/\(appSupportName)", isDirectory: true)
        return ClaudeMonitorPaths(claudeConfigDirectory: config, supportDirectory: support)
    }
}

public enum ClaudeHookInstallerError: LocalizedError, Equatable {
    case malformedSettings(String)

    public var errorDescription: String? {
        switch self {
        case .malformedSettings(let detail):
            return "Claude settings were left unchanged because they could not be read: \(detail)"
        }
    }
}

/// Adds and removes this app's hook entries in Claude Code's settings.
/// Other settings and other hooks are preserved, and the original file is
/// backed up before any change. Malformed settings are never rewritten.
public struct ClaudeHookInstaller: Sendable {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PostToolUseFailure", "PermissionDenied", "Notification", "Stop", "StopFailure",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "SessionEnd",
    ]

    /// Payloads above this size are cut off and then dropped as invalid JSON.
    static let maxPayloadBytes = 1_048_576

    public let paths: ClaudeMonitorPaths

    public init(paths: ClaudeMonitorPaths) {
        self.paths = paths
    }

    /// The exact command string, used to recognise this app's entries.
    public var hookCommand: String { Self.shellQuoted(paths.hookScript.path) }

    public func install() throws {
        try writeHookScript()
        var root = try readSettings()
        var hooks = try hooksObject(in: root)

        for event in Self.events {
            guard var groups = hooks[event] as? [[String: Any]] ?? (hooks[event] == nil ? [] : nil) else {
                throw ClaudeHookInstallerError.malformedSettings("hooks.\(event) is not a list")
            }
            if !groups.contains(where: containsOurHandler) {
                groups.append(["hooks": [["type": "command", "command": hookCommand, "timeout": 5] as [String: Any]]])
            }
            hooks[event] = groups
        }

        root["hooks"] = hooks
        try writeSettings(root)
    }

    public func uninstall() throws {
        var root = try readSettings()
        var hooks = try hooksObject(in: root)

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let remaining = groups.compactMap(removingOurHandler)
            hooks[event] = remaining.isEmpty ? nil : remaining
        }

        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(root)

        let fm = FileManager.default
        try? fm.removeItem(at: paths.hookScript)
        try? fm.removeItem(at: paths.spoolDirectory)
    }

    // MARK: - Settings

    private func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: paths.settingsFile) else {
            if FileManager.default.fileExists(atPath: paths.settingsFile.path) {
                throw ClaudeHookInstallerError.malformedSettings("the file is not readable")
            }
            return [:]
        }
        if data.isEmpty { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeHookInstallerError.malformedSettings("the file is not a JSON object")
        }
        return root
    }

    private func hooksObject(in root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw ClaudeHookInstallerError.malformedSettings("hooks is not an object")
        }
        return hooks
    }

    private func writeSettings(_ root: [String: Any]) throws {
        // Follow a symlink so dotfile-managed settings stay linked.
        let target = paths.settingsFile.resolvingSymlinksInPath()
        let fm = FileManager.default
        let existing = try? Data(contentsOf: target)

        if let existing, !existing.isEmpty,
           let current = try? JSONSerialization.jsonObject(with: existing) as? NSDictionary,
           current.isEqual(to: root) {
            return
        }
        if existing == nil && root.isEmpty { return }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if let existing { try backUp(existing) }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    private func backUp(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: paths.backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "settings-\(formatter.string(from: Date())).json"
        let url = paths.backupDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func containsOurHandler(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { $0["command"] as? String == hookCommand }
    }

    /// Returns the group without our handler, or nil if nothing remains.
    private func removingOurHandler(_ group: [String: Any]) -> [String: Any]? {
        guard containsOurHandler(group), let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let remaining = handlers.filter { $0["command"] as? String != hookCommand }
        if remaining.isEmpty { return nil }
        var updated = group
        updated["hooks"] = remaining
        return updated
    }

    // MARK: - Script

    private func writeHookScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: paths.hookScript.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(hookScript.utf8).write(to: paths.hookScript, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.hookScript.path)
    }

    /// Records one event for the app. It prints nothing and always exits 0, so
    /// Claude Code proceeds exactly as if the hook were not installed. Each
    /// event is renamed into place so concurrent hooks cannot interleave.
    var hookScript: String {
        """
        #!/bin/sh
        # LyricsIsland Claude Code monitor. Records events for the local app only.
        spool=\(Self.shellQuoted(paths.spoolDirectory.path))
        pidfile=\(Self.shellQuoted(paths.pidFile.path))
        pid=$(cat "$pidfile" 2>/dev/null)
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
          cat >/dev/null
          exit 0
        fi
        umask 077
        mkdir -p "$spool" 2>/dev/null
        tmp=$(mktemp "$spool/.tmp.XXXXXX" 2>/dev/null) || { cat >/dev/null; exit 0; }
        head -c \(Self.maxPayloadBytes) >"$tmp"
        cat >/dev/null
        mv "$tmp" "$spool/$$-${tmp##*/.tmp.}.json" 2>/dev/null
        exit 0

        """
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
