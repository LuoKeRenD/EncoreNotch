import Foundation
import Yams

/// Parses the YAML `lyricsfile` field that LRCLIB returns alongside LRC text.
///
/// The field is not covered by LRCLIB's published docs, so anything unexpected
/// returns nil and the caller falls back to the LRC lyrics.
enum LyricsfileParser {
    private struct File: Decodable {
        let lines: [Line]?
    }

    private struct Line: Decodable {
        let text: String?
        let start_ms: Double?
        let end_ms: Double?
        let words: [Word]?
    }

    private struct Word: Decodable {
        let text: String?
        let start_ms: Double?
        let end_ms: Double?
    }

    /// Returns nil unless at least one line has real word timing.
    static func parse(_ yaml: String) -> [LyricLine]? {
        guard let file = try? YAMLDecoder().decode(File.self, from: yaml), let rawLines = file.lines else { return nil }

        let lines = rawLines
            .filter { $0.start_ms != nil }
            .sorted { $0.start_ms! < $1.start_ms! }

        let result = lines.enumerated().map { index, line -> LyricLine in
            let start = line.start_ms! / 1000
            let nextStart = index + 1 < lines.count ? lines[index + 1].start_ms! / 1000 : nil
            let end = line.end_ms.map { $0 / 1000 } ?? nextStart
            return LyricLine(
                start: start,
                text: (line.text ?? "").trimmingCharacters(in: .whitespaces),
                end: end,
                words: words(of: line, lineEnd: end)
            )
        }
        return result.contains { !$0.words.isEmpty } ? result : nil
    }

    private static func words(of line: Line, lineEnd: TimeInterval?) -> [LyricWord] {
        let timed = (line.words ?? []).filter { $0.start_ms != nil && !($0.text ?? "").isEmpty }
        // Some files mark a whole line as one "word", which is only line timing.
        guard timed.count >= 2 else { return [] }

        return timed.enumerated().map { index, word in
            let start = word.start_ms! / 1000
            let nextStart = index + 1 < timed.count ? timed[index + 1].start_ms! / 1000 : nil
            let end = word.end_ms.map { $0 / 1000 } ?? nextStart ?? lineEnd ?? start + 0.5
            return LyricWord(start: start, end: Swift.max(start, end), text: word.text ?? "")
        }
    }
}
