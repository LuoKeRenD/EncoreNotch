//
//  LyricsPanelView.swift
//  LyricsIsland
//

import LyricsKit
import SwiftUI

extension LyricsCache {
    static let app = LyricsCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsIsland/lyrics-v1", isDirectory: true)
    )
}

extension LyricsController {
    @MainActor static let app = LyricsController(
        provider: CachingLyricsProvider(source: LRCLIBProvider(), cache: .app)
    )
}

struct LyricsPanelView: View {
    @ObservedObject private var lyrics = LyricsController.app
    @ObservedObject private var music = MusicManager.shared
    @State private var isHovering = false

    /// Often enough to catch drift well before it is audible.
    private let calibrationInterval: Duration = .seconds(5)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if isHovering, case .loaded(let loaded) = lyrics.status, case .synced = loaded {
                    LyricsOffsetControl(lyrics: lyrics, hasWordTiming: loaded.hasWordTiming)
                        .transition(.opacity)
                }
            }
            // After the overlay, so moving onto the control still counts as hovering.
            .onHover { isHovering = $0 }
            .animation(.smooth(duration: 0.15), value: isHovering)
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
                SyncedLyricsView(lines: lines, index: lines.index(at: lyrics.lyricPosition()))
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.gray)
    }
}

private struct LyricsOffsetControl: View {
    @ObservedObject var lyrics: LyricsController
    let hasWordTiming: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(hasWordTiming ? "Word" : "Line")
                .foregroundStyle(.gray)
                .help(hasWordTiming ? "These lyrics have word timing" : "These lyrics have line timing")

            step("minus", by: -0.1, help: "Show lyrics later for this song")

            Button {
                lyrics.setTrackOffset(0)
            } label: {
                Text(String(format: "%+.1fs", lyrics.trackOffset))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Reset this song's offset")

            step("plus", by: 0.1, help: "Show lyrics earlier for this song")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }

    private func step(_ symbol: String, by amount: TimeInterval, help: String) -> some View {
        Button {
            lyrics.setTrackOffset(lyrics.trackOffset + amount)
        } label: {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
