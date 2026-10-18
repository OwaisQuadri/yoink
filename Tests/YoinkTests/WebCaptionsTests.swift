import XCTest
@testable import Yoink

final class WebCaptionsTests: XCTestCase {
    private func fixtureMedia(_ name: String) throws -> FoundMedia {
        guard let address = ProcessInfo.processInfo.environment["YOINK_MEDIA_FIXTURE_URL"], let base = URL(string: address) else {
            throw XCTSkip("Run scripts/check-subtitles.sh for caption fixtures")
        }
        return FoundMedia(url: base.deletingLastPathComponent().appendingPathComponent(name), kind: .file, title: "Captions", headers: [:])
    }

    private func workspace() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("caption-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: work) }
        return work
    }

    func testSharedHLSInitializationTimestampMapAlignsCaptionBodies() async throws {
        let media = try fixtureMedia("shared-captions.m3u8")
        let track = try await WebCaptions.download(RemoteSubtitle(url: media.url, language: "es"), media: media, work: workspace(), timeline: .available([TransportEpoch(start: 0, transportStart: 10_000)]), presentationShift: 0)
        guard case .ready(let file) = track.state else { return XCTFail("Valid shared initialization must produce a ready track") }
        let cues = try WebCaptions.cues(String(contentsOf: file, encoding: .utf8), videoStart: 0, segmentStart: 0)
        XCTAssertEqual(cues, [SubtitleCue(start: 2500, end: 3000, text: "Shared header captions")])
    }

    func testUnrepresentableRemoteDurationsFailWithoutCrashing() async throws {
        for value in ["1e100", "-1", "nan", "inf", "overflow"] {
            let media = try fixtureMedia("invalid-\(value).m3u8")
            do {
                _ = try await WebCaptions.download(RemoteSubtitle(url: media.url, language: "es"), media: media, work: workspace(), timeline: .available([]), presentationShift: 0)
                XCTFail("Invalid or overflowing caption duration must fail")
            } catch let error as YoinkError {
                XCTAssertNotNil(error.errorDescription)
            }
        }
    }

    func testTimestampOffsetAndAccumulationOverflowThrowInsteadOfTrapping() throws {
        XCTAssertThrowsError(try SubtitleTime.duration(1e100))
        XCTAssertThrowsError(try SubtitleTime.add(Int.max, 1))
        XCTAssertThrowsError(try SubtitleTime.subtract(Int.min, 1))
        XCTAssertThrowsError(try WebCaptions.cues("""
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:01.000,MPEGTS:0

            00:00:00.500 --> 00:00:01.000
            Outside timeline
            """, videoStart: Int.max, segmentStart: Int.min, epochOffset: 0))
    }

    func testHLSSelectsOnlySubtitleGroupForBestVideo() throws {
        let variant = try XCTUnwrap(HLS.pickVariant("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="low",LANGUAGE="de",URI="low.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="high",LANGUAGE="es",URI="es.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="high",LANGUAGE="en",FORCED=YES,URI="forced.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100,SUBTITLES="low"
            low-video.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=200,SUBTITLES="high"
            high-video.m3u8
            """, base: URL(string: "https://example.com/master.m3u8")!))
        XCTAssertEqual(variant.video.lastPathComponent, "high-video.m3u8")
        XCTAssertEqual(variant.subtitles.map(\.language), ["es", "en"])
        XCTAssertEqual(variant.subtitles.map(\.isForced), [false, true])
    }

    func testHLSAudioLanguageNeverComesFromUnselectedOrAmbiguousInBandRenditions() throws {
        let base = URL(string: "https://example.com/master.m3u8")!
        let renditions = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Spanish",LANGUAGE="es",DEFAULT=YES
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="French",LANGUAGE="fr"
            """
        let ambiguous = try XCTUnwrap(HLS.pickVariant(renditions + "\n#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO=\"audio\"\nvideo.m3u8", base: base))
        XCTAssertNil(ambiguous.audio)
        XCTAssertNil(ambiguous.selectedAudioLanguage)
        let unselected = try XCTUnwrap(HLS.pickVariant(renditions + "\n#EXT-X-STREAM-INF:BANDWIDTH=100\nvideo.m3u8", base: base))
        XCTAssertNil(unselected.audio)
        XCTAssertNil(unselected.selectedAudioLanguage)
        let external = try XCTUnwrap(HLS.pickVariant(renditions + """

            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="eng-US",URI="english.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO="audio"
            video.m3u8
            """, base: base))
        XCTAssertEqual(external.audio, base.deletingLastPathComponent().appendingPathComponent("english.m3u8"))
        XCTAssertEqual(external.selectedAudioLanguage, "en")
    }

    func testWebVTTTimestampMapKeepsNonzeroTransportClockSynchronized() throws {
        let cues = try WebCaptions.cues("""
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000

            1
            00:00:02.500 --> 00:00:04.000 align:start
            Hola
            otra línea
            """, videoStart: 10_000, segmentStart: 0)
        XCTAssertEqual(cues, [SubtitleCue(start: 2500, end: 4000, text: "Hola\notra línea")])
    }

    func testWebVTTTimestampWrapDoesNotMoveCuesAwayFromTheirSegment() throws {
        let cues = try WebCaptions.cues("""
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:45000

            00:00:01.000 --> 00:00:02.000
            After wrap
            """, videoStart: Int((Double((Int64(1) << 33) - 90_000) / 90).rounded()), segmentStart: 1500)
        XCTAssertEqual(cues.first?.start, 2500)
        XCTAssertEqual(cues.first?.end, 3500)
    }
}
