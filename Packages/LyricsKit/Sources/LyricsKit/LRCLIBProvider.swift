import Foundation

public enum LyricsError: Error, Equatable {
    case badStatus(Int)
}

/// One entry from a search the user runs by hand.
public struct LyricsSearchResult: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval?
    public let lyrics: Lyrics
}

public struct LRCLIBProvider: LyricsProvider {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let baseURL = URL(string: "https://lrclib.net/api")!
    private let transport: Transport

    /// A different recording of the song would be out of time with its lyrics.
    private let durationTolerance: TimeInterval = 5
    /// Tighter, because without the artist the length is the only other evidence.
    private let titleOnlyDurationTolerance: TimeInterval = 3

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private struct Record: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let hasWordSync: Bool?
        let lyricsfile: String?
    }

    public func lyrics(for query: TrackQuery) async throws -> Lyrics? {
        var candidates: [Record] = []

        // The exact lookup needs album and duration, and is usually the best match.
        // Only word timing ends the search, since another entry may have it.
        if !query.album.isEmpty, query.duration > 0, let exact = try await fetchExact(query) {
            if let lyrics = convert(exact), lyrics.hasWordTiming { return lyrics }
            candidates.append(exact)
        }

        candidates += try await search(title: query.title, artist: query.artist)
        if candidates.isEmpty {
            let simplified = Self.simplifiedTitle(query.title)
            if simplified != query.title {
                candidates += try await search(title: simplified, artist: query.artist)
            }
        }

        // The same song is often filed under the other Chinese script, and only
        // one of the entries may have word timing.
        if !candidates.contains(where: { convert($0)?.hasWordTiming == true }) {
            for variant in Self.chineseScriptVariants(of: query) {
                candidates += (try? await search(title: variant.title, artist: variant.artist)) ?? []
            }
        }

        if let found = best(of: candidates, for: query, tolerance: durationTolerance) {
            return found
        }

        // Non-Latin titles are often filed under a romanized or translated artist.
        // Latin titles repeat too often across songs to trust a match on length.
        guard query.duration > 0, !query.title.allSatisfy(\.isASCII) else { return nil }
        let titleMatches = (try? await search(title: query.title, artist: "")) ?? []
        return best(of: titleMatches, for: query, tolerance: titleOnlyDurationTolerance)
    }

    /// Searches for the user to pick from. Either field may be empty. Results
    /// are ordered by timing detail, then by closeness to `duration` when known.
    public func search(title: String, artist: String, duration: TimeInterval = 0) async throws -> [LyricsSearchResult] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedArtist.isEmpty else { return [] }

        func difference(_ result: LyricsSearchResult) -> TimeInterval {
            guard duration > 0, let length = result.duration else { return 0 }
            return abs(length - duration)
        }
        return try await search(title: trimmedTitle, artist: trimmedArtist)
            .enumerated()
            .compactMap { index, record -> LyricsSearchResult? in
                guard let lyrics = convert(record) else { return nil }
                return LyricsSearchResult(
                    id: record.id ?? -index - 1,
                    title: record.trackName ?? "",
                    artist: record.artistName ?? "",
                    album: record.albumName ?? "",
                    duration: record.duration,
                    lyrics: lyrics
                )
            }
            .sorted { (Self.tier($0.lyrics), difference($0)) < (Self.tier($1.lyrics), difference($1)) }
    }

    /// The query rewritten in Simplified and in Traditional Chinese, leaving
    /// out any that match the original.
    static func chineseScriptVariants(of query: TrackQuery) -> [(title: String, artist: String)] {
        var variants: [(title: String, artist: String)] = []
        for transform in [StringTransform("Hant-Hans"), StringTransform("Hans-Hant")] {
            let title = query.title.applyingTransform(transform, reverse: false) ?? query.title
            let artist = query.artist.applyingTransform(transform, reverse: false) ?? query.artist
            let isOriginal = title == query.title && artist == query.artist
            if !isOriginal, !variants.contains(where: { $0.title == title && $0.artist == artist }) {
                variants.append((title, artist))
            }
        }
        return variants
    }

    /// Streaming services add suffixes that community lyric titles usually lack.
    static func simplifiedTitle(_ title: String) -> String {
        var result = title
        if let range = result.range(of: " - ") {
            result = String(result[..<range.lowerBound])
        }
        if let range = result.range(of: #"\s*[\(\[](feat|ft|with|remaster|live|deluxe)[^\)\]]*[\)\]]"#, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private func convert(_ record: Record) -> Lyrics? {
        if record.instrumental == true { return .instrumental }
        if record.hasWordSync == true, let file = record.lyricsfile, let lines = LyricsfileParser.parse(file) {
            return .synced(lines)
        }
        if let synced = record.syncedLyrics {
            let lines = LRCParser.parse(synced)
            if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
        }
        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain)
        }
        return nil
    }

    private static func tier(_ lyrics: Lyrics) -> Int {
        switch lyrics {
        case .synced: return lyrics.hasWordTiming ? 0 : 1
        case .plain: return 2
        case .instrumental: return 3
        }
    }

    private func best(of records: [Record], for query: TrackQuery, tolerance: TimeInterval) -> Lyrics? {
        func difference(_ record: Record) -> TimeInterval {
            guard query.duration > 0, let duration = record.duration else { return 0 }
            return abs(duration - query.duration)
        }
        return records
            .filter { difference($0) <= tolerance }
            .compactMap { record in convert(record).map { (lyrics: $0, difference: difference(record)) } }
            .min { (Self.tier($0.lyrics), $0.difference) < (Self.tier($1.lyrics), $1.difference) }?
            .lyrics
    }

    private func fetchExact(_ query: TrackQuery) async throws -> Record? {
        let data = try await get("get", [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album),
            URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))),
        ])
        return try data.map { try JSONDecoder().decode(Record.self, from: $0) }
    }

    private func search(title: String, artist: String) async throws -> [Record] {
        var items: [URLQueryItem] = []
        if !title.isEmpty { items.append(URLQueryItem(name: "track_name", value: title)) }
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        let data = try await get("search", items)
        return try data.map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    /// Returns nil for 404, which means the source has no match.
    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("LyricsIsland/0.1", forHTTPHeaderField: "User-Agent")

        let (data, status) = try await transport(request)
        switch status {
        case 200: return data
        case 404: return nil
        default: throw LyricsError.badStatus(status)
        }
    }
}
