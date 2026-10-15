import WebKit

struct FoundMedia {
    let url: URL
    let title: String
    let headers: [String: String]
}

enum YoinkError: LocalizedError {
    case noVideo
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "Couldn’t find a video on this page"
        case .downloadFailed(let reason): reason
        }
    }
}

@MainActor
final class Sniffer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let adMarkers = ["doubleclick", "googlesyndication", "googleadservices", "imasdk", "dclk", "2mdn", "adservice", "/ads/", "vast", "preroll"]

    private struct Candidate {
        let url: URL
        let kind: String
        let page: String
    }

    let webView: WKWebView
    private var candidates: [Candidate] = []
    private var startSite = ""

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let scriptURL = Bundle.main.url(forResource: "Sniffer", withExtension: "js") ?? Bundle.module.url(forResource: "Sniffer", withExtension: "js")!
        let script = try! String(contentsOf: scriptURL, encoding: .utf8)
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "yoink")
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    func find(_ pageURL: URL) async throws -> FoundMedia {
        candidates = []
        startSite = Self.site(pageURL.host)
        webView.load(URLRequest(url: pageURL))
        defer { webView.load(URLRequest(url: URL(string: "about:blank")!)) }

        var firstSeen: Date?
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if firstSeen == nil, best() != nil { firstSeen = Date() }
            if let firstSeen, Date().timeIntervalSince(firstSeen) > 5 { break }
        }
        guard let chosen = best() else { throw YoinkError.noVideo }

        var headers = ["Referer": chosen.page]
        if let page = URL(string: chosen.page), let scheme = page.scheme, let host = page.host {
            headers["Origin"] = "\(scheme)://\(host)"
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return chosen.url.host?.hasSuffix(domain) ?? false
            }
        if !cookies.isEmpty {
            headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return FoundMedia(url: chosen.url, title: Self.cleanTitle(webView.title ?? ""), headers: headers)
    }

    private func best() -> Candidate? {
        let usable = candidates.filter { candidate in
            let text = candidate.url.absoluteString.lowercased()
            return !Self.adMarkers.contains { text.contains($0) }
        }
        func rank(_ candidate: Candidate) -> Int {
            let text = candidate.url.absoluteString.lowercased()
            if candidate.kind == "hls" || text.contains("m3u8") { return 3 }
            if candidate.kind == "dash" || text.contains(".mpd") { return 2 }
            return 1
        }
        let top = usable.map(rank).max()
        return usable.first { rank($0) == top }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let text = body["url"] as? String, let url = URL(string: text) else { return }
        candidates.append(Candidate(url: url, kind: body["kind"] as? String ?? "net", page: body["page"] as? String ?? ""))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let host = action.request.url?.host else { return .allow }
        return Self.site(host) == startSite ? .allow : .cancel
    }

    private static func site(_ host: String?) -> String {
        (host ?? "").split(separator: ".").suffix(2).joined(separator: ".")
    }

    private static func cleanTitle(_ title: String) -> String {
        let base = title.components(separatedBy: " | ").first ?? title
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Video" : String(cleaned.prefix(120))
    }
}
