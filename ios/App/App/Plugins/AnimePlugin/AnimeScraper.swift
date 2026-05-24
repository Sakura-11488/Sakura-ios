import Foundation
import WebKit

struct AnimeSearchResult {
    let id: String
    let title: String
}

struct AnimeEpisode {
    let id: String
    let number: Int
    let title: String
}

class AnimeScraper: NSObject {

    private static let baseUrl = "https://hianime.dk"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var cfCookies: [HTTPCookie] = []
    private var cfCookiesValid = false
    private let cookieLock = NSLock()

    // MARK: - Cloudflare Bypass

    func ensureCfCookies() throws {
        cookieLock.lock()
        let valid = cfCookiesValid
        cookieLock.unlock()

        if valid { return }

        let semaphore = DispatchSemaphore(value: 0)
        var bypassError: Error?

        DispatchQueue.main.async {
            self.solveCfChallenge { error in
                bypassError = error
                semaphore.signal()
            }
        }

        semaphore.wait()

        if let error = bypassError {
            throw error
        }
    }

    func clearCfCookies() {
        cookieLock.lock()
        cfCookies = []
        cfCookiesValid = false
        cookieLock.unlock()

        DispatchQueue.main.async {
            let dataStore = WKWebsiteDataStore.default()
            dataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies where cookie.domain.contains("hianime") {
                    dataStore.httpCookieStore.delete(cookie)
                }
            }
        }
    }

    private func solveCfChallenge(completion: @escaping (Error?) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)
        webView.customUserAgent = Self.userAgent

        let delegate = CfBypassDelegate()
        webView.navigationDelegate = delegate

        var timeoutTimer: Timer?
        var finished = false

        delegate.onPageLoaded = { [weak self] in
            guard !finished else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let cfCookies = cookies.filter { cookie in
                    cookie.domain.contains("hianime") &&
                    (cookie.name == "cf_clearance" || cookie.name.hasPrefix("__cf"))
                }

                if !cfCookies.isEmpty {
                    finished = true
                    timeoutTimer?.invalidate()

                    self?.cookieLock.lock()
                    self?.cfCookies = cookies.filter { $0.domain.contains("hianime") }
                    self?.cfCookiesValid = true
                    self?.cookieLock.unlock()

                    self?.syncCookiesToURLSession(cookies: cookies.filter { $0.domain.contains("hianime") })

                    webView.stopLoading()
                    webView.removeFromSuperview()
                    completion(nil)
                }
            }
        }

        guard let url = URL(string: Self.baseUrl) else {
            completion(AnimeError.invalidUrl(Self.baseUrl))
            return
        }

        webView.load(URLRequest(url: url))

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            guard !finished else { return }
            finished = true

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                let allHianimeCookies = cookies.filter { $0.domain.contains("hianime") }

                self?.cookieLock.lock()
                self?.cfCookies = allHianimeCookies
                self?.cfCookiesValid = !allHianimeCookies.isEmpty
                self?.cookieLock.unlock()

                if !allHianimeCookies.isEmpty {
                    self?.syncCookiesToURLSession(cookies: allHianimeCookies)
                }

                webView.stopLoading()
                webView.removeFromSuperview()
                completion(nil)
            }
        }
    }

    private func syncCookiesToURLSession(cookies: [HTTPCookie]) {
        let storage = HTTPCookieStorage.shared
        for cookie in cookies {
            storage.setCookie(cookie)
        }
    }

    // MARK: - HTTP Helpers

    private func makeRequest(url: String, referer: String? = nil) throws -> String {
        guard let requestUrl = URL(string: url) else {
            throw AnimeError.invalidUrl(url)
        }

        var request = URLRequest(url: requestUrl, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        cookieLock.lock()
        let cookies = cfCookies
        cookieLock.unlock()

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        var requestError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = error
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                requestError = AnimeError.httpError(0)
                return
            }
            if httpResponse.statusCode == 403 {
                requestError = AnimeError.httpError(403)
                return
            }
            if let data = data {
                result = String(data: data, encoding: .utf8)
            }
        }.resume()

        semaphore.wait()

        if let error = requestError { throw error }
        guard let content = result else { throw AnimeError.emptyResponse }
        return content
    }

    // MARK: - Search

    func searchHiAnime(query: String) throws -> [AnimeSearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(Self.baseUrl)/search?keyword=\(encodedQuery)"
        let html = try makeRequest(url: url, referer: Self.baseUrl)
        return parseSearchResults(html: html)
    }

    private func parseSearchResults(html: String) -> [AnimeSearchResult] {
        var results: [AnimeSearchResult] = []

        let pattern = #"<a\s+[^>]*href="(/[^"]*)"[^>]*class="[^"]*film-poster[^"]*"[^>]*>[\s\S]*?<h3[^>]*class="[^"]*film-name[^"]*"[^>]*>\s*<a[^>]*>([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        for match in matches {
            if match.numberOfRanges >= 3 {
                let href = nsHtml.substring(with: match.range(at: 1))
                let title = nsHtml.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")

                let id = href.hasPrefix("/") ? String(href.dropFirst()) : href
                if !id.isEmpty && !title.isEmpty {
                    results.append(AnimeSearchResult(id: id, title: title))
                }
            }
        }

        if results.isEmpty {
            let simplePattern = #"href="/([^"]+)"[^>]*title="([^"]+)"[^>]*class="[^"]*dynamic-name[^"]*""#
            if let simpleRegex = try? NSRegularExpression(pattern: simplePattern, options: []) {
                let simpleMatches = simpleRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
                for match in simpleMatches {
                    if match.numberOfRanges >= 3 {
                        let id = nsHtml.substring(with: match.range(at: 1))
                        let title = nsHtml.substring(with: match.range(at: 2))
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "&#39;", with: "'")
                        if !id.isEmpty && !title.isEmpty {
                            results.append(AnimeSearchResult(id: id, title: title))
                        }
                    }
                }
            }
        }

        return results
    }

    // MARK: - Episodes

    func getEpisodes(animeId: String) throws -> [AnimeEpisode] {
        let pageUrl = "\(Self.baseUrl)/watch/\(animeId)"
        let html = try makeRequest(url: pageUrl, referer: Self.baseUrl)

        guard let dataIdMatch = html.range(of: #"data-id="(\d+)""#, options: .regularExpression) else {
            let directUrl = "\(Self.baseUrl)/ajax/v2/episode/list/\(animeId)"
            let ajaxHtml = try makeRequest(url: directUrl, referer: pageUrl)
            return parseEpisodes(html: ajaxHtml)
        }

        let dataId = String(html[dataIdMatch])
            .replacingOccurrences(of: "data-id=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")

        let ajaxUrl = "\(Self.baseUrl)/ajax/v2/episode/list/\(dataId)"
        let ajaxResponse = try makeRequest(url: ajaxUrl, referer: pageUrl)

        if let jsonData = ajaxResponse.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let innerHtml = json["html"] as? String {
            return parseEpisodes(html: innerHtml)
        }

        return parseEpisodes(html: ajaxResponse)
    }

    private func parseEpisodes(html: String) -> [AnimeEpisode] {
        var episodes: [AnimeEpisode] = []

        let pattern = #"data-id="(\d+)"[^>]*data-number="(\d+)"[^>]*title="([^"]*)"[^>]*href="/watch/([^"]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        for match in matches {
            if match.numberOfRanges >= 5 {
                let number = Int(nsHtml.substring(with: match.range(at: 2))) ?? 0
                let title = nsHtml.substring(with: match.range(at: 3))
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                let watchPath = nsHtml.substring(with: match.range(at: 4))

                let epId: String
                if let queryStart = watchPath.range(of: "?ep=") {
                    epId = String(watchPath[queryStart.upperBound...])
                } else {
                    epId = nsHtml.substring(with: match.range(at: 1))
                }

                episodes.append(AnimeEpisode(id: epId, number: number, title: title))
            }
        }

        if episodes.isEmpty {
            let simplePattern = #"<a[^>]*href="/watch/[^?]*\?ep=(\d+)"[^>]*data-number="(\d+)"[^>]*title="([^"]*)"#
            if let simpleRegex = try? NSRegularExpression(pattern: simplePattern, options: []) {
                let simpleMatches = simpleRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
                for match in simpleMatches {
                    if match.numberOfRanges >= 4 {
                        let epId = nsHtml.substring(with: match.range(at: 1))
                        let number = Int(nsHtml.substring(with: match.range(at: 2))) ?? 0
                        let title = nsHtml.substring(with: match.range(at: 3))
                            .replacingOccurrences(of: "&amp;", with: "&")
                        episodes.append(AnimeEpisode(id: epId, number: number, title: title))
                    }
                }
            }
        }

        return episodes
    }

    // MARK: - Embed URL Resolution

    func resolveAllEmbedUrls(episodeId: String) throws -> [(url: String, serverName: String)] {
        let serversUrl = "\(Self.baseUrl)/ajax/v2/episode/servers?episodeId=\(episodeId)"
        let serversResponse = try makeRequest(url: serversUrl, referer: Self.baseUrl)

        var serversHtml = serversResponse
        if let jsonData = serversResponse.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let innerHtml = json["html"] as? String {
            serversHtml = innerHtml
        }

        let serverPattern = #"data-id="(\d+)"[^>]*data-type="([^"]*)"[^>]*>[\s\S]*?<span[^>]*>([^<]+)"#
        guard let serverRegex = try? NSRegularExpression(pattern: serverPattern, options: []) else { return [] }

        let nsHtml = serversHtml as NSString
        let matches = serverRegex.matches(in: serversHtml, range: NSRange(location: 0, length: nsHtml.length))

        var embedUrls: [(url: String, serverName: String)] = []

        for match in matches {
            if match.numberOfRanges >= 4 {
                let serverId = nsHtml.substring(with: match.range(at: 1))
                let serverType = nsHtml.substring(with: match.range(at: 2))
                let serverName = nsHtml.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)

                let sourcesUrl = "\(Self.baseUrl)/ajax/v2/episode/sources?id=\(serverId)"
                if let sourcesResponse = try? makeRequest(url: sourcesUrl, referer: Self.baseUrl),
                   let jsonData = sourcesResponse.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let link = json["link"] as? String,
                   !link.isEmpty {
                    embedUrls.append((url: link, serverName: "\(serverName) (\(serverType))"))
                }
            }
        }

        if embedUrls.isEmpty {
            let simplePattern = #"data-id="(\d+)"[^>]*data-type="([^"]*)"#
            if let simpleRegex = try? NSRegularExpression(pattern: simplePattern, options: []) {
                let simpleMatches = simpleRegex.matches(in: serversHtml, range: NSRange(location: 0, length: nsHtml.length))
                for match in simpleMatches {
                    if match.numberOfRanges >= 3 {
                        let serverId = nsHtml.substring(with: match.range(at: 1))
                        let serverType = nsHtml.substring(with: match.range(at: 2))
                        let sourcesUrl = "\(Self.baseUrl)/ajax/v2/episode/sources?id=\(serverId)"
                        if let sourcesResponse = try? makeRequest(url: sourcesUrl, referer: Self.baseUrl),
                           let jsonData = sourcesResponse.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let link = json["link"] as? String,
                           !link.isEmpty {
                            embedUrls.append((url: link, serverName: "Server-\(serverId) (\(serverType))"))
                        }
                    }
                }
            }
        }

        return embedUrls
    }
}

// MARK: - Cloudflare Bypass WKWebView Delegate

private class CfBypassDelegate: NSObject, WKNavigationDelegate {

    var onPageLoaded: (() -> Void)?
    private var checkCount = 0

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.onPageLoaded?()
        }

        if checkCount > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onPageLoaded?()
            }
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.onPageLoaded?()
        }
    }
}
