import XCTest
@testable import Yoink

final class DownloaderSubtitleTests: XCTestCase {
    @MainActor
    func testWorkspaceSetupFailureReleasesAcquisitionExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: blocker)
        let work = blocker.appendingPathComponent("work")
        let output = directory.appendingPathComponent("saved.mp4")
        let media = FoundMedia(url: URL(string: "https://example.com/video.mp4")!, kind: .file, title: "Fixture", headers: [:])
        var acquisitionReleases = 0

        do {
            _ = try await Downloader.save(media, to: output, work: work, onAcquired: {
                acquisitionReleases += 1
            }, onSubtitles: { _, _ in XCTFail("Setup failure must not start subtitles") }, onProgress: { _ in
                XCTFail("Setup failure must not start acquisition")
            })
            XCTFail("A file cannot contain the workspace directory")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }

        XCTAssertEqual(acquisitionReleases, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("part").path))
        XCTAssertEqual(try Data(contentsOf: blocker), Data("not a directory".utf8))
    }

    func testCancellationDuringSubtitleStagesNeverPublishesVideoOrPartialFile() async throws {
        guard let address = ProcessInfo.processInfo.environment["YOINK_MEDIA_FIXTURE_URL"], let url = URL(string: address), url.pathExtension == "mp4" else {
            throw XCTSkip("Run with the direct Spanish HTTP fixture for cancellation checks")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for phase in [SubtitlePhase.transcribing(0), .translating(0), .muxing] {
            let output = directory.appendingPathComponent("cancelled.mp4")
            let task = Task {
                try await Downloader.save(FoundMedia(url: url, kind: .file, title: "Fixture", headers: [:]), to: output, onAcquired: {}, onSubtitles: { current, _ in
                    if current == phase { withUnsafeCurrentTask { $0?.cancel() } }
                }, onProgress: { _ in })
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled subtitle processing must not save a video")
            } catch is CancellationError {
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("part").path))
        }
    }

    func testInvalidHLSEpochTimingStillSavesVideoWithCaptionWarning() async throws {
        guard let address = ProcessInfo.processInfo.environment["YOINK_MEDIA_FIXTURE_URL"], let base = URL(string: address), base.pathExtension == "mp4" else {
            throw XCTSkip("Run with the direct HTTP fixture to check malformed HLS source timing")
        }
        let url = base.deletingLastPathComponent().appendingPathComponent("hls/invalid-master.m3u8")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-caption-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("saved.mp4")
        let warning = try await Downloader.save(FoundMedia(url: url, kind: .hls, title: "Fixture", headers: [:]), to: output, onAcquired: {}, onSubtitles: { _, _ in }, onProgress: { _ in })
        XCTAssertTrue(try XCTUnwrap(warning).contains("Source captions"))
        let inventory = try await MediaInventory.read(output)
        XCTAssertEqual(inventory.streams.filter { $0.codec_type == "video" }.count, 1)
        XCTAssertEqual(inventory.streams.filter { $0.codec_type == "subtitle" }.count, 2)
    }

    func testAcquiredMediaSavesOriginalAndEnglishAtExpectedTimes() async throws {
        guard let address = ProcessInfo.processInfo.environment["YOINK_MEDIA_FIXTURE_URL"], let url = URL(string: address) else {
            throw XCTSkip("Set YOINK_MEDIA_FIXTURE_URL for the local HTTP media fixture")
        }
        let kind: FoundMedia.Kind = url.pathExtension == "m3u8" ? .hls : url.pathExtension == "mpd" ? .dash : .file
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOINK_MEDIA_OUTPUT"] ?? directory.appendingPathComponent("saved.mp4").path)
        let warning = try await Downloader.save(FoundMedia(url: url, kind: kind, title: "Fixture", headers: [:]), to: output, onAcquired: {}, onSubtitles: { _, _ in }, onProgress: { _ in })
        XCTAssertNil(warning)
        let inventory = try await MediaInventory.read(output)
        XCTAssertEqual(inventory.streams.filter { $0.codec_type == "subtitle" }.compactMap { $0.tags?["language"] }, ["spa", "eng"])
        if let expected = ProcessInfo.processInfo.environment["YOINK_MEDIA_EXPECTED_DURATION"].flatMap(Double.init) {
            XCTAssertEqual(try XCTUnwrap(inventory.format.duration.flatMap(Double.init)), expected, accuracy: 0.2)
        }
        if let marker = ProcessInfo.processInfo.environment["YOINK_MEDIA_SOURCE_MARKER"] {
            let captions = try await MediaCommand.run(Downloader.ffmpegURL, ["-v", "error", "-i", output.path, "-map", "0:s:0", "-f", "srt", "-"])
            let text = String(decoding: captions, as: UTF8.self)
            XCTAssertTrue(text.contains(marker))
            let cues = try WebCaptions.cues(text, videoStart: 0, segmentStart: 0)
            let videoStart = inventory.streams.first { $0.codec_type == "video" }?.start_time.flatMap(Double.init) ?? 0
            XCTAssertEqual(Double(try XCTUnwrap(cues.first?.start)), videoStart * 1000 + 500, accuracy: 2)
            XCTAssertTrue(cues.contains { $0.start > 9000 && $0.text.contains(marker) })
        }
    }
}
