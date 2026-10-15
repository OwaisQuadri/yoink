import OSLog
import WebKit

let log = Logger(subsystem: "com.owaisquadri.yoink", category: "sniffer")

struct FoundMedia {
    enum Kind {
        case hls
        case dash
        case file
    }

    let url: URL
    let kind: Kind
    let title: String
    let headers: [String: String]
    var fetcher: FrameFetcher?
}

enum YoinkError: LocalizedError {
    case noVideo
    case unreachable
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "Couldn’t find a video on this page"
        case .unreachable: "The video’s servers can’t be reached on this network"
        case .downloadFailed(let reason): reason
        }
    }
}

@MainActor
final class Sniffer: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let adMarkers = ["doubleclick", "googlesyndication", "googleadservices", "imasdk", "dclk", "2mdn", "adservice", "/ads/", "vast", "preroll"]
    private static let clickServer = """
        const pattern = /^\\s*server\\s*\\d+\\s*$/i;
        const buttons = [...document.querySelectorAll('a, button, li, div, span')]
            .filter((element) => pattern.test(element.textContent || ''))
            .filter((element) => ![...element.querySelectorAll('*')].some((child) => pattern.test(child.textContent || '')));
        if (index >= buttons.length) return false;
        buttons[index].click();
        return true;
        """

    private struct Candidate {
        let url: URL
        let kind: String
        let page: String
        let frame: WKFrameInfo
    }

    let webView: WKWebView
    private var hiddenHost: NSView?
    private var pageWindow: NSWindow?
    var onPageClosed: (() -> Void)?
    private var candidates: [Candidate] = []
    private var firstFreshCandidate = 0
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
        firstFreshCandidate = 0
        startSite = Self.site(pageURL.host)
        webView.load(URLRequest(url: pageURL))

        var serverIndex = 0
        var isAnyServerSeen = false
        var isOutOfServers = false
        var isSwitchDue = false
        var lastChange = Date()
        var lastClick = Date()
        var firstSeen: Date?
        let deadline = Date().addingTimeInterval(240)
        while isPageVisible || (Date() < deadline && Date().timeIntervalSince(lastChange) < 60) {
            try await Task.sleep(for: .milliseconds(500))
            if !isPageVisible, try await isChallenged() { showPage() }
            if let chosen = best() {
                isAnyServerSeen = true
                guard let seen = firstSeen else { firstSeen = Date(); continue }
                guard Date().timeIntervalSince(seen) > 4 else { continue }
                var media = await makeMedia(chosen)
                do { try await Downloader.probe(media); return media } catch {
                    log.error("direct probe failed \(chosen.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                media.fetcher = FrameFetcher(webView: webView, frame: chosen.frame)
                do { try await Downloader.probe(media); return media } catch {
                    log.error("frame probe failed \(chosen.url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                firstFreshCandidate = candidates.count
                firstSeen = nil
                lastChange = Date()
                isSwitchDue = true
                continue
            }
            if !isOutOfServers, isSwitchDue || Date().timeIntervalSince(lastChange) > 25 {
                isSwitchDue = false
                serverIndex += 1
                let isClicked = try await webView.callAsyncJavaScript(Self.clickServer, arguments: ["index": serverIndex], contentWorld: .page) as? Bool ?? false
                log.info("server \(serverIndex) clicked: \(isClicked)")
                if isClicked {
                    firstFreshCandidate = candidates.count
                    lastChange = Date()
                } else {
                    isOutOfServers = true
                }
                continue
            }
            if !isPageVisible, isOutOfServers || !isAnyServerSeen, Date().timeIntervalSince(lastClick) > 5 {
                clickCenter()
                lastClick = Date()
            }
        }
        throw isAnyServerSeen ? YoinkError.unreachable : YoinkError.noVideo
    }

    private func clickCenter() {
        guard let window = webView.window else { return }
        let point = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }

    var isPageVisible: Bool {
        pageWindow?.isVisible ?? false
    }

    func attach(to host: NSView) {
        hiddenHost = host
        if !isPageVisible { host.addSubview(webView) }
    }

    func showPage() {
        let window = pageWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Yoink"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            pageWindow = window
            return window
        }()
        guard let content = window.contentView else { return }
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
    }

    func hidePage() {
        pageWindow?.orderOut(nil)
        returnToHiddenHost()
    }

    func windowWillClose(_ notification: Notification) {
        returnToHiddenHost()
        onPageClosed?()
    }

    private func returnToHiddenHost() {
        webView.autoresizingMask = []
        webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        hiddenHost?.addSubview(webView)
    }

    private func isChallenged() async throws -> Bool {
        let text = try await webView.evaluateJavaScript("(document.title + ' ' + (document.body ? document.body.innerText.slice(0, 2000) : ''))") as? String ?? ""
        return text.range(of: #"just a moment|verify you are (a )?human|security verification|checking your browser"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func reset() {
        hidePage()
        candidates = []
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func makeMedia(_ chosen: Candidate) async -> FoundMedia {
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
        let kind: FoundMedia.Kind = switch Self.rank(chosen) {
        case 3: .hls
        case 2: .dash
        default: .file
        }
        return FoundMedia(url: chosen.url, kind: kind, title: Self.cleanTitle(webView.title ?? ""), headers: headers)
    }

    private func best() -> Candidate? {
        let usable = candidates[firstFreshCandidate...].filter { candidate in
            let text = candidate.url.absoluteString.lowercased()
            return !Self.adMarkers.contains { text.contains($0) }
        }
        func score(_ candidate: Candidate) -> Int { Self.rank(candidate) * 2 + (candidate.kind == "video" ? 1 : 0) }
        let top = usable.map(score).max()
        return usable.first { score($0) == top }
    }

    private static func rank(_ candidate: Candidate) -> Int {
        let text = candidate.url.absoluteString.lowercased()
        if candidate.kind == "hls" || text.contains("m3u8") { return 3 }
        if candidate.kind == "dash" || text.contains(".mpd") { return 2 }
        return 1
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let text = body["url"] as? String, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return }
        log.info("candidate \(text, privacy: .public)")
        candidates.append(Candidate(url: url, kind: body["kind"] as? String ?? "net", page: body["page"] as? String ?? "", frame: message.frameInfo))
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
