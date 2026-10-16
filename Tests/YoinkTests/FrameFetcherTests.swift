import WebKit
import XCTest
@testable import Yoink

@MainActor
final class FrameFetcherTests: XCTestCase, WKScriptMessageHandler {
    private let ready = XCTestExpectation(description: "Frame ready")
    private var frame: WKFrameInfo?

    func testFileMetadataStaysBoundedWhenZeroRangeEndMeansWholeFile() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "ready")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "ready") }
        webView.loadHTMLString("""
            <script>
            window.fetch = async (url, options) => {
                const size = 10485777;
                const match = /^bytes=(\\d+)-(\\d+)$/.exec(options.headers.Range);
                const start = Number(match[1]);
                const end = Number(match[2]) || size - 1;
                window.responseSize = end - start + 1;
                return new Response(new Uint8Array(window.responseSize), {
                    status: 206,
                    headers: { 'Content-Range': `bytes ${start}-${end}/${size}` }
                });
            };
            webkit.messageHandlers.ready.postMessage('ready');
            </script>
            """, baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        let fetcher = FrameFetcher(webView: webView, frame: try XCTUnwrap(frame))
        let media = FoundMedia(url: URL(string: "https://example.com/video.mp4")!, kind: .file, title: "Video", headers: [:], fetcher: fetcher)

        let track = try await Downloader.fileTrack(media)

        let responseSize = try await webView.callAsyncJavaScript("return window.responseSize;", contentWorld: .page)
        XCTAssertLessThanOrEqual(try XCTUnwrap(responseSize as? Int), 16)
        XCTAssertEqual(track.segments.map(\.byteRange), [0..<5242880, 5242880..<10485760, 10485760..<10485777])
        XCTAssertTrue(track.segments.allSatisfy { $0.url == media.url })
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
        ready.fulfill()
    }
}
