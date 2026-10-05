import Foundation
import WebKit

/// A cikkek teljes szövegének kinyerése a weboldalukból Mozilla Readability.js-szel
/// (ugyanaz, mint a Firefox olvasó nézete).
///
/// A letöltött oldal nem töltődik be a WebView-ba: `DOMParser`-rel dolgozzuk fel, így az oldal saját
/// szkriptjei nem futnak, és képek, stíluslapok sem töltődnek le.
@MainActor
final class FullTextExtractor: NSObject, WKNavigationDelegate {
    struct Extracted {
        let html: String
        let textLength: Int
        let byline: String?
    }

    private nonisolated static let concurrency = 4
    /// Böngészőnek tűnő azonosító: több hírportál elutasítja az ismeretlen klienseket.
    private nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var webView: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    /// Letölti és feldolgozza az oldalakat; a sikertelen URL-ek kimaradnak az eredményből.
    func extract(_ urls: Set<URL>) async -> [URL: Extracted] {
        let pages = await Self.download(urls)
        guard !pages.isEmpty, (try? await prepareWebView()) != nil, let webView else { return [:] }

        var results: [URL: Extracted] = [:]
        for (url, html) in pages {
            if let extracted = try? await parse(html, url: url, in: webView) {
                results[url] = extracted
            }
        }
        return results
    }

    private func parse(_ html: String, url: URL, in webView: WKWebView) async throws -> Extracted? {
        let script = """
        const doc = new DOMParser().parseFromString(html, "text/html");
        const base = doc.createElement("base");
        base.href = url;
        doc.head.prepend(base);
        const article = new Readability(doc).parse();
        if (!article) return null;

        // Az oldal saját elemei, amelyeket a Readability bent hagy. Külön DOMParser-dokumentumban
        // dolgozunk, hogy a képek ne kezdjenek el letöltődni.
        const content = new DOMParser().parseFromString(article.content, "text/html").body;
        const blockSelector = "p, h1, h2, h3, h4, h5, h6, li, blockquote";
        const blocks = () => Array.from(content.querySelectorAll(blockSelector))
            .filter(el => !el.querySelector(blockSelector));
        const text = el => el.textContent.trim();

        // 1. Többször előforduló rövid blokkok (pl. „Kövess minket Facebookon!”).
        const counts = new Map();
        for (const el of blocks()) {
            if (text(el).length < 100) counts.set(text(el), (counts.get(text(el)) || 0) + 1);
        }
        for (const el of blocks()) {
            if (text(el) && counts.get(text(el)) > 1 && !el.querySelector("img")) el.remove();
        }

        // 2. A cikk utolsó mondata utáni rövid, mondatvég nélküli blokkok (pl. „Friss hírek”).
        const remaining = blocks();
        for (let i = remaining.length - 1; i >= 0; i--) {
            const el = remaining[i];
            if (el.querySelector("img") || text(el).length >= 100 || /[.?…"”)]$/.test(text(el))) break;
            el.remove();
        }

        // 3. Üres blokkok, amelyek csak térközt adnának.
        for (const el of Array.from(content.querySelectorAll("p, div, span")).reverse()) {
            if (!text(el) && !el.querySelector("img, picture, figure")) el.remove();
        }

        return { content: content.innerHTML, length: content.textContent.trim().length, byline: article.byline };
        """
        let value = try await webView.callAsyncJavaScript(script, arguments: ["html": html, "url": url.absoluteString],
                                                          contentWorld: .defaultClient)
        guard let result = value as? [String: Any], let content = result["content"] as? String else { return nil }
        return Extracted(html: content, textLength: (result["length"] as? NSNumber)?.intValue ?? 0,
                         byline: (result["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - WebView

    private func prepareWebView() async throws {
        guard webView == nil else { return }
        let source = try String(contentsOf: Self.readabilityURL, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadHTMLString("<html><head></head><body></body></html>", baseURL: nil)
        }
        self.webView = webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    /// Az .app-ban a Resources mappában van, `swift run`-nál a forrásfa Support mappájában.
    private static var readabilityURL: URL {
        Bundle.main.url(forResource: "Readability", withExtension: "js")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Support/Readability.js")
    }

    // MARK: - Letöltés

    private nonisolated static func download(_ urls: Set<URL>) async -> [URL: String] {
        await withTaskGroup(of: (URL, String?).self) { group in
            var pending = Array(urls)
            var pages: [URL: String] = [:]

            func startNext() {
                guard let url = pending.popLast() else { return }
                group.addTask { (url, await fetchPage(url)) }
            }

            for _ in 0..<concurrency { startNext() }
            for await (url, html) in group {
                if let html { pages[url] = html }
                startNext()
            }
            return pages
        }
    }

    private nonisolated static func fetchPage(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("hu-HU,hu;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.contains("html") ?? true
        else { return nil }
        return decode(data, charset: http.textEncodingName)
    }

    private nonisolated static func decode(_ data: Data, charset: String?) -> String? {
        if let charset {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250)
    }
}
