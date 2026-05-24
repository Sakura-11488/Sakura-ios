import Foundation
import Capacitor
import UIKit
import Photos

@objc(AnimePlugin)
public class AnimePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "AnimePlugin"
    public let jsName = "Anime"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "playEpisode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playLocalEpisode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadEpisode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelDownload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "searchHiAnime", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getEpisodes", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCache", returnType: CAPPluginReturnPromise),
    ]

    private lazy var scraper: AnimeScraper = AnimeScraper()
    private lazy var extractor: WebViewExtractor = WebViewExtractor()

    private let downloadStateLock = NSLock()
    private var downloadCancelledEpisodeIds = Set<String>()

    private func requestDownloadCancel(episodeId: String) {
        downloadStateLock.lock()
        downloadCancelledEpisodeIds.insert(episodeId)
        downloadStateLock.unlock()
    }

    private func clearDownloadCancelFlag(episodeId: String) {
        downloadStateLock.lock()
        downloadCancelledEpisodeIds.remove(episodeId)
        downloadStateLock.unlock()
    }

    private func isDownloadCancelled(episodeId: String) -> Bool {
        downloadStateLock.lock()
        let cancelled = downloadCancelledEpisodeIds.contains(episodeId)
        downloadStateLock.unlock()
        return cancelled
    }

    // MARK: - playEpisode

    @objc func playEpisode(_ call: CAPPluginCall) {
        guard let episodeId = call.getString("episodeId"), !episodeId.isEmpty else {
            call.reject("Missing episodeId parameter")
            return
        }

        let title = call.getString("title") ?? "Episode"
        let hasNext = call.getBool("hasNext") ?? false
        let nextEpisodeTitle = call.getString("nextEpisodeTitle") ?? ""
        let introStart = call.getDouble("introStart")
        let introEnd = call.getDouble("introEnd")
        let streamUrl = call.getString("streamUrl") ?? ""
        let referer = call.getString("referer")

        if !streamUrl.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.presentPlayer(
                    streamUrl: streamUrl,
                    referer: referer,
                    title: title,
                    subtitles: [],
                    episodeId: episodeId,
                    hasNext: hasNext,
                    nextEpisodeTitle: nextEpisodeTitle,
                    introStart: introStart,
                    introEnd: introEnd,
                    isLocal: false,
                    call: call
                )
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.scraper.ensureCfCookies()

                let embedUrls = try self.scraper.resolveAllEmbedUrls(episodeId: episodeId)
                guard !embedUrls.isEmpty else {
                    throw AnimeError.noServers(episodeId)
                }

                var stream: ExtractedStream?
                var workingEmbedUrl = ""

                for (embedUrl, serverName) in embedUrls {
                    NSLog("[AnimePlugin] Trying server %@: %@", serverName, embedUrl)
                    let extraction = try self.extractor.extract(embedUrl: embedUrl)

                    if let s = extraction.stream {
                        stream = s
                        workingEmbedUrl = embedUrl
                        NSLog("[AnimePlugin] Server %@ worked!", serverName)
                        break
                    }

                    if extraction.isFileNotFound {
                        NSLog("[AnimePlugin] Server %@: file not found, trying next...", serverName)
                        continue
                    }

                    NSLog("[AnimePlugin] Server %@: extraction failed, trying next...", serverName)
                }

                guard let resolvedStream = stream else {
                    throw AnimeError.allServersFailed(embedUrls.count)
                }

                var allSubs = resolvedStream.subtitles
                if allSubs.isEmpty && !workingEmbedUrl.isEmpty {
                    allSubs = self.fetchSubtitlesFromApi(embedUrl: workingEmbedUrl)
                }

                DispatchQueue.main.async {
                    self.presentPlayer(
                        streamUrl: resolvedStream.m3u8Url,
                        referer: resolvedStream.referer,
                        title: title,
                        subtitles: allSubs,
                        episodeId: episodeId,
                        hasNext: hasNext,
                        nextEpisodeTitle: nextEpisodeTitle,
                        introStart: introStart,
                        introEnd: introEnd,
                        isLocal: false,
                        call: call
                    )
                }
            } catch {
                NSLog("[AnimePlugin] playEpisode failed: %@", error.localizedDescription)
                call.reject("Native playback failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - playLocalEpisode

    @objc func playLocalEpisode(_ call: CAPPluginCall) {
        guard let filePath = call.getString("filePath"), !filePath.isEmpty else {
            call.reject("Missing filePath")
            return
        }

        let title = call.getString("title") ?? "Episode"
        let episodeId = call.getString("episodeId") ?? ""
        let hasNext = call.getBool("hasNext") ?? false
        let nextEpisodeTitle = call.getString("nextEpisodeTitle") ?? ""
        let introStart = call.getDouble("introStart")
        let introEnd = call.getDouble("introEnd")

        DispatchQueue.main.async { [weak self] in
            self?.presentPlayer(
                streamUrl: filePath,
                referer: nil,
                title: title,
                subtitles: [],
                episodeId: episodeId,
                hasNext: hasNext,
                nextEpisodeTitle: nextEpisodeTitle,
                introStart: introStart,
                introEnd: introEnd,
                isLocal: true,
                call: call
            )
        }
    }

    // MARK: - searchHiAnime

    @objc func searchHiAnime(_ call: CAPPluginCall) {
        let query = call.getString("query") ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.scraper.ensureCfCookies()
                let results = try self.scraper.searchHiAnime(query: query)

                var arr: [[String: Any]] = []
                for r in results {
                    arr.append(["id": r.id, "title": r.title])
                }

                let jsonData = try JSONSerialization.data(withJSONObject: arr)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                call.resolve(["results": jsonString])
            } catch {
                NSLog("[AnimePlugin] searchHiAnime failed: %@", error.localizedDescription)
                call.reject("Search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - getEpisodes

    @objc func getEpisodes(_ call: CAPPluginCall) {
        guard let animeId = call.getString("animeId"), !animeId.isEmpty else {
            call.reject("Missing animeId parameter")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.scraper.ensureCfCookies()
                let episodes = try self.scraper.getEpisodes(animeId: animeId)

                var arr: [[String: Any]] = []
                for ep in episodes {
                    arr.append(["id": ep.id, "number": ep.number, "title": ep.title])
                }

                let jsonData = try JSONSerialization.data(withJSONObject: arr)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                call.resolve(["episodes": jsonString])
            } catch {
                NSLog("[AnimePlugin] getEpisodes failed: %@", error.localizedDescription)
                call.reject("Episodes failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - downloadEpisode

    @objc func downloadEpisode(_ call: CAPPluginCall) {
        guard let episodeId = call.getString("episodeId"), !episodeId.isEmpty else {
            call.reject("Missing episodeId")
            return
        }

        let title = call.getString("title") ?? "Episode"
        let animeTitle = call.getString("animeTitle") ?? "Anime"
        let passedM3u8 = (call.getString("m3u8Url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let passedReferer = call.getString("referer") ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                self.clearDownloadCancelFlag(episodeId: episodeId)
                self.notifyDownload(episodeId: episodeId, progress: 0, state: "extracting")

                let resolvedStream: ExtractedStream
                if !passedM3u8.isEmpty {
                    try self.scraper.ensureCfCookies()
                    if self.isDownloadCancelled(episodeId: episodeId) {
                        self.clearDownloadCancelFlag(episodeId: episodeId)
                        self.notifyDownload(episodeId: episodeId, progress: 0, state: "cancelled")
                        call.reject("Cancelled")
                        return
                    }
                    resolvedStream = ExtractedStream(m3u8Url: passedM3u8, referer: passedReferer, subtitles: [])
                } else {
                    try self.scraper.ensureCfCookies()
                    let embedUrls = try self.scraper.resolveAllEmbedUrls(episodeId: episodeId)
                    guard !embedUrls.isEmpty else {
                        throw AnimeError.noServers(episodeId)
                    }

                    var stream: ExtractedStream?
                    for (embedUrl, _) in embedUrls {
                        if self.isDownloadCancelled(episodeId: episodeId) {
                            self.clearDownloadCancelFlag(episodeId: episodeId)
                            self.notifyDownload(episodeId: episodeId, progress: 0, state: "cancelled")
                            call.reject("Cancelled")
                            return
                        }
                        let extraction = try self.extractor.extract(embedUrl: embedUrl)
                        if let s = extraction.stream {
                            stream = s
                            break
                        }
                    }

                    guard let s = stream else {
                        throw AnimeError.extractionFailed
                    }
                    resolvedStream = s
                }

                if self.isDownloadCancelled(episodeId: episodeId) {
                    self.clearDownloadCancelFlag(episodeId: episodeId)
                    self.notifyDownload(episodeId: episodeId, progress: 0, state: "cancelled")
                    call.reject("Cancelled")
                    return
                }

                self.notifyDownload(episodeId: episodeId, progress: 3, state: "downloading")

                let session = URLSession(configuration: .default)

                let m3u8Content = try self.httpGet(
                    session: session,
                    url: resolvedStream.m3u8Url,
                    referer: resolvedStream.referer
                )
                let baseUrl = String(resolvedStream.m3u8Url.prefix(
                    upTo: resolvedStream.m3u8Url.lastIndex(of: "/") ?? resolvedStream.m3u8Url.endIndex
                )) + "/"

                var segments = self.parseM3u8Segments(
                    content: m3u8Content,
                    baseUrl: baseUrl,
                    manifestUrl: resolvedStream.m3u8Url
                )

                guard !segments.isEmpty else {
                    throw AnimeError.noSegments
                }

                if segments.count == 1 && segments[0].hasSuffix(".m3u8") {
                    let variantContent = try self.httpGet(
                        session: session,
                        url: segments[0],
                        referer: resolvedStream.referer
                    )
                    let variantBase = String(segments[0].prefix(
                        upTo: segments[0].lastIndex(of: "/") ?? segments[0].endIndex
                    )) + "/"
                    segments = self.parseM3u8Segments(
                        content: variantContent,
                        baseUrl: variantBase,
                        manifestUrl: segments[0]
                    )
                    guard !segments.isEmpty else {
                        throw AnimeError.noSegments
                    }
                }

                if self.isDownloadCancelled(episodeId: episodeId) {
                    self.clearDownloadCancelFlag(episodeId: episodeId)
                    self.notifyDownload(episodeId: episodeId, progress: 0, state: "cancelled")
                    call.reject("Cancelled")
                    return
                }

                self.notifyDownload(episodeId: episodeId, progress: 5, state: "downloading")

                let safeName = "\(animeTitle) - \(title)"
                    .replacingOccurrences(of: "[^a-zA-Z0-9 \\-]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(200)

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent("\(safeName).ts")

                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                FileManager.default.createFile(atPath: tempFile.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: tempFile)
                defer { fileHandle.closeFile() }

                for (index, segUrl) in segments.enumerated() {
                    if self.isDownloadCancelled(episodeId: episodeId) {
                        try? FileManager.default.removeItem(at: tempFile)
                        self.clearDownloadCancelFlag(episodeId: episodeId)
                        self.notifyDownload(episodeId: episodeId, progress: 0, state: "cancelled")
                        call.reject("Cancelled")
                        return
                    }
                    let segData = try self.downloadSegment(
                        session: session,
                        url: segUrl,
                        referer: resolvedStream.referer
                    )
                    fileHandle.write(segData)
                    let progress = 5 + Int(Float(index + 1) / Float(segments.count) * 95)
                    self.notifyDownload(episodeId: episodeId, progress: progress, state: "downloading")
                }

                self.saveToPhotoLibrary(fileUrl: tempFile) { savedUrl in
                    let filePath = savedUrl ?? tempFile.absoluteString
                    self.notifyDownload(episodeId: episodeId, progress: 100, state: "completed", filePath: filePath)
                    call.resolve(["success": true, "filePath": filePath])
                }
            } catch {
                NSLog("[AnimePlugin] downloadEpisode failed: %@", error.localizedDescription)
                self.notifyDownload(episodeId: episodeId, progress: 0, state: "error")
                call.reject("Download failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func cancelDownload(_ call: CAPPluginCall) {
        guard let episodeId = call.getString("episodeId"), !episodeId.isEmpty else {
            call.reject("Missing episodeId")
            return
        }
        requestDownloadCancel(episodeId: episodeId)
        call.resolve(["cancelled": true])
    }

    // MARK: - clearCache

    @objc func clearCache(_ call: CAPPluginCall) {
        scraper.clearCfCookies()
        call.resolve(["cleared": true])
    }

    // MARK: - Private Helpers

    private func presentPlayer(
        streamUrl: String,
        referer: String?,
        title: String,
        subtitles: [SubtitleTrack],
        episodeId: String,
        hasNext: Bool,
        nextEpisodeTitle: String,
        introStart: Double?,
        introEnd: Double?,
        isLocal: Bool,
        call: CAPPluginCall
    ) {
        guard let viewController = self.bridge?.viewController else {
            call.reject("No view controller available")
            return
        }

        let playerVC = SakuraPlayerViewController()
        playerVC.streamUrl = streamUrl
        playerVC.referer = referer
        playerVC.episodeTitle = title
        playerVC.subtitles = subtitles
        playerVC.episodeId = episodeId
        playerVC.hasNext = hasNext
        playerVC.nextEpisodeTitle = nextEpisodeTitle
        playerVC.introStart = introStart
        playerVC.introEnd = introEnd
        playerVC.isLocal = isLocal
        playerVC.modalPresentationStyle = .fullScreen

        playerVC.onDismiss = { completed in
            self.notifyListeners("playbackEnded", data: [
                "episodeId": episodeId,
                "completed": completed,
            ])
            call.resolve(["success": true, "completed": completed])
        }

        viewController.present(playerVC, animated: true)
    }

    private func notifyDownload(episodeId: String, progress: Int, state: String, filePath: String = "") {
        var data: [String: Any] = [
            "episodeId": episodeId,
            "progress": progress,
            "state": state,
        ]
        if !filePath.isEmpty {
            data["filePath"] = filePath
        }
        notifyListeners("downloadProgress", data: data)
    }

    private func fetchSubtitlesFromApi(embedUrl: String) -> [SubtitleTrack] {
        guard let url = URL(string: embedUrl),
              let host = url.host,
              let scheme = url.scheme else { return [] }

        let pathParts = url.path.split(separator: "/").map(String.init)
        guard let videoId = pathParts.last?.split(separator: "?").first.map(String.init) else { return [] }

        let eIdx = pathParts.firstIndex(where: { $0.hasPrefix("e-") })
        let prefix: String
        let eVersion: String
        if let eIdx = eIdx, eIdx > 0 {
            prefix = "/" + pathParts[0..<eIdx].joined(separator: "/")
            eVersion = pathParts[eIdx]
        } else {
            prefix = "/embed-2"
            eVersion = "e-1"
        }

        let apiUrl = "\(scheme)://\(host)\(prefix)/ajax/\(eVersion)/getSources?id=\(videoId)"
        NSLog("[AnimePlugin] Fetching subtitles from API: %@", apiUrl)

        guard let apiURL = URL(string: apiUrl) else { return [] }

        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://hianime.dk/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var subtitles: [SubtitleTrack] = []

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [[String: Any]] else { return }

            for track in tracks {
                guard let file = track["file"] as? String, !file.isEmpty else { continue }
                let kind = track["kind"] as? String ?? ""
                if kind == "thumbnails" { continue }
                let label = track["label"] as? String ?? "Track"
                subtitles.append(SubtitleTrack(url: file, label: label))
            }

            NSLog("[AnimePlugin] API returned %d subtitle tracks", subtitles.count)
        }.resume()

        semaphore.wait()
        return subtitles
    }

    private func httpGet(session: URLSession, url: String, referer: String) throws -> String {
        guard let requestUrl = URL(string: url) else {
            throw AnimeError.invalidUrl(url)
        }

        var request = URLRequest(url: requestUrl, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let origin = URL(string: referer)?.deletingLastPathComponent().absoluteString {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        var requestError: Error?

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = error
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                requestError = AnimeError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
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

    private func downloadSegment(session: URLSession, url: String, referer: String) throws -> Data {
        guard let requestUrl = URL(string: url) else {
            throw AnimeError.invalidUrl(url)
        }

        var request = URLRequest(url: requestUrl, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var requestError: Error?

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = error
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                requestError = AnimeError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
                return
            }
            result = data
        }.resume()

        semaphore.wait()

        if let error = requestError { throw error }
        guard let data = result else { throw AnimeError.emptyResponse }
        return data
    }

    private func parseM3u8Segments(content: String, baseUrl: String, manifestUrl: String) -> [String] {
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        var variants: [(bandwidth: Int, url: String)] = []
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                if let match = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) {
                    let bwStr = line[match].replacingOccurrences(of: "BANDWIDTH=", with: "")
                    let bw = Int(bwStr) ?? 0
                    if i + 1 < lines.count {
                        let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        if !next.isEmpty && !next.hasPrefix("#") {
                            variants.append((bw, resolveUrl(path: next, baseUrl: baseUrl, manifestUrl: manifestUrl)))
                        }
                    }
                }
            }
        }

        if !variants.isEmpty {
            if let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) {
                return [best.url]
            }
            return []
        }

        var segments: [String] = []
        for line in lines {
            if line.isEmpty || line.hasPrefix("#") { continue }
            segments.append(resolveUrl(path: line, baseUrl: baseUrl, manifestUrl: manifestUrl))
        }
        return segments
    }

    private func resolveUrl(path: String, baseUrl: String, manifestUrl: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        if path.hasPrefix("/") {
            if let url = URL(string: manifestUrl) {
                return "\(url.scheme ?? "https")://\(url.host ?? "")\(path)"
            }
        }
        return baseUrl + path
    }

    private func saveToPhotoLibrary(fileUrl: URL, completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(fileUrl.absoluteString)
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
            }) { success, error in
                if success {
                    completion(fileUrl.absoluteString)
                } else {
                    NSLog("[AnimePlugin] Failed to save to Photos: %@", error?.localizedDescription ?? "unknown")
                    completion(fileUrl.absoluteString)
                }
            }
        }
    }
}

// MARK: - Error Types

enum AnimeError: LocalizedError {
    case noServers(String)
    case allServersFailed(Int)
    case extractionFailed
    case invalidUrl(String)
    case httpError(Int)
    case emptyResponse
    case noSegments

    var errorDescription: String? {
        switch self {
        case .noServers(let id): return "No servers found for episode \(id)"
        case .allServersFailed(let count): return "All \(count) servers failed"
        case .extractionFailed: return "Failed to extract stream"
        case .invalidUrl(let url): return "Invalid URL: \(url)"
        case .httpError(let code): return "HTTP \(code)"
        case .emptyResponse: return "Empty response"
        case .noSegments: return "No segments in manifest"
        }
    }
}
