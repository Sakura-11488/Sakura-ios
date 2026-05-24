import Foundation
import WebKit

struct SubtitleTrack {
    let url: String
    let label: String
}

struct ExtractedStream {
    let m3u8Url: String
    let referer: String
    let subtitles: [SubtitleTrack]
}

struct ExtractionResult {
    let stream: ExtractedStream?
    let debugLog: String
    let isFileNotFound: Bool
}

class WebViewExtractor: NSObject {

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let extractionTimeout: TimeInterval = 30

    func extract(embedUrl: String) throws -> ExtractionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ExtractionResult?

        DispatchQueue.main.async {
            self.performExtraction(embedUrl: embedUrl) { extractionResult in
                result = extractionResult
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + Self.extractionTimeout + 5)
        if waitResult == .timedOut {
            return ExtractionResult(stream: nil, debugLog: "Extraction timed out", isFileNotFound: false)
        }

        return result ?? ExtractionResult(stream: nil, debugLog: "No result", isFileNotFound: false)
    }

    private func performExtraction(embedUrl: String, completion: @escaping (ExtractionResult) -> Void) {
        guard let url = URL(string: embedUrl) else {
            completion(ExtractionResult(stream: nil, debugLog: "Invalid URL: \(embedUrl)", isFileNotFound: false))
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let interceptScript = WKUserScript(
            source: Self.interceptorJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(interceptScript)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)
        webView.customUserAgent = Self.userAgent

        let delegate = ExtractorDelegate(embedUrl: embedUrl)
        webView.navigationDelegate = delegate

        let handler = ExtractorMessageHandler()
        config.userContentController.add(handler, name: "m3u8Interceptor")

        var finished = false
        var debugLog = ""

        handler.onM3u8Found = { m3u8Url, subtitles in
            guard !finished else { return }
            finished = true

            let referer: String
            if let host = url.host, let scheme = url.scheme {
                referer = "\(scheme)://\(host)/"
            } else {
                referer = "https://hianime.dk/"
            }

            debugLog += "Found m3u8: \(m3u8Url)\n"
            let stream = ExtractedStream(m3u8Url: m3u8Url, referer: referer, subtitles: subtitles)

            webView.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
            webView.removeFromSuperview()

            completion(ExtractionResult(stream: stream, debugLog: debugLog, isFileNotFound: false))
        }

        delegate.onError = { error, isNotFound in
            guard !finished else { return }
            finished = true
            debugLog += "Navigation error: \(error)\n"

            webView.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
            webView.removeFromSuperview()

            completion(ExtractionResult(stream: nil, debugLog: debugLog, isFileNotFound: isNotFound))
        }

        delegate.onPageLoaded = { [weak webView] in
            guard !finished, let webView = webView else { return }
            debugLog += "Page loaded, checking for m3u8...\n"

            webView.evaluateJavaScript(Self.pollJS) { _, _ in }
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://hianime.dk/", forHTTPHeaderField: "Referer")
        webView.load(request)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extractionTimeout) {
            guard !finished else { return }
            finished = true
            debugLog += "Extraction timed out after \(Self.extractionTimeout)s\n"

            webView.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
            webView.removeFromSuperview()

            completion(ExtractionResult(stream: nil, debugLog: debugLog, isFileNotFound: false))
        }
    }

    // JS injected at document start to intercept XHR and fetch calls that return m3u8 URLs
    private static let interceptorJS = """
    (function() {
        window.__capturedM3u8 = null;
        window.__capturedSubs = [];

        // Intercept XMLHttpRequest
        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url) {
            this._interceptUrl = url;
            return origOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function() {
            this.addEventListener('load', function() {
                try {
                    const url = this._interceptUrl || '';
                    if (url.includes('.m3u8') || url.includes('getSources')) {
                        const text = this.responseText;
                        // Direct m3u8 URL in response
                        if (url.endsWith('.m3u8') || url.includes('.m3u8?')) {
                            window.__capturedM3u8 = url;
                            window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                                type: 'found',
                                url: url,
                                subtitles: window.__capturedSubs
                            });
                        }
                        // getSources API response
                        if (text && text.includes('"sources"')) {
                            try {
                                const json = JSON.parse(text);
                                let sourceUrl = null;
                                if (Array.isArray(json.sources) && json.sources.length > 0) {
                                    sourceUrl = json.sources[0].file || json.sources[0].url;
                                } else if (typeof json.sources === 'string') {
                                    // Encrypted sources -- the m3u8 is in the encrypted blob
                                    // Try to find it after decryption via the player
                                }
                                if (json.tracks) {
                                    json.tracks.forEach(function(t) {
                                        if (t.file && t.kind !== 'thumbnails') {
                                            window.__capturedSubs.push({url: t.file, label: t.label || 'Track'});
                                        }
                                    });
                                }
                                if (sourceUrl) {
                                    window.__capturedM3u8 = sourceUrl;
                                    window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                                        type: 'found',
                                        url: sourceUrl,
                                        subtitles: window.__capturedSubs
                                    });
                                }
                            } catch(e) {}
                        }
                    }
                } catch(e) {}
            });
            return origSend.apply(this, arguments);
        };

        // Intercept fetch
        const origFetch = window.fetch;
        window.fetch = function(input, init) {
            const url = typeof input === 'string' ? input : (input.url || '');
            return origFetch.apply(this, arguments).then(function(response) {
                if (url.includes('.m3u8') || url.includes('getSources')) {
                    response.clone().text().then(function(text) {
                        if (url.endsWith('.m3u8') || url.includes('.m3u8?')) {
                            window.__capturedM3u8 = url;
                            window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                                type: 'found',
                                url: url,
                                subtitles: window.__capturedSubs
                            });
                        }
                        if (text && text.includes('"sources"')) {
                            try {
                                const json = JSON.parse(text);
                                let sourceUrl = null;
                                if (Array.isArray(json.sources) && json.sources.length > 0) {
                                    sourceUrl = json.sources[0].file || json.sources[0].url;
                                }
                                if (json.tracks) {
                                    json.tracks.forEach(function(t) {
                                        if (t.file && t.kind !== 'thumbnails') {
                                            window.__capturedSubs.push({url: t.file, label: t.label || 'Track'});
                                        }
                                    });
                                }
                                if (sourceUrl) {
                                    window.__capturedM3u8 = sourceUrl;
                                    window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                                        type: 'found',
                                        url: sourceUrl,
                                        subtitles: window.__capturedSubs
                                    });
                                }
                            } catch(e) {}
                        }
                    });
                }
                return response;
            });
        };

        // Intercept video src assignments
        const origDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (origDescriptor && origDescriptor.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                set: function(val) {
                    if (val && (val.includes('.m3u8') || val.includes('master'))) {
                        window.__capturedM3u8 = val;
                        window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                            type: 'found',
                            url: val,
                            subtitles: window.__capturedSubs
                        });
                    }
                    return origDescriptor.set.call(this, val);
                },
                get: origDescriptor.get,
                configurable: true
            });
        }
    })();
    """

    // JS to poll for captured m3u8 after page load
    private static let pollJS = """
    (function() {
        var attempts = 0;
        var maxAttempts = 20;
        function check() {
            if (window.__capturedM3u8) {
                window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                    type: 'found',
                    url: window.__capturedM3u8,
                    subtitles: window.__capturedSubs || []
                });
                return;
            }
            // Also check for video elements with src
            var videos = document.querySelectorAll('video');
            for (var i = 0; i < videos.length; i++) {
                var src = videos[i].src || videos[i].currentSrc;
                if (src && (src.includes('.m3u8') || src.includes('master'))) {
                    window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                        type: 'found',
                        url: src,
                        subtitles: window.__capturedSubs || []
                    });
                    return;
                }
                var sources = videos[i].querySelectorAll('source');
                for (var j = 0; j < sources.length; j++) {
                    if (sources[j].src && sources[j].src.includes('.m3u8')) {
                        window.webkit.messageHandlers.m3u8Interceptor.postMessage({
                            type: 'found',
                            url: sources[j].src,
                            subtitles: window.__capturedSubs || []
                        });
                        return;
                    }
                }
            }
            attempts++;
            if (attempts < maxAttempts) {
                setTimeout(check, 500);
            }
        }
        check();
    })();
    """
}

// MARK: - WKScriptMessageHandler

private class ExtractorMessageHandler: NSObject, WKScriptMessageHandler {

    var onM3u8Found: ((String, [SubtitleTrack]) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "found",
              let url = body["url"] as? String,
              !url.isEmpty else { return }

        var subtitles: [SubtitleTrack] = []
        if let subs = body["subtitles"] as? [[String: Any]] {
            for sub in subs {
                if let subUrl = sub["url"] as? String, !subUrl.isEmpty {
                    let label = sub["label"] as? String ?? "Track"
                    subtitles.append(SubtitleTrack(url: subUrl, label: label))
                }
            }
        }

        onM3u8Found?(url, subtitles)
    }
}

// MARK: - WKNavigationDelegate

private class ExtractorDelegate: NSObject, WKNavigationDelegate {

    let embedUrl: String
    var onPageLoaded: (() -> Void)?
    var onError: ((String, Bool) -> Void)?

    init(embedUrl: String) {
        self.embedUrl = embedUrl
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let isNotFound = nsError.code == 404
        onError?(error.localizedDescription, isNotFound)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let isNotFound = nsError.code == 404
        onError?(error.localizedDescription, isNotFound)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            if httpResponse.statusCode == 404 {
                onError?("404 Not Found", true)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}
