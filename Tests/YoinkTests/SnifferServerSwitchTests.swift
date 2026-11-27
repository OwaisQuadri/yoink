import Testing
import WebKit
@testable import Yoink

@MainActor
struct SnifferServerSwitchTests {
    @Test func switchSkipsDownloadLinksThatOpenNewWindows() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("""
            <ul class="dltabsi">
              <li><div><a href="https://download.invalid/1" target="_blank">SERVER 1</a></div></li>
              <li><div><a href="https://download.invalid/2" target="_blank">SERVER 2</a></div></li>
              <li><div><a href="https://download.invalid/3" target="_blank">SERVER 3</a></div></li>
            </ul>
            <ul class="optitabs">
              <li><div><a href="#tab1">SERVER 1</a></div></li>
              <li><div><a href="#tab2">SERVER 2</a></div></li>
              <li><div><a href="#tab3">SERVER 3</a></div></li>
              <li><div><a href="#tab4">SERVER 4</a></div></li>
              <li><div><a href="#tab5">SERVER 5</a></div></li>
            </ul>
            <script>
            document.addEventListener('click', (event) => {
              event.preventDefault();
              window.clicked = event.target.closest('a').getAttribute('href');
            });
            </script>
            """, baseURL: URL(string: "https://example.invalid/"))
        var attempts = 0
        while try await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('.optitabs')") as? Bool != true, attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(50))
        }

        let isClicked = try await webView.callAsyncJavaScript(Sniffer.clickServer, arguments: ["index": 1], contentWorld: .page) as? Bool
        let clicked = try await webView.evaluateJavaScript("window.clicked") as? String

        #expect(isClicked == true)
        #expect(clicked == "#tab2")
    }
}
