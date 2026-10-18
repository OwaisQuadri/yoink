import XCTest
@testable import Yoink

final class SubtitlePipelineTests: XCTestCase {
    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func video(in work: URL, language: String = "spa", isAudioIncluded: Bool = true, isEmbeddedIncluded: Bool = false) async throws -> URL {
        let video = work.appendingPathComponent("video-\(UUID().uuidString).mkv")
        var arguments = ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=2"]
        if isAudioIncluded { arguments += ["-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono"] }
        if isEmbeddedIncluded { arguments += ["-i", try captionFile(in: work, language: "en").path] }
        arguments += ["-c:v", "h264_videotoolbox", "-c:a", "aac", "-c:s", "srt", "-metadata:s:a:0", "language=\(language)", "-metadata:s:s:0", "language=eng", "-t", "2", video.path]
        _ = try await MediaCommand.run(Downloader.ffmpegURL, arguments)
        return video
    }

    private func caption(in work: URL, language: String) throws -> SubtitleTrack {
        SubtitleTrack(language: language, source: .web, state: .ready(try captionFile(in: work, language: language)))
    }

    private func captionFile(in work: URL, language: String) throws -> URL {
        let file = work.appendingPathComponent("\(language).srt")
        try "1\n00:00:00,100 --> 00:00:01,500\nSource captions\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func recognition(language: String = "es", text: String = "Spoken captions") throws -> WhisperResult {
        try JSONDecoder().decode(WhisperResult.self, from: Data("""
            {"result":{"language":"\(language)"},"transcription":[{"offsets":{"from":0,"to":1000},"text":"\(text)"}]}
            """.utf8))
    }

    func testNeitherSkipsInspectionRecognitionAndWarningsEvenWithGenerationEnabled() async throws {
        let work = try workspace()
        let outcome = try await SubtitlePipeline.complete(
            video: work.appendingPathComponent("missing.mp4"), work: work,
            sourceTracks: [SubtitleTrack(language: "en", source: .web, state: .failed("Ignored"))],
            subtitleChoice: .init(languages: []),
            recognizer: { _, _, _, _, _, _ in XCTFail("Neither must not recognize audio"); throw CancellationError() },
            onUpdate: { _, _ in XCTFail("Neither must not start subtitle work") }
        )
        XCTAssertTrue(outcome.tracks.isEmpty)
        XCTAssertNil(outcome.warning)
    }

    func testEnglishOnlyWithGenerationDisabledPreservesEmbeddedCaptionsWithoutAudioOrRecognition() async throws {
        let work = try workspace()
        let video = try await video(in: work, isAudioIncluded: false, isEmbeddedIncluded: true)
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [], subtitleChoice: .init(languages: .english, isGenerationEnabled: false), recognizer: { _, _, _, _, _, _ in
            XCTFail("Source captions must not require recognition")
            throw CancellationError()
        }) { _, _ in }
        XCTAssertEqual(outcome.readyTracks.map(\.language), ["en"])
        XCTAssertNil(outcome.warning)
    }

    func testEnglishOnlyDoesNotNeedOriginalMetadataOrAudioWhenMatchingCaptionsAreAvailable() async throws {
        let work = try workspace()
        let sources = try ["es", "en", "fr"].map { try caption(in: work, language: $0) }
        for isAudioIncluded in [true, false] {
            let video = try await video(in: work, language: "und", isAudioIncluded: isAudioIncluded)
            for isGenerationEnabled in [true, false] {
                let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, subtitleChoice: .init(languages: .english, isGenerationEnabled: isGenerationEnabled), recognizer: { _, _, _, _, _, _ in
                    XCTFail("Available English captions must not require original-language detection")
                    throw CancellationError()
                }) { _, _ in }
                XCTAssertEqual(outcome.readyTracks, [sources[1]])
                XCTAssertNil(outcome.warning)
            }
            let missing = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [], subtitleChoice: .init(languages: .english, isGenerationEnabled: false), recognizer: { _, _, _, _, _, _ in
                XCTFail("Disabled generation must not recognize audio")
                throw CancellationError()
            }) { _, _ in }
            let warning = try XCTUnwrap(missing.warning)
            XCTAssertTrue(warning.contains("English"))
            XCTAssertFalse(warning.contains("Original"))
            XCTAssertFalse(warning.contains("metadata"))
        }
    }

    func testEnglishOnlyGeneratesOnlyEnglishAndDetectsWhetherTranslationIsNeeded() async throws {
        let work = try workspace()
        for (metadata, detected) in [("und", "es"), ("und", "en"), ("spa", "es"), ("eng", "en")] {
            let video = try await video(in: work, language: metadata)
            var languages: [String] = []
            var translations: [Bool] = []
            let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [], subtitleChoice: .init(languages: .english), recognizer: { _, _, _, _, language, isTranslation in
                languages.append(language)
                translations.append(isTranslation)
                return try self.recognition(language: detected)
            }) { _, _ in }
            let isTranslationNeeded = detected != "en"
            XCTAssertEqual(languages, metadata == "und" ? (isTranslationNeeded ? ["auto", "es"] : ["auto"]) : [detected])
            XCTAssertEqual(translations, metadata == "und" ? (isTranslationNeeded ? [false, true] : [false]) : [isTranslationNeeded])
            XCTAssertEqual(outcome.readyTracks.map(\.language), ["en"])
            XCTAssertEqual(outcome.readyTracks.map(\.source), [isTranslationNeeded ? .translated : .transcribed])
            XCTAssertNil(outcome.warning)
        }
    }

    func testEnglishOnlyDetectionFailureReportsOnlyMissingEnglishAndKeepsNoOriginalTrack() async throws {
        let work = try workspace()
        let video = try await video(in: work, language: "und")
        let source = try caption(in: work, language: "es")
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [source], subtitleChoice: .init(languages: .english), recognizer: { _, _, _, _, _, _ in
            throw YoinkError.downloadFailed("Detection unavailable")
        }) { _, _ in }
        XCTAssertTrue(outcome.tracks.isEmpty)
        let warning = try XCTUnwrap(outcome.warning)
        XCTAssertTrue(warning.contains("English"))
        XCTAssertTrue(warning.contains("Detection unavailable"))
        XCTAssertFalse(warning.contains("Original"))
    }

    func testBothSelectionsGenerateOneTrackForEnglishAudio() async throws {
        let work = try workspace()
        let video = try await video(in: work, language: "eng")
        var calls = 0
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [], recognizer: { _, _, _, _, language, isTranslation in
            calls += 1
            XCTAssertEqual(language, "en")
            XCTAssertFalse(isTranslation)
            return try self.recognition(language: "en")
        }) { _, _ in }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.readyTracks.map(\.language), ["en"])
        XCTAssertEqual(outcome.readyTracks.map(\.source), [.transcribed])
        XCTAssertNil(outcome.warning)
    }

    func testDisabledGenerationFiltersSelectedAudioAndNeverDetectsOrInventsGeneratedFailures() async throws {
        let work = try workspace()
        let video = try await video(in: work)
        let sources = try ["es", "en", "fr", "und"].map { try caption(in: work, language: $0) }
        for choice in [SubtitleChoice(languages: .original, isGenerationEnabled: false), .init(isGenerationEnabled: false)] {
            let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, subtitleChoice: choice, recognizer: { _, _, _, _, _, _ in
                XCTFail("Disabled generation must not recognize audio")
                throw CancellationError()
            }) { _, _ in }
            XCTAssertEqual(outcome.readyTracks.map(\.language), choice.languages == .original ? ["es"] : ["es", "en"])
            XCTAssertNil(outcome.warning)
        }
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [sources[1]], subtitleChoice: .init(languages: .original, isGenerationEnabled: false), recognizer: { _, _, _, _, _, _ in
            XCTFail("A missing original must not enable recognition")
            throw CancellationError()
        }) { _, _ in }
        XCTAssertTrue(outcome.tracks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("Original"))
        XCTAssertFalse(try XCTUnwrap(outcome.warning).contains("English"))
    }

    func testSelectedRenditionLanguageOnlyFillsUnidentifiedAudioMetadataWithoutRecognition() async throws {
        let work = try workspace()
        let sources = try ["es", "en"].map { try caption(in: work, language: $0) }
        for (metadata, isAudioIncluded, expected) in [("und", true, ["es"]), ("invalid", true, ["es"]), ("eng", true, ["en"]), ("und", false, [])] {
            let video = try await video(in: work, language: metadata, isAudioIncluded: isAudioIncluded)
            let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, selectedAudioLanguage: "es", subtitleChoice: .init(languages: .original, isGenerationEnabled: false), recognizer: { _, _, _, _, _, _ in
                XCTFail("Disabled generation must never recognize audio")
                throw CancellationError()
            }) { _, _ in }
            XCTAssertEqual(outcome.readyTracks.map(\.language), expected)
            if isAudioIncluded { XCTAssertNil(outcome.warning) }
        }
    }

    func testUnidentifiedOriginalIsNotGuessedFromSubtitleLanguageWhenGenerationIsDisabled() async throws {
        let work = try workspace()
        let sources = try ["es", "en"].map { try caption(in: work, language: $0) }
        for language in ["und", "invalid"] {
            let video = try await video(in: work, language: language)
            for choice in [SubtitleChoice(languages: .original, isGenerationEnabled: false), .init(isGenerationEnabled: false)] {
                let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, subtitleChoice: choice, recognizer: { _, _, _, _, _, _ in
                    XCTFail("Disabled generation must not detect language")
                    throw CancellationError()
                }) { _, _ in }
                XCTAssertEqual(outcome.readyTracks.map(\.language), choice.languages == .original ? [] : ["en"])
                XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("not identified in metadata"))
                XCTAssertEqual(outcome.tracks, outcome.readyTracks)
            }
        }
    }

    func testOriginalOnlyGeneratesFullOriginalForForcedCaptionsWithoutTranslation() async throws {
        let work = try workspace()
        let video = try await video(in: work)
        var forced = try caption(in: work, language: "es")
        forced.coverage = .forced
        let sources = try [forced, caption(in: work, language: "en"), caption(in: work, language: "fr")]
        var calls = 0
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, subtitleChoice: .init(languages: .original), recognizer: { _, _, _, _, language, isTranslation in
            calls += 1
            XCTAssertEqual(language, "es")
            XCTAssertFalse(isTranslation)
            return try self.recognition()
        }) { _, _ in }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.readyTracks.map(\.language), ["es", "es"])
        XCTAssertEqual(outcome.readyTracks.map(\.coverage), [.forced, .full])
        XCTAssertEqual(outcome.readyTracks.map(\.source), [.web, .transcribed])
        XCTAssertNil(outcome.warning)
    }

    func testDetectionUsesActualAudioBeforeFilteringSourcesAndDoesNotReplaceFullTargets() async throws {
        let work = try workspace()
        let video = try await video(in: work, language: "und")
        let sources = try ["en", "fr", "es"].map { try caption(in: work, language: $0) }
        var calls = 0
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: sources, recognizer: { _, _, _, _, language, isTranslation in
            calls += 1
            XCTAssertEqual(language, "auto")
            XCTAssertFalse(isTranslation)
            return try self.recognition(language: "spa")
        }) { _, _ in }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.readyTracks.map(\.language), ["en", "es"])
        XCTAssertEqual(outcome.readyTracks.map(\.source), [.web, .web])
        XCTAssertNil(outcome.warning)
    }

    func testOriginalAndEnglishGeneratesOnlyTheMissingTarget() async throws {
        let work = try workspace()
        let video = try await video(in: work)
        for existingLanguage in ["es", "en"] {
            let source = try caption(in: work, language: existingLanguage)
            var calls = 0
            let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [source], recognizer: { _, _, _, _, language, isTranslation in
                calls += 1
                XCTAssertEqual(language, "es")
                XCTAssertEqual(isTranslation, existingLanguage == "es")
                return try self.recognition()
            }) { _, _ in }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(Set(outcome.readyTracks.map(\.language)), ["es", "en"])
            XCTAssertEqual(outcome.readyTracks.first, source)
            XCTAssertNil(outcome.warning)
        }
    }

    func testOriginalOnlyDetectionFailureDoesNotKeepEnglishOrReportItAsMissing() async throws {
        let work = try workspace()
        let video = try await video(in: work, language: "und")
        let source = try caption(in: work, language: "en")
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: [source], subtitleChoice: .init(languages: .original), recognizer: { _, _, _, _, _, _ in
            throw YoinkError.downloadFailed("Detection unavailable")
        }) { _, _ in }
        XCTAssertTrue(outcome.tracks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("Original"))
        XCTAssertTrue(try XCTUnwrap(outcome.warning).contains("Detection unavailable"))
        XCTAssertFalse(try XCTUnwrap(outcome.warning).contains("English"))
    }

    func testBlankDetectionDoesNotChooseTheWrongLanguageBeforeDelayedSpeech() async throws {
        let work = try workspace()
        var language = "und"
        var tracks = try ["en", "es", "fr"].map { try caption(in: work, language: $0) }
        var offsets: [Double] = []
        try await SubtitlePipeline.generate(video: work.appendingPathComponent("unused"), work: work, duration: 301, language: &language, tracks: &tracks, onUpdate: { _, _ in }) { _, _, offset, _, _, _ in
            offsets.append(offset)
            return try self.recognition(language: offset == 0 ? "fr" : "es", text: offset == 0 ? " " : "Speech")
        }
        XCTAssertEqual(offsets, [0, 300])
        XCTAssertEqual(language, "es")
        XCTAssertEqual(tracks.map(\.language), ["en", "es"])
    }

    func testExistingEnglishCaptionsArePreservedWithoutDuplicateTrack() async throws {
        let work = try workspace()
        let source = work.appendingPathComponent("english.srt")
        try "1\n00:00:00,200 --> 00:00:01,500\nExisting English captions\n".write(to: source, atomically: true, encoding: .utf8)
        let video = work.appendingPathComponent("video.mkv")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=2", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-i", source.path, "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-c:s", "srt", "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng", "-t", "2", video.path])
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
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=1", "-c:v", "h264_videotoolbox", video.path])
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
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=3", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-t", "3", video.path])
        let outcome = try await SubtitlePipeline.complete(video: video, work: work, sourceTracks: []) { _, _ in }
        XCTAssertTrue(outcome.readyTracks.isEmpty)
        XCTAssertNotNil(outcome.warning)
    }

    func testNoAudioRetainsUsableSourceCaptionsWithMissingOriginalWarning() async throws {
        let work = try workspace()
        let video = work.appendingPathComponent("no-audio.mp4")
        _ = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-f", "lavfi", "-i", "color=s=160x90:d=2", "-c:v", "h264_videotoolbox", video.path])
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
