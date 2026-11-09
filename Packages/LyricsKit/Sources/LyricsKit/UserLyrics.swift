import CryptoKit
import Foundation

extension Lyrics {
    /// Reads pasted or imported text: LRC when it has timed lines, otherwise
    /// plain lyrics. Returns nil when there is no text.
    public init?(userText: String) {
        let lines = LRCParser.parse(userText)
        if lines.contains(where: { !$0.text.isEmpty }) {
            self = .synced(lines)
            return
        }
        let plain = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        self = .plain(plain)
    }
}

/// Lyrics the user chose for a track. These always win over automatic lookups
/// and are kept apart from the cache, so clearing the cache leaves them alone.
public struct UserLyricsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(forTrackKey key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    func lyrics(forTrackKey key: String) -> Lyrics? {
        guard let data = try? Data(contentsOf: url(forTrackKey: key)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    func save(_ lyrics: Lyrics, forTrackKey key: String) {
        guard let data = try? JSONEncoder().encode(lyrics) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(forTrackKey: key), options: .atomic)
    }

    func remove(forTrackKey key: String) {
        try? FileManager.default.removeItem(at: url(forTrackKey: key))
    }
}
