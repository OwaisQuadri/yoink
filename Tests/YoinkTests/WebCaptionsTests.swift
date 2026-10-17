import XCTest
@testable import Yoink

final class WebCaptionsTests: XCTestCase {
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
