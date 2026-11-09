import Combine
import Foundation

/// Loads lyrics for the current track and tracks where playback is within them.
@MainActor
public final class LyricsController: ObservableObject {
    public enum Status: Equatable, Sendable {
        case idle
        case loading
        case loaded(Lyrics)
        case notFound
        case failed
    }

    @Published public private(set) var status: Status = .idle

    private let provider: any LyricsProvider
    private let settleDelay: Duration
    private let retryDelay: Duration
    private var clock = PlaybackClock()
    private var trackKey: String?
    private var pendingQuery: TrackQuery?
    private var loadTask: Task<Void, Never>?
    private var lastSample: (position: TimeInterval, stamp: Date, rate: Double, isPlaying: Bool)?

    public init(
        provider: any LyricsProvider,
        settleDelay: Duration = .milliseconds(300),
        retryDelay: Duration = .seconds(1)
    ) {
        self.provider = provider
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
    }

    /// Call on every player update. Repeats for the same track cost nothing,
    /// and nil clears the current lyrics.
    public func setTrack(_ query: TrackQuery?) {
        let key = query.map { "\($0.title)\u{1F}\($0.artist)".lowercased() }
        if key == trackKey {
            // Metadata often arrives piecemeal, so keep the most complete version.
            if let query { pendingQuery = query }
            return
        }

        trackKey = key
        pendingQuery = query
        loadTask?.cancel()
        clock = PlaybackClock()
        lastSample = nil

        guard query != nil else {
            status = .idle
            return
        }
        status = .loading
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        try? await Task.sleep(for: settleDelay)
        guard !Task.isCancelled, let query = pendingQuery else { return }

        for attempt in 0..<2 {
            do {
                let result = try await provider.lyrics(for: query)
                guard !Task.isCancelled else { return }
                status = result.map(Status.loaded) ?? .notFound
                return
            } catch {
                guard !Task.isCancelled else { return }
                if attempt == 0 { try? await Task.sleep(for: retryDelay) }
                guard !Task.isCancelled else { return }
            }
        }
        status = .failed
    }

    /// Feeds a player sample into the clock. Updates that only changed
    /// metadata repeat the previous sample and must not count as new timing.
    public func ingest(
        position: TimeInterval,
        stamp: Date,
        rate: Double,
        isPlaying: Bool,
        wallNow: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if let last = lastSample, last.position == position, last.stamp == stamp,
           last.rate == rate, last.isPlaying == isPlaying {
            return
        }
        lastSample = (position, stamp, rate, isPlaying)

        let current = PlaybackClock.currentPosition(
            reported: position,
            sampleAge: wallNow.timeIntervalSince(stamp),
            rate: rate,
            isPlaying: isPlaying
        )
        clock.ingest(position: current, rate: rate, isPlaying: isPlaying, at: uptime)
    }

    public func position(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        clock.position(at: uptime)
    }
}
