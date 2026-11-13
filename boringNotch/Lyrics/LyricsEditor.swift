//
//  LyricsEditor.swift
//  EncoreNotch
//

import AppKit
import LyricsKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the user pick or supply lyrics when the automatic lookup misses.
@MainActor
final class LyricsEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = LyricsEditorWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Edit Lyrics")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 420, height: 400)
            window.contentView = NSHostingView(rootView: LyricsEditorView())
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct LyricsEditorView: View {
    private enum Mode: Hashable {
        case search
        case paste
    }

    @ObservedObject private var lyrics = LyricsController.app

    @State private var mode = Mode.search
    @State private var title = ""
    @State private var artist = ""
    @State private var results: [LyricsSearchResult] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var pastedText = ""

    private let provider = LRCLIBProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("", selection: $mode) {
                Text("Search").tag(Mode.search)
                Text("Paste").tag(Mode.paste)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .search: searchPane
            case .paste: pastePane
            }

            if lyrics.hasUserLyrics {
                Divider()
                HStack {
                    Text("This song is using lyrics you chose.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove My Lyrics") { lyrics.removeUserLyrics() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 400)
        .onAppear(perform: fillFromCurrentTrack)
        .onChange(of: lyrics.currentTrack?.title) { fillFromCurrentTrack() }
    }

    @ViewBuilder
    private var header: some View {
        if let track = lyrics.currentTrack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text("Nothing is playing").foregroundStyle(.secondary)
        }
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
            }

            HStack {
                Button("Search Online", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSearching || (title.isBlank && artist.isBlank))
                if isSearching { ProgressView().controlSize(.small) }
                Spacer()
            }

            if searchFailed {
                Text("Could not search. Check your connection and try again.")
                    .foregroundStyle(.red)
            } else if hasSearched && results.isEmpty && !isSearching {
                Text("No results. Try the title in its original language, or leave the artist empty.")
                    .foregroundStyle(.secondary)
            }

            List(results) { result in
                resultRow(result)
            }
            .listStyle(.inset)
        }
    }

    private func resultRow(_ result: LyricsSearchResult) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1)
                Text(result.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let duration = result.duration {
                Text(Self.formatted(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(lengthMatches(duration) ? .green : .secondary)
            }
            Text(tierLabel(result.lyrics))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36)
            Button("Use") {
                use(result.lyrics)
            }
        }
    }

    private var pastePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste LRC text with timestamps for synced lyrics, or plain text.")
                .foregroundStyle(.secondary)

            TextEditor(text: $pastedText)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))

            HStack {
                Button("Import File…", action: importFile)
                Spacer()
                Button("Save") {
                    if let parsed = Lyrics(userText: pastedText) { use(parsed) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pastedText.isBlank || lyrics.currentTrack == nil)
            }
        }
    }

    private func tierLabel(_ item: Lyrics) -> LocalizedStringKey {
        switch item {
        case .synced: return item.hasWordTiming ? "Word" : "Line"
        case .plain: return "Text"
        case .instrumental: return "Instrumental"
        }
    }

    private func lengthMatches(_ duration: TimeInterval) -> Bool {
        guard let target = lyrics.currentTrack?.duration, target > 0 else { return false }
        return abs(duration - target) <= 3
    }

    private static func formatted(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func fillFromCurrentTrack() {
        title = lyrics.currentTrack?.title ?? ""
        artist = lyrics.currentTrack?.artist ?? ""
        results = []
        hasSearched = false
        searchFailed = false
    }

    private func use(_ chosen: Lyrics) {
        lyrics.saveUserLyrics(chosen)
        LyricsEditorWindowController.shared.close()
    }

    private func runSearch() {
        isSearching = true
        searchFailed = false
        Task {
            do {
                results = try await provider.search(
                    title: title,
                    artist: artist,
                    duration: lyrics.currentTrack?.duration ?? 0
                )
            } catch {
                results = []
                searchFailed = true
            }
            hasSearched = true
            isSearching = false
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        pastedText = Self.decodeText(data)
    }

    /// Older Chinese LRC files are often GB18030 rather than UTF-8.
    private static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030)) ?? ""
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
