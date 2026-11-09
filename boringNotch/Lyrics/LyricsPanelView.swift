//
//  LyricsPanelView.swift
//  LyricsIsland
//

import LyricsKit
import SwiftUI

extension LyricsController {
    @MainActor static let app = LyricsController(provider: LRCLIBProvider())
}

struct LyricsPanelView: View {
    @ObservedObject private var lyrics = LyricsController.app
    @ObservedObject private var music = MusicManager.shared

    /// Often enough to catch drift well before it is audible.
    private let calibrationInterval: Duration = .seconds(5)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .task(id: music.isPlaying) {
                guard music.isPlaying else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: calibrationInterval)
                    guard !Task.isCancelled else { return }
                    music.calibratePlayback()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.status {
        case .idle:
            Color.clear
        case .loading:
            message("Loading lyrics…")
        case .notFound:
            message("No lyrics found")
        case .failed:
            message("Lyrics unavailable")
        case .loaded(.instrumental):
            message("Instrumental")
        case .loaded(.plain(let text)):
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .padding(.vertical, 8)
        case .loaded(.synced(let lines)):
            TimelineView(.animation(minimumInterval: 0.1, paused: !music.isPlaying)) { _ in
                SyncedLyricsView(lines: lines, index: lines.index(at: lyrics.position()))
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.gray)
    }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let index: Int?

    private var current: String {
        guard let index, !lines[index].text.isEmpty else { return "♪" }
        return lines[index].text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                // A space keeps the slot, so the current line stays put at the start of a song.
                Text(lines.previousSungLine(before: index)?.text ?? " ")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray.opacity(0.7))
                    .lineLimit(2)
                Text(current)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(lines.nextSungLine(after: index)?.text ?? " ")
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(index ?? -1)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 14)),
                removal: .opacity.combined(with: .offset(y: -14))
            ))
        }
        .animation(.smooth(duration: 0.3), value: index)
    }
}
