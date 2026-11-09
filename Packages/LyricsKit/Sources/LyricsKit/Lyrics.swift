import Foundation

public struct TrackQuery: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds, or 0 when unknown.
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String = "", duration: TimeInterval = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct LyricWord: Equatable, Codable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// May carry trailing spaces, which matter when words are joined.
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct LyricLine: Equatable, Codable, Sendable {
    public var start: TimeInterval
    /// Empty for a timed gap between sung lines.
    public var text: String
    public var end: TimeInterval?
    /// Empty when this line only has line-level timing.
    public var words: [LyricWord]

    public init(start: TimeInterval, text: String, end: TimeInterval? = nil, words: [LyricWord] = []) {
        self.start = start
        self.text = text
        self.end = end
        self.words = words
    }
}

public enum Lyrics: Equatable, Codable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental

    public var hasWordTiming: Bool {
        guard case .synced(let lines) = self else { return false }
        return lines.contains { !$0.words.isEmpty }
    }
}

public protocol LyricsProvider: Sendable {
    /// Returns nil when the source has nothing for this track.
    func lyrics(for query: TrackQuery) async throws -> Lyrics?
}

extension Array where Element == LyricLine {
    /// The last line that has started at `time`, or nil before the first line.
    /// Lines must be sorted by start time.
    public func index(at time: TimeInterval) -> Int? {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }

    /// The last sung line before `index`, skipping timed gaps.
    public func previousSungLine(before index: Int?) -> LyricLine? {
        guard let index, index > 0 else { return nil }
        return self[..<index].last { !$0.text.isEmpty }
    }

    /// The first sung line after `index`, skipping timed gaps.
    public func nextSungLine(after index: Int?) -> LyricLine? {
        let start = (index ?? -1) + 1
        guard start < count else { return nil }
        return self[start...].first { !$0.text.isEmpty }
    }
}

public enum LRCParser {
    /// Parses LRC text, accepting several time tags per line and 1 to 3
    /// fraction digits. Lines without a time tag are ignored.
    public static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine).drop(while: \.isWhitespace)
            var times: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }

            let lyric = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { LyricLine(start: $0, text: lyric) }
        }

        // The sort is stable, so lines sharing a time keep their written order.
        return lines
            .map { LyricLine(start: Swift.max(0, $0.start - offset), text: $0.text) }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    private static func parseTime(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts[0].allSatisfy(\.isNumber), !parts[0].isEmpty,
              let minutes = Double(parts[0])
        else { return nil }

        // Both mm:ss.xx and mm:ss:xx appear in the wild.
        let secondsAndFraction = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard secondsAndFraction.count <= 2,
              secondsAndFraction[0].allSatisfy(\.isNumber),
              let seconds = Double(secondsAndFraction[0])
        else { return nil }

        var fractionDigits: Substring = ""
        if parts.count == 3 {
            guard secondsAndFraction.count == 1 else { return nil }
            fractionDigits = parts[2]
        } else if secondsAndFraction.count == 2 {
            fractionDigits = secondsAndFraction[1]
        }
        guard fractionDigits.allSatisfy(\.isNumber) else { return nil }
        let fraction = fractionDigits.isEmpty ? 0 : (Double("0." + fractionDigits) ?? 0)
        return minutes * 60 + seconds + fraction
    }
}
