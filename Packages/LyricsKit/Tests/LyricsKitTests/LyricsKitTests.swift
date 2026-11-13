import XCTest
@testable import LyricsKit

final class LRCParserTests: XCTestCase {
    func testFractionDigitsAreScaledByLength() {
        let lines = LRCParser.parse("[00:01.5]a\n[00:02.25]b\n[00:03.125]c\n[00:04]d")
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(lines[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(lines[1].start, 2.25, accuracy: 0.0001)
        XCTAssertEqual(lines[2].start, 3.125, accuracy: 0.0001)
        XCTAssertEqual(lines[3].start, 4, accuracy: 0.0001)
    }

    func testColonFractionAndLongMinutes() {
        let lines = LRCParser.parse("[01:02:50]a\n[100:00.00]b")
        XCTAssertEqual(lines[0].start, 62.5, accuracy: 0.0001)
        XCTAssertEqual(lines[1].start, 6000, accuracy: 0.0001)
    }

    func testRepeatedTagsExpandAndSort() {
        let lines = LRCParser.parse("[00:30.00][00:10.00]chorus\n[00:20.00]verse")
        XCTAssertEqual(lines.map(\.text), ["chorus", "verse", "chorus"])
        XCTAssertEqual(lines.map(\.start), [10, 20, 30])
    }

    func testMetadataIgnoredAndOffsetApplied() {
        let lines = LRCParser.parse("[ar:Someone]\n[offset:+500]\n[00:01.00]a\nno tag here\n[00:00.20]b")
        XCTAssertEqual(lines.map(\.text), ["b", "a"])
        XCTAssertEqual(lines[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(lines[1].start, 0.5, accuracy: 0.0001)
    }

    func testEmptyLinesAreKeptAsGaps() {
        let lines = LRCParser.parse("[00:01.00]a\r\n[00:02.00]\r\n[00:03.00] b ")
        XCTAssertEqual(lines.map(\.text), ["a", "", "b"])
    }

    func testSungIndexSkipsGapsAndStopsAtEnds() {
        let lines = LRCParser.parse("[00:10.00]a\n[00:20.00]\n[00:30.00]b")
        XCTAssertEqual(lines.sungIndex(from: 0, forward: true), 2)
        XCTAssertEqual(lines.sungIndex(from: 2, forward: false), 0)
        XCTAssertEqual(lines.sungIndex(from: 2, forward: true), 2)
        XCTAssertEqual(lines.sungIndex(from: 0, forward: false), 0)
        XCTAssertEqual(lines.sungIndex(from: 1, forward: false), 0)
        XCTAssertEqual(lines.sungIndex(from: nil, forward: true), 0)
        XCTAssertEqual(lines.sungIndex(from: nil, forward: false), 0)
    }

    func testScrollTimingRestsAtBothEnds() {
        let timing = LyricScrollTiming(lineStart: 10, lineEnd: 20)
        XCTAssertEqual(timing.scrollStart, 11.5, accuracy: 0.0001)
        XCTAssertEqual(timing.scrollEnd, 18.5, accuracy: 0.0001)
        XCTAssertEqual(timing.fraction(at: 10), 0)
        XCTAssertEqual(timing.fraction(at: 15), 0.5, accuracy: 0.0001)
        XCTAssertEqual(timing.fraction(at: 19), 1)
    }

    func testScrollTimingHandlesZeroLengthLine() {
        let timing = LyricScrollTiming(lineStart: 10, lineEnd: 10)
        XCTAssertEqual(timing.fraction(at: 9), 0)
        XCTAssertEqual(timing.fraction(at: 10), 1)
    }

    func testBracketInsideLyricIsKept() {
        XCTAssertEqual(LRCParser.parse("[00:01.00][la la] song").first?.text, "[la la] song")
    }

    func testLineLookup() {
        let lines = LRCParser.parse("[00:10.00]a\n[00:20.00]\n[00:30.00]b")
        XCTAssertNil(lines.index(at: 9.99))
        XCTAssertEqual(lines.index(at: 10), 0)
        XCTAssertEqual(lines.index(at: 25), 1)
        XCTAssertEqual(lines.index(at: 500), 2)
        XCTAssertEqual(lines.nextSungLine(after: nil)?.text, "a")
        XCTAssertEqual(lines.nextSungLine(after: 0)?.text, "b")
        XCTAssertNil(lines.nextSungLine(after: 2))
        XCTAssertNil(lines.previousSungLine(before: nil))
        XCTAssertNil(lines.previousSungLine(before: 0))
        XCTAssertEqual(lines.previousSungLine(before: 1)?.text, "a")
        XCTAssertEqual(lines.previousSungLine(before: 2)?.text, "a")
    }
}

final class PlaybackClockTests: XCTestCase {
    func testExtrapolatesAtRateAndFreezesWhenPaused() {
        var clock = PlaybackClock()
        clock.ingest(position: 10, rate: 1, isPlaying: true, at: 100)
        XCTAssertEqual(clock.position(at: 105), 15, accuracy: 0.001)
        clock.ingest(position: 15, rate: 0, isPlaying: false, at: 105)
        XCTAssertEqual(clock.position(at: 200), 15, accuracy: 0.001)
    }

    func testZeroRateWhilePlayingMeansNormalSpeed() {
        var clock = PlaybackClock()
        clock.ingest(position: 0, rate: 0, isPlaying: true, at: 0)
        XCTAssertEqual(clock.position(at: 2), 2, accuracy: 0.001)
    }

    func testHonoursPlaybackRate() {
        var clock = PlaybackClock()
        clock.ingest(position: 0, rate: 2, isPlaying: true, at: 0)
        XCTAssertEqual(clock.position(at: 3), 6, accuracy: 0.001)
    }

    func testNoiseIsIgnored() {
        var clock = PlaybackClock()
        clock.ingest(position: 10, rate: 1, isPlaying: true, at: 0)
        clock.ingest(position: 15.03, rate: 1, isPlaying: true, at: 5)
        XCTAssertEqual(clock.position(at: 5), 15, accuracy: 0.001)
    }

    func testSmallDriftIsBlendedInWithoutAJump() {
        var clock = PlaybackClock()
        clock.ingest(position: 10, rate: 1, isPlaying: true, at: 0)
        clock.ingest(position: 15.3, rate: 1, isPlaying: true, at: 5)
        XCTAssertEqual(clock.position(at: 5), 15, accuracy: 0.001)
        XCTAssertEqual(clock.position(at: 5.25), 15.4, accuracy: 0.001)
        XCTAssertEqual(clock.position(at: 6), 16.3, accuracy: 0.001)
    }

    func testSeekJumpsImmediately() {
        var clock = PlaybackClock()
        clock.ingest(position: 10, rate: 1, isPlaying: true, at: 0)
        clock.ingest(position: 100, rate: 1, isPlaying: true, at: 5)
        XCTAssertEqual(clock.position(at: 5), 100, accuracy: 0.001)
    }

    func testResumeJumpsEvenForSmallDifference() {
        var clock = PlaybackClock()
        clock.ingest(position: 10, rate: 0, isPlaying: false, at: 0)
        clock.ingest(position: 10.3, rate: 1, isPlaying: true, at: 1)
        XCTAssertEqual(clock.position(at: 1), 10.3, accuracy: 0.001)
    }

    func testPositionNeverNegative() {
        var clock = PlaybackClock()
        clock.ingest(position: 0.1, rate: 1, isPlaying: true, at: 10)
        clock.ingest(position: 0.11, rate: 1, isPlaying: true, at: 10.1)
        XCTAssertGreaterThanOrEqual(clock.position(at: 9), 0)
    }

    func testFreshSecondResolutionStampUsesArrivalTime() {
        XCTAssertEqual(PlaybackClock.currentPosition(reported: 14.315, sampleAge: 0.9, rate: 1, isPlaying: true), 14.315)
    }

    func testOldSampleIsExtrapolatedAndPausedIsNot() {
        XCTAssertEqual(PlaybackClock.currentPosition(reported: 10, sampleAge: 30, rate: 1, isPlaying: true), 40)
        XCTAssertEqual(PlaybackClock.currentPosition(reported: 10, sampleAge: 30, rate: 1, isPlaying: false), 10)
    }

    func testMissingStampIsNotExtrapolated() {
        let age = Date().timeIntervalSince(.distantPast)
        XCTAssertEqual(PlaybackClock.currentPosition(reported: 10, sampleAge: age, rate: 1, isPlaying: true), 10)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var paths: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
    var last: URLComponents? { lock.withLock { urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } } }
    var userAgentChecked = true
}

final class LRCLIBProviderTests: XCTestCase {
    private func provider(_ responses: [String: (String, Int)], recorder: Recorder = Recorder()) -> LRCLIBProvider {
        LRCLIBProvider { request in
            recorder.add(request.url!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "EncoreNotch/1.1")
            let (body, status) = responses[request.url!.lastPathComponent] ?? ("", 404)
            return (Data(body.utf8), status)
        }
    }

    private let full = TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200)

    func testExactSyncedMatchSkipsSearch() async throws {
        let recorder = Recorder()
        let result = try await provider(
            ["get": (#"{"duration":200,"syncedLyrics":"[00:01.00]hello","plainLyrics":"hello"}"#, 200)],
            recorder: recorder
        ).lyrics(for: full)
        XCTAssertEqual(result, .synced([LyricLine(start: 1, text: "hello")]))
        XCTAssertEqual(recorder.paths, ["get", "search"])
    }

    func testPlainExactFallsThroughToSyncedSearchResult() async throws {
        let result = try await provider([
            "get": (#"{"duration":200,"plainLyrics":"hello"}"#, 200),
            "search": (#"[{"duration":201,"syncedLyrics":"[00:02.00]hi"}]"#, 200),
        ]).lyrics(for: full)
        XCTAssertEqual(result, .synced([LyricLine(start: 2, text: "hi")]))
    }

    func testSkipsExactWithoutAlbumOrDuration() async throws {
        let recorder = Recorder()
        _ = try await provider(["search": ("[]", 200)], recorder: recorder)
            .lyrics(for: TrackQuery(title: "Song", artist: "Band"))
        XCTAssertEqual(recorder.paths, ["search"])
    }

    func testDifferentRecordingLengthIsRejected() async throws {
        let result = try await provider([
            "search": (#"[{"duration":260,"syncedLyrics":"[00:02.00]wrong"}]"#, 200)
        ]).lyrics(for: full)
        XCTAssertNil(result)
    }

    func testPrefersSyncedThenClosestDuration() async throws {
        let result = try await provider(["search": (#"""
        [{"duration":200,"plainLyrics":"plain only"},
         {"duration":204,"syncedLyrics":"[00:01.00]far"},
         {"duration":201,"syncedLyrics":"[00:01.00]near"}]
        """#, 200)]).lyrics(for: full)
        XCTAssertEqual(result, .synced([LyricLine(start: 1, text: "near")]))
    }

    func testFallsBackToPlainAndInstrumental() async throws {
        let plain = try await provider(["search": (#"[{"plainLyrics":"  words \n"}]"#, 200)]).lyrics(for: full)
        XCTAssertEqual(plain, .plain("words"))
        let instrumental = try await provider(["search": (#"[{"instrumental":true}]"#, 200)]).lyrics(for: full)
        XCTAssertEqual(instrumental, .instrumental)
    }

    func testEmptySyncedFallsBackToPlain() async throws {
        let result = try await provider(["search": (#"[{"syncedLyrics":"[00:01.00]\n","plainLyrics":"words"}]"#, 200)]).lyrics(for: full)
        XCTAssertEqual(result, .plain("words"))
    }

    func testRetriesSearchWithSimplifiedTitle() async throws {
        let recorder = Recorder()
        _ = try await provider(["search": ("[]", 200)], recorder: recorder)
            .lyrics(for: TrackQuery(title: "Song - Remastered 2011", artist: "Band"))
        XCTAssertEqual(recorder.paths, ["search", "search"])
        XCTAssertEqual(recorder.last?.queryItems?.first?.value, "Song")
    }

    func testSimplifiedTitle() {
        XCTAssertEqual(LRCLIBProvider.simplifiedTitle("Song (feat. Someone)"), "Song")
        XCTAssertEqual(LRCLIBProvider.simplifiedTitle("Song [Live at Home]"), "Song")
        XCTAssertEqual(LRCLIBProvider.simplifiedTitle("Love (Is All)"), "Love (Is All)")
        XCTAssertEqual(LRCLIBProvider.simplifiedTitle("晴天"), "晴天")
    }

    func testQueryValuesAreEncoded() async throws {
        let recorder = Recorder()
        _ = try await provider(["search": ("[]", 200)], recorder: recorder)
            .lyrics(for: TrackQuery(title: "晴 & 天", artist: "A/B"))
        XCTAssertEqual(recorder.last?.queryItems?.map(\.value), ["晴 & 天", "A/B"])
    }

    func testServerErrorThrows() async {
        do {
            _ = try await provider(["search": ("", 500)]).lyrics(for: full)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LyricsError, .badStatus(500))
        }
    }
}

private actor StubProvider: LyricsProvider {
    var calls: [TrackQuery] = []
    var failures: Int
    let result: Lyrics?

    init(result: Lyrics?, failures: Int = 0) {
        self.result = result
        self.failures = failures
    }

    func lyrics(for query: TrackQuery) async throws -> Lyrics? {
        calls.append(query)
        if failures > 0 {
            failures -= 1
            throw LyricsError.badStatus(503)
        }
        return result
    }
}

@MainActor
final class LyricsControllerTests: XCTestCase {
    private let song = TrackQuery(title: "Song", artist: "Band")
    private let lyrics = Lyrics.plain("words")

    private func controller(_ provider: StubProvider) -> LyricsController {
        LyricsController(provider: provider, settleDelay: .milliseconds(1), retryDelay: .milliseconds(1))
    }

    private func waitForLoad(_ controller: LyricsController) async {
        for _ in 0..<400 where controller.status == .loading {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLoadsOncePerTrackUsingLatestMetadata() async {
        let stub = StubProvider(result: lyrics)
        let sut = LyricsController(provider: stub, settleDelay: .milliseconds(30), retryDelay: .milliseconds(1))
        sut.setTrack(song)
        sut.setTrack(TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200))
        await waitForLoad(sut)
        XCTAssertEqual(sut.status, .loaded(lyrics))
        let calls = await stub.calls
        XCTAssertEqual(calls, [TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200)])

        sut.setTrack(song)
        try? await Task.sleep(for: .milliseconds(20))
        let again = await stub.calls
        XCTAssertEqual(again.count, 1)
    }

    func testMissingLyricsReportNotFound() async {
        let sut = controller(StubProvider(result: nil))
        sut.setTrack(song)
        await waitForLoad(sut)
        XCTAssertEqual(sut.status, .notFound)
    }

    func testRetriesOnceAfterFailure() async {
        let stub = StubProvider(result: lyrics, failures: 1)
        let sut = controller(stub)
        sut.setTrack(song)
        await waitForLoad(sut)
        XCTAssertEqual(sut.status, .loaded(lyrics))
        let calls = await stub.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testReportsFailureAfterRetry() async {
        let sut = controller(StubProvider(result: lyrics, failures: 2))
        sut.setTrack(song)
        await waitForLoad(sut)
        XCTAssertEqual(sut.status, .failed)
    }

    func testNewTrackResetsClockAndNilClears() async {
        let sut = controller(StubProvider(result: lyrics))
        sut.setTrack(song)
        let now = Date()
        sut.ingest(position: 50, stamp: now, rate: 1, isPlaying: false, wallNow: now, uptime: 10)
        XCTAssertEqual(sut.position(at: 10), 50, accuracy: 0.001)

        sut.setTrack(TrackQuery(title: "Other", artist: "Band"))
        XCTAssertEqual(sut.position(at: 10), 0, accuracy: 0.001)
        XCTAssertEqual(sut.status, .loading)

        sut.setTrack(nil)
        XCTAssertEqual(sut.status, .idle)
    }

    func testMetadataOnlyUpdateDoesNotReanchor() {
        let sut = controller(StubProvider(result: lyrics))
        let stamp = Date()
        sut.ingest(position: 10, stamp: stamp, rate: 1, isPlaying: true, wallNow: stamp, uptime: 100)
        // Same sample seen again later, as when only the artwork changed.
        sut.ingest(position: 10, stamp: stamp, rate: 1, isPlaying: true, wallNow: stamp.addingTimeInterval(1.5), uptime: 101.5)
        XCTAssertEqual(sut.position(at: 101.5), 11.5, accuracy: 0.001)
    }
}
