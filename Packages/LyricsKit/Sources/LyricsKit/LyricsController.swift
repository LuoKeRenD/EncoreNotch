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
    /// Seconds added to the playback position, so positive shows lyrics earlier.
    @Published public private(set) var globalOffset: TimeInterval
    @Published public private(set) var trackOffset: TimeInterval = 0

    public static let offsetRange: ClosedRange<TimeInterval> = -5...5
    private static let globalOffsetKey = "lyricsGlobalOffset"
    private static let trackOffsetsKey = "lyricsTrackOffsets"

    private let defaults: UserDefaults
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
        retryDelay: Duration = .seconds(1),
        defaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.defaults = defaults
        self.globalOffset = defaults.double(forKey: Self.globalOffsetKey)
    }

    private static func sanitized(_ offset: TimeInterval) -> TimeInterval {
        // Whole tenths, so repeated steps do not accumulate floating point noise.
        (Swift.min(Swift.max(offset, offsetRange.lowerBound), offsetRange.upperBound) * 10).rounded() / 10
    }

    public func setGlobalOffset(_ offset: TimeInterval) {
        globalOffset = Self.sanitized(offset)
        defaults.set(globalOffset, forKey: Self.globalOffsetKey)
    }

    /// Remembered per track. Does nothing when no track is loaded.
    public func setTrackOffset(_ offset: TimeInterval) {
        guard let trackKey else { return }
        trackOffset = Self.sanitized(offset)
        var stored = defaults.dictionary(forKey: Self.trackOffsetsKey) as? [String: Double] ?? [:]
        stored[trackKey] = trackOffset == 0 ? nil : trackOffset
        defaults.set(stored, forKey: Self.trackOffsetsKey)
    }

    private func storedTrackOffset(for key: String?) -> TimeInterval {
        guard let key else { return 0 }
        return (defaults.dictionary(forKey: Self.trackOffsetsKey) as? [String: Double])?[key] ?? 0
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
        trackOffset = storedTrackOffset(for: key)

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

    /// The position to look up lyrics with, including the user's offsets.
    public func lyricPosition(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        position(at: uptime) + globalOffset + trackOffset
    }
}
