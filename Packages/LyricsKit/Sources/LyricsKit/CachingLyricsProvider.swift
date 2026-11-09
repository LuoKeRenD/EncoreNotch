import CryptoKit
import Foundation

/// Stores lyrics on disk so a track only has to be looked up once.
public struct LyricsCache: Sendable {
    struct Entry: Codable, Equatable {
        /// Nil records that the source had nothing for this track.
        var lyrics: Lyrics?
        var storedAt: Date
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(for query: TrackQuery) -> URL {
        let key = [query.title, query.artist, query.album].joined(separator: "\u{1F}").lowercased()
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    func entry(for query: TrackQuery) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: query)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func store(_ entry: Entry, for query: TrackQuery) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: query), options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public struct CachingLyricsProvider: LyricsProvider {
    private let source: any LyricsProvider
    private let cache: LyricsCache
    private let now: @Sendable () -> Date

    /// New lyrics get contributed, so a miss is only remembered briefly.
    private let notFoundLifetime: TimeInterval = 86_400

    public init(source: any LyricsProvider, cache: LyricsCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.cache = cache
        self.now = now
    }

    public func lyrics(for query: TrackQuery) async throws -> Lyrics? {
        if let entry = cache.entry(for: query),
           entry.lyrics != nil || now().timeIntervalSince(entry.storedAt) < notFoundLifetime {
            return entry.lyrics
        }
        // Errors propagate uncached, so a network failure is retried next time.
        let lyrics = try await source.lyrics(for: query)
        cache.store(.init(lyrics: lyrics, storedAt: now()), for: query)
        return lyrics
    }
}
