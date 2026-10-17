import XCTest
@testable import Yoink

final class SubtitleTrackTests: XCTestCase {
    func testChunkTimestampsStayOnVideoTimelineAndWithinAudio() throws {
        let result = try JSONDecoder().decode(WhisperResult.self, from: Data("""
            {"result":{"language":"es"},"transcription":[
              {"offsets":{"from":1200,"to":3000},"text":" Hola "},
              {"offsets":{"from":4500,"to":7000},"text":"Adiós"},
              {"offsets":{"from":8000,"to":9000},"text":"outside audio"}
            ]}
            """.utf8))
        XCTAssertEqual(SubtitleCue.srt(result.cues(offset: 300_000, duration: 5000)), """
            1
            00:05:01,200 --> 00:05:03,000
            Hola

            2
            00:05:04,500 --> 00:05:05,000
            Adiós

            """)
    }

    func testEnglishLanguageAliasesDoNotCreateDuplicateTranslation() {
        XCTAssertEqual(SubtitleLanguage.canonical("eng"), "en")
        XCTAssertEqual(SubtitleLanguage.canonical("en-US"), "en")
        XCTAssertEqual(SubtitleLanguage.canonical("fre"), "fr")
        XCTAssertEqual(SubtitleLanguage.mp4("es"), "spa")
        XCTAssertEqual(SubtitleLanguage.canonical(nil), "und")
    }

    func testCancellingMediaCommandStopsTheProcess() async throws {
        let task = Task { try await MediaCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not succeed")
        } catch is CancellationError {
        }
    }
}
