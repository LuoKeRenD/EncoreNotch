//
//  LyricsPanelView.swift
//  EncoreNotch
//

import LyricsKit
import SwiftUI

extension LyricsCache {
    static let app = LyricsCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EncoreNotch/lyrics-v1", isDirectory: true)
    )
}

extension LyricsController {
    @MainActor static let app = LyricsController(
        provider: CachingLyricsProvider(source: LRCLIBProvider(), cache: .app),
        userStore: UserLyricsStore(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/EncoreNotch/user-lyrics", isDirectory: true)
        )
    )
}

/// Lets the scroll wheel page through lyrics while the pointer is over them,
/// returning to the playing line when left alone.
@MainActor
private final class LyricsBrowser: ObservableObject {
    /// The line being browsed to, or nil when following playback.
    @Published private(set) var index: Int?

    private let lyrics = LyricsController.app
    private let pointsPerLine: CGFloat = 28
    private let holdDuration: Duration = .seconds(5)
    private var accumulated: CGFloat = 0
    private var monitor: Any?
    private var returnTask: Task<Void, Never>?

    func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        accumulated = 0
    }

    func returnToPlayback() {
        returnTask?.cancel()
        returnTask = nil
        index = nil
    }

    private func handle(_ event: NSEvent) {
        // Momentum would carry the list far past where the fingers stopped.
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }

        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 { step(forward: event.scrollingDeltaY < 0) }
            return
        }
        accumulated += event.scrollingDeltaY
        while abs(accumulated) >= pointsPerLine {
            step(forward: accumulated < 0)
            accumulated -= accumulated > 0 ? pointsPerLine : -pointsPerLine
        }
    }

    private func step(forward: Bool) {
        guard case .loaded(.synced(let lines)) = lyrics.status else { return }
        let start = index ?? lines.index(at: lyrics.lyricPosition())
        index = lines.sungIndex(from: start, forward: forward)

        returnTask?.cancel()
        returnTask = Task { [weak self, holdDuration] in
            try? await Task.sleep(for: holdDuration)
            guard !Task.isCancelled else { return }
            self?.index = nil
        }
    }
}

struct LyricsPanelView: View {
    @ObservedObject private var lyrics = LyricsController.app
    @ObservedObject private var music = MusicManager.shared
    @StateObject private var browser = LyricsBrowser()
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
                } else if isHovering, case .loaded(.plain) = lyrics.status {
                    LyricsEditButton()
                        .padding(6)
                        .background(Capsule().fill(.black.opacity(0.85)))
                        .transition(.opacity)
                }
            }
            // After the overlay, so moving onto the control still counts as hovering.
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    browser.startListening()
                } else {
                    browser.stopListening()
                }
            }
            .onChange(of: lyrics.status) { browser.returnToPlayback() }
            .onDisappear {
                browser.stopListening()
                browser.returnToPlayback()
            }
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
            missingLyrics("No lyrics found")
        case .failed:
            missingLyrics("Lyrics unavailable")
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
                SyncedLyricsView(
                    lines: lines,
                    index: browser.index ?? lines.index(at: lyrics.lyricPosition()),
                    isBrowsing: browser.index != nil
                ) { line in
                    browser.returnToPlayback()
                    music.seek(to: lyrics.seekTarget(forLyricTime: line.start))
                }
            }
        }
    }

    private func missingLyrics(_ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            message(text)
            Button {
                LyricsEditorWindowController.shared.show()
            } label: {
                Text("Add Lyrics…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.gray)
    }
}

/// The current line, shown below the notch while it is closed.
struct ClosedNotchLyricLine: View {
    @ObservedObject private var lyrics = LyricsController.app
    @ObservedObject private var music = MusicManager.shared

    /// How long a final line with no known end is assumed to last.
    private let lastLineFallback: TimeInterval = 5

    var body: some View {
        // The reader takes the notch's width instead of pushing it wider.
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 0.2, paused: !music.isPlaying)) { _ in
                let line = currentLine
                ScrollingLyricText(
                    text: line.text,
                    timing: line.timing,
                    width: geometry.size.width,
                    isPlaying: music.isPlaying,
                    seekCount: lyrics.seekCount,
                    position: { lyrics.lyricPosition() }
                )
                .id(line.text)
                .transition(.opacity)
                .animation(.smooth(duration: 0.2), value: line.text)
            }
        }
        .frame(height: 18)
        .task(id: music.isPlaying) {
            guard music.isPlaying else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                music.calibratePlayback()
            }
        }
    }

    private var currentLine: (text: String, timing: LyricScrollTiming?) {
        guard case .loaded(.synced(let lines)) = lyrics.status,
              let index = lines.index(at: lyrics.lyricPosition()),
              !lines[index].text.isEmpty
        else { return ("♪", nil) }

        let line = lines[index]
        let nextStart = index + 1 < lines.count ? lines[index + 1].start : nil
        return (line.text, LyricScrollTiming(
            lineStart: line.start,
            lineEnd: line.end ?? nextStart ?? line.start + lastLineFallback
        ))
    }
}

/// Centers text that fits. Longer text scrolls across as its line is sung.
private struct ScrollingLyricText: View {
    let text: String
    let timing: LyricScrollTiming?
    let width: CGFloat
    let isPlaying: Bool
    let seekCount: Int
    let position: () -> TimeInterval

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private struct ScrollKey: Equatable {
        let text: String
        let textWidth: CGFloat
        let width: CGFloat
        let isPlaying: Bool
        let seekCount: Int
    }

    private var overflow: CGFloat { max(0, textWidth - width) }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .offset(x: overflow > 0 ? offset : (width - textWidth) / 2)
            .frame(width: width, height: 18, alignment: .leading)
            .clipped()
            .task(id: ScrollKey(text: text, textWidth: textWidth, width: width, isPlaying: isPlaying, seekCount: seekCount)) {
                await scroll()
            }
    }

    private func scroll() async {
        guard overflow > 0, let timing else {
            offset = 0
            return
        }

        // Starts from the right place after a seek, a resume or opening late.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { offset = -overflow * timing.fraction(at: position()) }
        guard isPlaying else { return }

        let wait = timing.scrollStart - position()
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
        }
        let remaining = timing.scrollEnd - position()
        guard remaining > 0 else { return }
        withAnimation(.linear(duration: remaining)) { offset = -overflow }
    }
}

private struct LyricsEditButton: View {
    var body: some View {
        Button {
            LyricsEditorWindowController.shared.show()
        } label: {
            Image(systemName: "pencil")
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit lyrics for this song")
    }
}

private struct LyricsOffsetControl: View {
    @ObservedObject var lyrics: LyricsController
    let hasWordTiming: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                LyricsWindowController.shared.show()
            } label: {
                Image(systemName: "macwindow")
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the lyrics window")

            LyricsEditButton()

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
    let isBrowsing: Bool
    let onSeek: (LyricLine) -> Void

    private var currentLine: LyricLine? {
        guard let index, !lines[index].text.isEmpty else { return nil }
        return lines[index]
    }

    private func seekable(_ text: Text, to line: LyricLine?) -> some View {
        text
            .contentShape(Rectangle())
            .onTapGesture {
                if let line { onSeek(line) }
            }
    }

    var body: some View {
        let previous = lines.previousSungLine(before: index)
        let next = lines.nextSungLine(after: index)

        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                // A space keeps the slot, so the current line stays put at the start of a song.
                seekable(Text(previous?.text ?? " "), to: previous)
                    .font(.system(size: 13))
                    .foregroundStyle(.gray.opacity(0.7))
                    .lineLimit(2)
                seekable(Text(currentLine?.text ?? "♪"), to: currentLine)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isBrowsing ? Color.effectiveAccent : .white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                seekable(Text(next?.text ?? " "), to: next)
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
