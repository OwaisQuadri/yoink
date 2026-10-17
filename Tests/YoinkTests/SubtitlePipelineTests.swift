import XCTest
@testable import Yoink

final class SubtitlePipelineTests: XCTestCase {
    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testExistingEnglishCaptionsArePreservedWithoutDuplicateTrack() async throws {
        let work = try workspace()
        let source = work.appendingPathComponent("english.srt")
        try "1\n00:00:00,200 --> 00:00:01,500\nExisting English captions\n".write(to: source, atomically: true, encoding: .utf8)
        let video = work.appendingPathComponent("video.mkv")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=2", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-i", source.path, "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-c:a", "aac", "-c:s", "srt", "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng", "-t", "2", video.path])
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: []) { _, _ in }
        let tracks = outcome.readyTracks
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.language, "en")
        XCTAssertEqual(tracks.first?.source, .embedded)
        let output = work.appendingPathComponent("saved.mp4")
        try await SubtitlePipeline.mux(video: video, tracks: tracks, to: output)
        let inventory = try await MediaInventory.read(output)
        XCTAssertEqual(inventory.streams.filter { $0.codec_type == "subtitle" }.count, 1)
        XCTAssertEqual(inventory.streams.first { $0.codec_type == "subtitle" }?.codec_name, "mov_text")
        let captions = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", output.path, "-map", "0:s:0", "-f", "srt", "-"])
        XCTAssertTrue(String(decoding: captions, as: UTF8.self).contains("Existing English captions"))
        let before = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", video.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", "-"])
        let after = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", output.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", "-"])
        XCTAssertEqual(before, after)
    }

    func testMissingAudioCannotBeReportedAsSubtitleSuccess() async throws {
        let work = try workspace()
        let video = work.appendingPathComponent("silent.mp4")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=1", "-c:v", "libx264", video.path])
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: []) { _, _ in }
        XCTAssertTrue(outcome.readyTracks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("no audio"))
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("English"))
        let saved = work.appendingPathComponent("saved-with-warning.mp4")
        try await SubtitlePipeline.mux(video: video, tracks: outcome.readyTracks, to: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testOneGenerationFailureDoesNotDiscardOrSkipTheOtherLanguage() async throws {
        let work = try workspace()
        let result = try JSONDecoder().decode(WhisperResult.self, from: Data("""
            {"result":{"language":"es"},"transcription":[{"offsets":{"from":0,"to":1000},"text":"Usable captions"}]}
            """.utf8))
        for failing in [SubtitleTrack.Source.transcribed, .translated] {
            var language = "es"
            var tracks: [SubtitleTrack] = []
            try await SubtitlePipeline.generate(video: work.appendingPathComponent("unused.mp4"), work: work, duration: 1, language: &language, tracks: &tracks, onUpdate: { _, _ in }) { _, _, _, _, _, isTranslation in
                let source: SubtitleTrack.Source = isTranslation ? .translated : .transcribed
                if source == failing { throw YoinkError.downloadFailed("One role failed") }
                return result
            }
            let outcome = SubtitleOutcome(tracks: tracks)
            XCTAssertEqual(outcome.readyTracks.map(\.language), [failing == .transcribed ? "en" : "es"])
            XCTAssertEqual(outcome.tracks.filter { !$0.isReady }.map(\.source), [failing])
            XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("One role failed"))
        }
    }

    func testEnglishSpeechGeneratesOneEnglishTrackNotATranslationDuplicate() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOINK_ENGLISH_FIXTURE"] else {
            throw XCTSkip("Set YOINK_ENGLISH_FIXTURE to run English-only inference")
        }
        let work = try workspace()
        let outcome = try await SubtitlePipeline.complete(video: URL(fileURLWithPath: path), work: work, sourceTracks: []) { _, _ in }
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(outcome.readyTracks.map(\.language), ["en"])
        XCTAssertEqual(outcome.readyTracks.map(\.source), [.transcribed])
    }

    func testSilentAudioDoesNotInventSuccessfulSubtitles() async throws {
        guard ProcessInfo.processInfo.environment["YOINK_SUBTITLE_FIXTURE"] != nil else {
            throw XCTSkip("Run with the multilingual fixture to enable local inference checks")
        }
        let work = try workspace()
        let video = work.appendingPathComponent("silence.mp4")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=3", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-c:v", "libx264", "-c:a", "aac", "-t", "3", video.path])
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: []) { _, _ in }
        XCTAssertTrue(outcome.readyTracks.isEmpty)
        XCTAssertNotNil(outcome.warning)
    }

    func testNoAudioRetainsUsableSourceCaptionsWithMissingOriginalWarning() async throws {
        let work = try workspace()
        let video = work.appendingPathComponent("no-audio.mp4")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=2", "-c:v", "libx264", video.path])
        let captions = work.appendingPathComponent("english.srt")
        try "1\n00:00:00,100 --> 00:00:01,500\nKeep this source track\n".write(to: captions, atomically: true, encoding: .utf8)
        let source = SubtitleTrack(language: "en", source: .web, state: .ready(captions))
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [source]) { _, _ in }
        XCTAssertEqual(outcome.readyTracks, [source])
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("Original"))
        XCTAssertFalse(try XCTUnwrap(outcome.warning).contains("English"))
    }

    func testNonEnglishSpeechProducesOriginalAndEnglishSoftTracks() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOINK_SUBTITLE_FIXTURE"] else {
            throw XCTSkip("Set YOINK_SUBTITLE_FIXTURE to run local multilingual inference")
        }
        let work = try workspace()
        let outcome = try await SubtitlePipeline.complete(video: URL(fileURLWithPath: path), work: work, sourceTracks: []) { _, _ in }
        let tracks = outcome.readyTracks
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(tracks.map(\.language), ["es", "en"])
        XCTAssertEqual(tracks.map(\.source), [.transcribed, .translated])
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOINK_SUBTITLE_OUTPUT"] ?? work.appendingPathComponent("subtitled.mp4").path)
        try await SubtitlePipeline.mux(video: URL(fileURLWithPath: path), tracks: tracks, to: output)
        let inventory = try await MediaInventory.read(output)
        XCTAssertEqual(inventory.streams.filter { $0.codec_type == "subtitle" }.compactMap { $0.tags?["language"] }, ["spa", "eng"])
        let original = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", output.path, "-map", "0:s:0", "-f", "srt", "-"])
        let english = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", output.path, "-map", "0:s:1", "-f", "srt", "-"])
        XCTAssertTrue(String(decoding: original, as: UTF8.self).localizedCaseInsensitiveContains("biblioteca"))
        XCTAssertTrue(String(decoding: english, as: UTF8.self).localizedCaseInsensitiveContains("library"))
    }
}
