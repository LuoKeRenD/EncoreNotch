import Foundation

/// Finds a session's custom title in its transcript.
///
/// Hooks report `session_title` only with SessionStart and UserPromptSubmit,
/// so a session already running when monitoring starts would stay unnamed
/// until its next prompt. Claude Code records renames in the transcript as
/// `custom-title` lines; only those lines are decoded, never prompts or output.
enum TranscriptTitle {
    /// Transcripts can grow large; renames are found near the end in practice.
    static let tailBytes = 4 << 20
    private static let marker = Data(#""type":"custom-title""#.utf8)

    static func read(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        return latestTitle(in: data)
    }

    static func latestTitle(in data: Data) -> String? {
        var title: String?
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["type"] as? String == "custom-title",
                  let value = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            title = value
        }
        return title
    }
}
