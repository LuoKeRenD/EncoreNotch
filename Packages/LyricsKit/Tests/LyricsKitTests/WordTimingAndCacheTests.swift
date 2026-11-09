import XCTest
@testable import LyricsKit

final class LyricsfileParserTests: XCTestCase {
    /// The shape LRCLIB returned for a real word-synced entry, with text replaced.
    private let sample = """
    version: '1.0'
    metadata:
      title: Song
      duration_ms: 270000
    lines:
    - text: whole line
      start_ms: 29250
      end_ms: 35697
      words:
      - text: whole line
        start_ms: 29250
    - text: one two
      start_ms: 42670
      end_ms: 45010
      words:
      - text: 'one '
        start_ms: 42670
      - text: 'two '
        start_ms: 43120
    """

    func testParsesWordsAndInfersEnds() throws {
        let lines = try XCTUnwrap(LyricsfileParser.parse(sample))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].text, "one two")
        XCTAssertEqual(lines[1].words.map(\.text), ["one ", "two "])
        XCTAssertEqual(lines[1].words[0].start, 42.67, accuracy: 0.0001)
        XCTAssertEqual(lines[1].words[0].end, 43.12, accuracy: 0.0001)
        XCTAssertEqual(lines[1].words[1].end, 45.01, accuracy: 0.0001)
    }

    func testSingleWordLineDegradesToLineTiming() throws {
        let lines = try XCTUnwrap(LyricsfileParser.parse(sample))
        XCTAssertEqual(lines[0].words, [])
        XCTAssertEqual(lines[0].end ?? 0, 35.697, accuracy: 0.0001)
    }

    func testNoWordTimingAnywhereReturnsNil() {
        XCTAssertNil(LyricsfileParser.parse("lines:\n- text: a\n  start_ms: 100\n  end_ms: 200\n"))
    }

    func testMalformedYamlReturnsNil() {
        XCTAssertNil(LyricsfileParser.parse("lines: [unclosed"))
        XCTAssertNil(LyricsfileParser.parse("just text"))
    }

    func testScalarsThatLookLikeOtherTypesStayText() throws {
        let yaml = """
        lines:
        - text: 123
          start_ms: 0
          words:
          - text: 1
            start_ms: 0
          - text: 'yes'
            start_ms: 100
        """
        let lines = try XCTUnwrap(LyricsfileParser.parse(yaml))
        XCTAssertEqual(lines[0].text, "123")
        XCTAssertEqual(lines[0].words.map(\.text), ["1", "yes"])
    }

    func testMissingWordEndWithoutLineEndHasPositiveLength() throws {
        let yaml = """
        lines:
        - text: a b
          start_ms: 1000
          words:
          - text: a
            start_ms: 1000
          - text: b
            start_ms: 1200
        """
        let word = try XCTUnwrap(LyricsfileParser.parse(yaml)?.first?.words.last)
        XCTAssertGreaterThan(word.end, word.start)
    }
}

final class TierSelectionTests: XCTestCase {
    private let query = TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200)
    private let wordFile = "lines:\\n- text: a b\\n  start_ms: 1000\\n  words:\\n  - text: a\\n    start_ms: 1000\\n  - text: b\\n    start_ms: 1500\\n"

    private func provider(get: (String, Int) = ("", 404), search: (String, Int)) -> LRCLIBProvider {
        LRCLIBProvider { request in
            let (body, status) = request.url!.lastPathComponent == "get" ? get : search
            return (Data(body.utf8), status)
        }
    }

    func testWordTimingBeatsLineTimingEvenIfFurtherInDuration() async throws {
        let result = try await provider(search: (#"""
        [{"duration":200,"syncedLyrics":"[00:01.00]line"},
         {"duration":204,"hasWordSync":true,"lyricsfile":"\#(wordFile)","syncedLyrics":"[00:01.00]a b"}]
        """#, 200)).lyrics(for: query)
        XCTAssertEqual(result?.hasWordTiming, true)
    }

    func testBrokenLyricsfileFallsBackToLineTiming() async throws {
        let result = try await provider(search: (#"""
        [{"duration":200,"hasWordSync":true,"lyricsfile":"lines: [","syncedLyrics":"[00:01.00]line"}]
        """#, 200)).lyrics(for: query)
        XCTAssertEqual(result, .synced([LyricLine(start: 1, text: "line")]))
    }

    func testLyricsfileIgnoredWithoutWordSyncFlag() async throws {
        let result = try await provider(search: (#"""
        [{"duration":200,"hasWordSync":false,"lyricsfile":"\#(wordFile)","syncedLyrics":"[00:01.00]line"}]
        """#, 200)).lyrics(for: query)
        XCTAssertEqual(result?.hasWordTiming, false)
    }

    private func artistRoutedProvider(_ bodies: [String: String]) -> LRCLIBProvider {
        LRCLIBProvider { request in
            guard request.url!.lastPathComponent == "search" else { return (Data(), 404) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let artist = items?.first { $0.name == "artist_name" }?.value ?? ""
            return (Data((bodies[artist] ?? "[]").utf8), 200)
        }
    }

    func testFindsWordTimingFiledUnderOtherChineseScript() async throws {
        let result = try await artistRoutedProvider([
            "周杰倫": #"[{"duration":270,"syncedLyrics":"[00:01.00]line"}]"#,
            "周杰伦": #"[{"duration":270,"hasWordSync":true,"lyricsfile":"\#(wordFile)"}]"#,
        ]).lyrics(for: TrackQuery(title: "晴天", artist: "周杰倫", album: "葉惠美", duration: 269.7))
        XCTAssertEqual(result?.hasWordTiming, true)
    }

    func testFailedScriptVariantKeepsOriginalResult() async throws {
        let result = try await LRCLIBProvider { request in
            let artist = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "artist_name" }?.value
            guard request.url!.lastPathComponent == "search", artist == "周杰倫" else { return (Data(), 500) }
            return (Data(#"[{"syncedLyrics":"[00:01.00]line"}]"#.utf8), 200)
        }.lyrics(for: TrackQuery(title: "晴天", artist: "周杰倫"))
        XCTAssertEqual(result, .synced([LyricLine(start: 1, text: "line")]))
    }

    func testScriptVariantsOnlyForConvertibleText() {
        XCTAssertTrue(LRCLIBProvider.chineseScriptVariants(of: TrackQuery(title: "Song", artist: "Band")).isEmpty)
        let fromTraditional = LRCLIBProvider.chineseScriptVariants(of: TrackQuery(title: "晴天", artist: "周杰倫"))
        XCTAssertTrue(fromTraditional.contains { $0.artist == "周杰伦" })
        XCTAssertFalse(fromTraditional.contains { $0.artist == "周杰倫" })
        let fromSimplified = LRCLIBProvider.chineseScriptVariants(of: TrackQuery(title: "晴天", artist: "周杰伦"))
        XCTAssertEqual(fromSimplified.map(\.artist), ["周傑倫"])
    }

    func testExactWordMatchSkipsSearch() async throws {
        let body = #"{"duration":200,"hasWordSync":true,"lyricsfile":"\#(wordFile)"}"#
        let result = try await LRCLIBProvider { request in
            XCTAssertEqual(request.url!.lastPathComponent, "get")
            return (Data(body.utf8), 200)
        }.lyrics(for: query)
        XCTAssertEqual(result?.hasWordTiming, true)
    }
}

private actor CountingSource: LyricsProvider {
    private(set) var calls = 0
    var result: Lyrics?
    var error: Error?

    init(result: Lyrics?) { self.result = result }
    func set(result: Lyrics?, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func lyrics(for query: TrackQuery) async throws -> Lyrics? {
        calls += 1
        if let error { throw error }
        return result
    }
}

private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class CachingLyricsProviderTests: XCTestCase {
    private var directory: URL!
    private let query = TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200)
    private let words = Lyrics.synced([
        LyricLine(start: 1, text: "a b", end: 2, words: [LyricWord(start: 1, end: 1.5, text: "a "), LyricWord(start: 1.5, end: 2, text: "b")])
    ])

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ source: CountingSource, time: FakeTime = FakeTime()) -> CachingLyricsProvider {
        CachingLyricsProvider(source: source, cache: LyricsCache(directory: directory), now: { time.now })
    }

    func testRoundTripsWordTimingWithoutRefetching() async throws {
        let source = CountingSource(result: words)
        let first = try await make(source).lyrics(for: query)
        let second = try await make(source).lyrics(for: query)
        XCTAssertEqual(first, words)
        XCTAssertEqual(second, words)
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
    }

    func testNotFoundIsRememberedThenRetried() async throws {
        let source = CountingSource(result: nil)
        let time = FakeTime()
        let sut = make(source, time: time)
        _ = try await sut.lyrics(for: query)
        _ = try await sut.lyrics(for: query)
        var calls = await source.calls
        XCTAssertEqual(calls, 1)

        time.advance(86_401)
        await source.set(result: words)
        let later = try await sut.lyrics(for: query)
        XCTAssertEqual(later, words)
        calls = await source.calls
        XCTAssertEqual(calls, 2)
    }

    func testErrorsAreNotCached() async throws {
        let source = CountingSource(result: nil)
        await source.set(result: nil, error: LyricsError.badStatus(500))
        let sut = make(source)
        do {
            _ = try await sut.lyrics(for: query)
            XCTFail("expected an error")
        } catch {}
        await source.set(result: words)
        let result = try await sut.lyrics(for: query)
        XCTAssertEqual(result, words)
    }

    func testClearForcesRefetch() async throws {
        let source = CountingSource(result: words)
        _ = try await make(source).lyrics(for: query)
        LyricsCache(directory: directory).clear()
        _ = try await make(source).lyrics(for: query)
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
    }

    func testDifferentTracksDoNotCollide() async throws {
        let source = CountingSource(result: words)
        let sut = make(source)
        _ = try await sut.lyrics(for: query)
        _ = try await sut.lyrics(for: TrackQuery(title: "Other", artist: "Band", album: "LP", duration: 200))
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
    }
}

@MainActor
final class LyricsOffsetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let song = TrackQuery(title: "Song", artist: "Band")
    private let other = TrackQuery(title: "Other", artist: "Band")

    private struct Empty: LyricsProvider {
        func lyrics(for query: TrackQuery) async throws -> Lyrics? { nil }
    }

    override func setUp() async throws {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> LyricsController {
        LyricsController(provider: Empty(), settleDelay: .milliseconds(1), retryDelay: .milliseconds(1), defaults: defaults)
    }

    func testOffsetsAddToLyricPositionButNotPlaybackPosition() {
        let sut = make()
        sut.setTrack(song)
        let now = Date()
        sut.ingest(position: 10, stamp: now, rate: 0, isPlaying: false, wallNow: now, uptime: 1)
        sut.setGlobalOffset(0.5)
        sut.setTrackOffset(-0.2)
        XCTAssertEqual(sut.position(at: 1), 10, accuracy: 0.001)
        XCTAssertEqual(sut.lyricPosition(at: 1), 10.3, accuracy: 0.001)
    }

    private func pausedAt(_ position: TimeInterval, _ sut: LyricsController, uptime: TimeInterval = 10) {
        let now = Date(timeIntervalSince1970: uptime)
        sut.ingest(position: position, stamp: now, rate: 0, isPlaying: false, wallNow: now, uptime: uptime)
    }

    func testSeekWhilePausedMovesImmediatelyAndStaysPaused() {
        let sut = make()
        sut.setTrack(song)
        pausedAt(20, sut)
        let before = sut.seekCount
        sut.noteSeek(to: 100, uptime: 11)
        XCTAssertEqual(sut.position(at: 11), 100, accuracy: 0.001)
        XCTAssertEqual(sut.position(at: 500), 100, accuracy: 0.001)
        XCTAssertEqual(sut.seekCount, before + 1)
    }

    func testSeekWhilePlayingKeepsAdvancing() {
        let sut = make()
        sut.setTrack(song)
        let now = Date(timeIntervalSince1970: 10)
        sut.ingest(position: 20, stamp: now, rate: 1, isPlaying: true, wallNow: now, uptime: 10)
        sut.noteSeek(to: 100, uptime: 11)
        XCTAssertEqual(sut.position(at: 13), 102, accuracy: 0.001)
    }

    func testStaleReportAfterSeekIsIgnoredButConfirmationAccepted() {
        let sut = make()
        sut.setTrack(song)
        pausedAt(20, sut)
        sut.noteSeek(to: 100, uptime: 11)

        pausedAt(20, sut, uptime: 11.1)
        XCTAssertEqual(sut.position(at: 11.1), 100, accuracy: 0.001)

        pausedAt(100.4, sut, uptime: 11.6)
        // Small differences blend in over half a second.
        XCTAssertEqual(sut.position(at: 12.2), 100.4, accuracy: 0.001)
    }

    func testLaterRealMoveIsAcceptedAfterHoldExpires() {
        let sut = make()
        sut.setTrack(song)
        pausedAt(20, sut)
        sut.noteSeek(to: 100, uptime: 11)
        pausedAt(50, sut, uptime: 13)
        XCTAssertEqual(sut.position(at: 13), 50, accuracy: 0.001)
    }

    func testSeekTargetUndoesOffsetsAndStaysInRange() {
        let sut = make()
        sut.setTrack(song)
        sut.setGlobalOffset(0.5)
        sut.setTrackOffset(0.2)
        XCTAssertEqual(sut.seekTarget(forLyricTime: 10), 9.3, accuracy: 0.001)
        XCTAssertEqual(sut.seekTarget(forLyricTime: 0.1), 0, accuracy: 0.001)
    }

    func testTrackOffsetFollowsTrackAndPersists() {
        let sut = make()
        sut.setTrack(song)
        sut.setTrackOffset(0.4)
        sut.setTrack(other)
        XCTAssertEqual(sut.trackOffset, 0)
        sut.setTrack(song)
        XCTAssertEqual(sut.trackOffset, 0.4)

        let relaunched = make()
        relaunched.setTrack(song)
        XCTAssertEqual(relaunched.trackOffset, 0.4)
    }

    func testGlobalOffsetPersists() {
        make().setGlobalOffset(-1.2)
        XCTAssertEqual(make().globalOffset, -1.2)
    }

    func testOffsetsAreClampedAndRounded() {
        let sut = make()
        sut.setTrack(song)
        sut.setTrackOffset(99)
        XCTAssertEqual(sut.trackOffset, 5)
        sut.setTrackOffset(0.1 + 0.2)
        XCTAssertEqual(sut.trackOffset, 0.3)
    }

    func testZeroOffsetIsNotStored() {
        let sut = make()
        sut.setTrack(song)
        sut.setTrackOffset(0.4)
        sut.setTrackOffset(0)
        XCTAssertEqual(defaults.dictionary(forKey: "lyricsTrackOffsets")?.count, 0)
    }

    func testOffsetWithoutTrackIsIgnored() {
        let sut = make()
        sut.setTrackOffset(1)
        XCTAssertEqual(sut.trackOffset, 0)
    }
}

final class TitleOnlyFallbackTests: XCTestCase {
    private func provider(withArtist: String = "[]", titleOnly: String) -> LRCLIBProvider {
        LRCLIBProvider { request in
            guard request.url!.lastPathComponent == "search" else { return (Data(), 404) }
            let names = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
            return (Data((names.contains("artist_name") ? withArtist : titleOnly).utf8), 200)
        }
    }

    func testNonLatinTitleFindsEntryFiledUnderAnotherArtistName() async throws {
        let result = try await provider(titleOnly: #"[{"duration":231,"plainLyrics":"words"}]"#)
            .lyrics(for: TrackQuery(title: "泡沫の夢", artist: "ハコニワリリィ", duration: 230))
        XCTAssertEqual(result, .plain("words"))
    }

    func testTitleOnlyRejectsDifferentLength() async throws {
        let result = try await provider(titleOnly: #"[{"duration":265,"syncedLyrics":"[00:01.00]cover"}]"#)
            .lyrics(for: TrackQuery(title: "泡沫の夢", artist: "ハコニワリリィ", duration: 230))
        XCTAssertNil(result)
    }

    func testTitleOnlyIsStricterThanArtistSearch() async throws {
        let result = try await provider(titleOnly: #"[{"duration":234,"plainLyrics":"words"}]"#)
            .lyrics(for: TrackQuery(title: "泡沫の夢", artist: "ハコニワリリィ", duration: 230))
        XCTAssertNil(result)
    }

    func testLatinTitlesNeverUseTitleOnly() async throws {
        let result = try await provider(titleOnly: #"[{"duration":200,"plainLyrics":"someone else's song"}]"#)
            .lyrics(for: TrackQuery(title: "Home", artist: "Band", duration: 200))
        XCTAssertNil(result)
    }

    func testTitleOnlyNeedsAKnownDuration() async throws {
        let result = try await provider(titleOnly: #"[{"duration":200,"plainLyrics":"words"}]"#)
            .lyrics(for: TrackQuery(title: "泡沫の夢", artist: "ハコニワリリィ"))
        XCTAssertNil(result)
    }

    func testArtistMatchIsPreferredOverTitleOnly() async throws {
        let result = try await provider(
            withArtist: #"[{"duration":230,"plainLyrics":"by artist"}]"#,
            titleOnly: #"[{"duration":230,"syncedLyrics":"[00:01.00]other"}]"#
        ).lyrics(for: TrackQuery(title: "泡沫の夢", artist: "ハコニワリリィ", duration: 230))
        XCTAssertEqual(result, .plain("by artist"))
    }
}

final class ManualSearchTests: XCTestCase {
    private let body = #"""
    [{"id":1,"trackName":"Plain","artistName":"A","albumName":"X","duration":200,"plainLyrics":"p"},
     {"id":2,"trackName":"Far","artistName":"B","albumName":"Y","duration":300,"syncedLyrics":"[00:01.00]far"},
     {"id":3,"trackName":"Near","artistName":"C","albumName":"Z","duration":201,"syncedLyrics":"[00:01.00]near"},
     {"id":4,"trackName":"Empty","artistName":"D","albumName":"W","duration":200}]
    """#

    func testOrdersByTimingThenDurationAndDropsEmptyEntries() async throws {
        let body = self.body
        let results = try await LRCLIBProvider { _ in (Data(body.utf8), 200) }
            .search(title: "Song", artist: "", duration: 200)
        XCTAssertEqual(results.map(\.title), ["Near", "Far", "Plain"])
        XCTAssertEqual(results[0].artist, "C")
    }

    func testEmptyFieldsAreLeftOutOfTheQuery() async throws {
        let recorder = Recorder()
        _ = try await LRCLIBProvider { request in
            recorder.add(request.url!)
            return (Data("[]".utf8), 200)
        }.search(title: "  ", artist: " Band ")
        XCTAssertEqual(recorder.last?.queryItems?.map(\.name), ["artist_name"])
        XCTAssertEqual(recorder.last?.queryItems?.first?.value, "Band")
    }

    func testNothingToSearchSkipsTheNetwork() async throws {
        let results = try await LRCLIBProvider { _ in
            XCTFail("should not search")
            return (Data(), 200)
        }.search(title: " ", artist: "")
        XCTAssertTrue(results.isEmpty)
    }
}

final class UserTextTests: XCTestCase {
    func testTimedTextBecomesSynced() {
        XCTAssertEqual(Lyrics(userText: "[00:01.00]a\n[00:02.00]b"), .synced([LyricLine(start: 1, text: "a"), LyricLine(start: 2, text: "b")]))
    }

    func testUntimedTextBecomesPlain() {
        XCTAssertEqual(Lyrics(userText: "\n line one\nline two \n"), .plain("line one\nline two"))
    }

    func testTagsWithNoLyricsAreNotSynced() {
        XCTAssertEqual(Lyrics(userText: "[ar:Band]\nwords"), .plain("[ar:Band]\nwords"))
    }

    func testBlankTextIsNothing() {
        XCTAssertNil(Lyrics(userText: " \n "))
    }
}

@MainActor
final class UserLyricsControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let song = TrackQuery(title: "Song", artist: "Band")
    private let automatic = Lyrics.plain("automatic")
    private let mine = Lyrics.plain("mine")

    private struct Fixed: LyricsProvider {
        let result: Lyrics?
        func lyrics(for query: TrackQuery) async throws -> Lyrics? { result }
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ result: Lyrics?) -> LyricsController {
        LyricsController(
            provider: Fixed(result: result), settleDelay: .milliseconds(1), retryDelay: .milliseconds(1),
            defaults: defaults, userStore: UserLyricsStore(directory: directory)
        )
    }

    private func settle(_ sut: LyricsController) async {
        for _ in 0..<400 where sut.status == .loading {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testSavedLyricsReplaceCurrentAndSurviveRelaunch() async {
        let first = make(nil)
        first.setTrack(song)
        await settle(first)
        XCTAssertEqual(first.status, .notFound)

        first.saveUserLyrics(mine)
        XCTAssertEqual(first.status, .loaded(mine))
        XCTAssertTrue(first.hasUserLyrics)

        let relaunched = make(automatic)
        relaunched.setTrack(song)
        await settle(relaunched)
        XCTAssertEqual(relaunched.status, .loaded(mine))
        XCTAssertTrue(relaunched.hasUserLyrics)
    }

    func testRemovingReturnsToAutomaticLookup() async {
        let sut = make(automatic)
        sut.setTrack(song)
        await settle(sut)
        sut.saveUserLyrics(mine)
        sut.removeUserLyrics()
        XCTAssertFalse(sut.hasUserLyrics)
        await settle(sut)
        XCTAssertEqual(sut.status, .loaded(automatic))
    }

    func testOtherTracksAreUnaffected() async {
        let sut = make(automatic)
        sut.setTrack(song)
        await settle(sut)
        sut.saveUserLyrics(mine)
        sut.setTrack(TrackQuery(title: "Other", artist: "Band"))
        XCTAssertFalse(sut.hasUserLyrics)
        await settle(sut)
        XCTAssertEqual(sut.status, .loaded(automatic))
    }

    func testPendingLookupCannotOverwriteSavedLyrics() async {
        let sut = LyricsController(
            provider: Fixed(result: automatic), settleDelay: .milliseconds(30), retryDelay: .milliseconds(1),
            defaults: defaults, userStore: UserLyricsStore(directory: directory)
        )
        sut.setTrack(song)
        sut.saveUserLyrics(mine)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(sut.status, .loaded(mine))
    }

    func testCurrentTrackKeepsLatestMetadata() {
        let sut = make(nil)
        sut.setTrack(song)
        let fuller = TrackQuery(title: "Song", artist: "Band", album: "LP", duration: 200)
        sut.setTrack(fuller)
        XCTAssertEqual(sut.currentTrack, fuller)
    }
}
