import Foundation

/// Extrapolates playback position on a monotonic timeline between samples
/// from the player. Times passed in are from one monotonic source, such as
/// `ProcessInfo.systemUptime`, which also stops during system sleep.
public struct PlaybackClock: Equatable, Sendable {
    /// Errors below this are sampling noise and are ignored.
    static let ignoredError: TimeInterval = 0.05
    /// Errors above this are a real jump, such as a seek.
    static let jumpThreshold: TimeInterval = 0.8
    /// Smaller errors are blended in over this long, so lyrics do not twitch.
    static let slewDuration: TimeInterval = 0.5

    private var anchorPosition: TimeInterval = 0
    private var anchorTime: TimeInterval = 0
    private var rate: Double = 0
    private var correction: TimeInterval = 0
    private var hasSample = false
    private var isPlaying = false

    public init() {}

    public func position(at now: TimeInterval) -> TimeInterval {
        let elapsed = Swift.max(0, now - anchorTime)
        let progress = Swift.min(1, elapsed / Self.slewDuration)
        return Swift.max(0, anchorPosition + rate * elapsed + correction * progress)
    }

    /// `position` must already describe the moment `now`.
    public mutating func ingest(position measured: TimeInterval, rate newRate: Double, isPlaying playing: Bool, at now: TimeInterval) {
        let effectiveRate = playing ? (newRate > 0 ? newRate : 1) : 0
        let error = hasSample ? measured - position(at: now) : .infinity
        let stateChanged = playing != isPlaying || effectiveRate != rate

        hasSample = true
        isPlaying = playing

        if stateChanged || abs(error) >= Self.jumpThreshold {
            anchor(position: measured, rate: effectiveRate, at: now, correction: 0)
        } else if abs(error) >= Self.ignoredError {
            anchor(position: position(at: now), rate: effectiveRate, at: now, correction: error)
        }
    }

    private mutating func anchor(position: TimeInterval, rate: Double, at now: TimeInterval, correction: TimeInterval) {
        anchorPosition = position
        anchorTime = now
        self.rate = rate
        self.correction = correction
    }

    /// Adjusts a player-reported position to the moment it is received.
    ///
    /// Some sources stamp samples only to the whole second, so a stamp from
    /// the last moment is less accurate than the arrival time itself. Older
    /// samples have to be extrapolated from their stamp.
    public static func currentPosition(
        reported position: TimeInterval,
        sampleAge: TimeInterval,
        rate: Double,
        isPlaying: Bool
    ) -> TimeInterval {
        // A stamp older than a day is a missing stamp, not a long-running sample.
        guard isPlaying, sampleAge > 2, sampleAge < 86_400 else { return position }
        return position + (rate > 0 ? rate : 1) * sampleAge
    }
}
