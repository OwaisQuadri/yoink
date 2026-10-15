import WebKit

@MainActor
final class FrameFetcher {
    private static let script = """
        const response = await fetch(url, { headers: range ? { Range: range } : {}, signal: AbortSignal.timeout(timeout) });
        if (response.status !== 200 && response.status !== 206) throw new Error('status ' + response.status);
        const total = (response.headers.get('content-range') || '').split('/')[1] || '';
        const bytes = new Uint8Array(await response.arrayBuffer());
        let binary = '';
        for (let index = 0; index < bytes.length; index += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
        }
        return { status: response.status, total, data: btoa(binary) };
        """

    private let webView: WKWebView
    private let frame: WKFrameInfo

    init(webView: WKWebView, frame: WKFrameInfo) {
        self.webView = webView
        self.frame = frame
    }

    func fetch(_ url: URL, range: Range<Int>?, timeout: TimeInterval) async throws -> (data: Data, total: Int?, isPartial: Bool) {
        let header = range.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" } ?? ""
        let arguments: [String: Any] = ["url": url.absoluteString, "range": header, "timeout": Int(timeout * 1000)]
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let result = try await webView.callAsyncJavaScript(Self.script, arguments: arguments, in: frame, contentWorld: .page)
                    guard let body = result as? [String: Any], let encoded = body["data"] as? String,
                          let data = Data(base64Encoded: encoded) else { throw YoinkError.downloadFailed("The page refused the download") }
                    if gate.open() { continuation.resume(returning: (data, Int(body["total"] as? String ?? ""), (body["status"] as? Int) == 206)) }
                } catch {
                    if gate.open() { continuation.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout + 5))
                if gate.open() { continuation.resume(throwing: YoinkError.downloadFailed("The page stopped responding")) }
            }
        }
    }
}

@MainActor
private final class Gate {
    private var isOpen = true

    func open() -> Bool {
        defer { isOpen = false }
        return isOpen
    }
}
