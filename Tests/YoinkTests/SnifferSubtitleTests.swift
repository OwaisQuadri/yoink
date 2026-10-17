import WebKit
import XCTest
@testable import Yoink

@MainActor
final class SnifferSubtitleTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        guard let address = ProcessInfo.processInfo.environment["YOINK_MEDIA_FIXTURE_URL"], let base = URL(string: address) else {
            throw XCTSkip("Run scripts/check-subtitles.sh for browser fixtures")
        }
        return base.deletingLastPathComponent().appendingPathComponent(name)
    }

    func testPageCaptionsBelongOnlyToTheSelectedVideo() async throws {
        let sniffer = Sniffer()
        defer { sniffer.reset() }
        let media = try await sniffer.find(fixture("two-videos.html"))
        XCTAssertEqual(media.url.lastPathComponent, "spanish.mp4")
        XCTAssertEqual(media.subtitles.map(\.url.lastPathComponent), ["selected.vtt"])
        XCTAssertEqual(media.subtitles.map(\.language), ["es"])
    }

    func testCancelledDelayedFrameProbeReleasesSnifferForNextJob() async throws {
        let firstURL = try fixture("cancel-probe.html")
        let store = Store()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previousFolder = store.folder
        defer { store.folder = previousFolder }
        store.folder = folder
        store.add(firstURL.absoluteString)
        let first = try XCTUnwrap(store.jobs.first)
        let firstTask = try XCTUnwrap(first.task)
        var isProbeStarted = false
        for _ in 0..<160 {
            isProbeStarted = (try? await store.sniffer.webView.evaluateJavaScript("window.isProbeStarted === true")) as? Bool ?? false
            if isProbeStarted { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(isProbeStarted, "The test must cancel inside the delayed browser probe")
        store.cancel(first)
        store.add(try fixture("two-videos.html").absoluteString)
        let second = try XCTUnwrap(store.jobs.first)
        await firstTask.value
        XCTAssertEqual(first.state, .cancelled)
        XCTAssertNotEqual(second.state, .waiting)
        let secondTask = second.task
        store.cancel(second)
        await secondTask?.value
    }

    func testStoreInitializationDoesNotDeleteAnotherInstancesTemporaryFiles() throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("yoink-other-instance-\(UUID().uuidString)")
        try Data("active job".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        _ = Store()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "active job")
    }

    func testCaptionCookieHeadersStayScopedToDomainPathAndSecureTransport() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "video.example", .path: "/private", .name: "session", .value: "private-value", .secure: "TRUE"]))
        let media = FoundMedia(url: URL(string: "https://video.example/private/movie.mp4")!, kind: .file, title: "Video", headers: ["Cookie": "session=private-value"], cookies: [cookie])
        XCTAssertEqual(media.requestHeaders(for: URL(string: "https://video.example/private/captions.vtt")!)["Cookie"], "session=private-value")
        XCTAssertNil(media.requestHeaders(for: URL(string: "https://captions.example/captions.vtt")!)["Cookie"])
        XCTAssertNil(media.requestHeaders(for: URL(string: "https://video.example/public/captions.vtt")!)["Cookie"])
        XCTAssertNil(media.requestHeaders(for: URL(string: "http://video.example/private/captions.vtt")!)["Cookie"])
    }
}
