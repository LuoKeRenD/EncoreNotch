import Foundation

/// Converts lyrics to the line objects `@applemusic-like-lyrics/core` expects.
public enum AMLLPayload {
    /// How long the final line lasts when the source gives it no end.
    private static let lastLineFallback: TimeInterval = 5

    /// AMLL throws on negative times or an end before a start, so every value
    /// here is clamped. Timed gaps are dropped because AMLL draws its own.
    public static func lines(from lines: [LyricLine]) -> [[String: Any]] {
        lines.enumerated().compactMap { index, line in
            guard !line.text.isEmpty else { return nil }

            let start = Swift.max(0, line.start)
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : nil
            let lastWordEnd = line.words.map(\.end).max() ?? start
            let end = Swift.max(start, line.end ?? nextStart ?? start + lastLineFallback, lastWordEnd)

            let words: [[String: Any]] = line.words.isEmpty
                ? [word(start: start, end: end, text: line.text)]
                : line.words.map { item in
                    let wordStart = Swift.max(start, item.start)
                    return word(start: wordStart, end: Swift.max(wordStart, item.end), text: item.text)
                }

            return [
                "words": words,
                "translatedLyric": "",
                "romanLyric": "",
                "startTime": start * 1000,
                "endTime": end * 1000,
                "isBG": false,
                "isDuet": false,
            ]
        }
    }

    private static func word(start: TimeInterval, end: TimeInterval, text: String) -> [String: Any] {
        ["startTime": start * 1000, "endTime": end * 1000, "word": text]
    }
}
