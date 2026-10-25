import Foundation
import Combine
import Network

/// Central coordinator: owns the item list, enforces max parallel downloads,
/// routes video URLs to yt-dlp and plain files to the segmented downloader.
@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    /// Fired whenever the list or an item's coarse state changes so the UI can refresh.
    var onChange: (() -> Void)?

    private var active: [UUID: Task<Void, Never>] = [:]
    private var activeCount: Int { active.count }
    private let network = NWPathMonitor()
    private var online = true
    private var queueSuspended = false

    init() {
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let recovered = !self.online && path.status == .satisfied
                self.online = path.status == .satisfied
                if recovered {
                    for item in self.items where item.retryAt != nil { item.retryAt = Date() }
                    self.tick()
                }
            }
        }
        network.start(queue: DispatchQueue(label: "macdm.network"))
    }
    deinit { network.cancel() }

    var aggregateSpeed: Double { items.reduce(0) { $0 + $1.speedBPS } }

    func tick(now: Date = Date()) {
        let settings = DownloadSettings.shared
        if let start = settings.queueStart, now >= start {
            settings.queueStart = nil
            queueSuspended = false
            resumeAll()
        }
        if let stop = settings.queueStop, now >= stop {
            settings.queueStop = nil
            queueSuspended = true
            pauseAll()
        }
        for item in items where item.state == .queued {
            if let retry = item.retryAt, retry <= now, online { item.retryAt = nil }
            if let scheduled = item.scheduledAt, scheduled <= now { item.scheduledAt = nil }
        }
        DownloadServices.shared.updateSleep(active: activeCount > 0)
        pump()
    }

    func pauseAll() {
        for item in items { pause(item) }
        onChange?()
    }
    func resumeAll() {
        queueSuspended = false
        for item in items where [.paused, .failed, .cancelled].contains(item.state) { retry(item) }
        pump()
    }
    func move(_ item: DownloadItem, offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = max(0, min(items.count - 1, index + offset))
        items.remove(at: index); items.insert(item, at: target)
        onChange?()
    }
    func prioritize(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        move(item, offset: -index)
    }
    @discardableResult
    func addBatch(_ text: String, startNow: Bool = true) -> (added: Int, rejected: Int) {
        var added = 0, rejected = 0
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if add(url: line, startNow: startNow) != nil { added += 1 } else { rejected += 1 }
        }
        return (added, rejected)
    }


    @discardableResult
    func add(url raw: String, maxHeight: Int? = nil, referrer: String? = nil,
             cookies: String? = nil, userAgent: String? = nil,
             startNow: Bool = true, filename: String? = nil, mime: String? = nil,
             forceVideo: Bool = false, audioOnly: Bool = false,
             mediaFormat: String? = nil, subtitles: Bool = false, playlistItems: String? = nil) -> DownloadItem? {
        guard let url = DownloadInput.url(raw) else { return nil }
        // Same URL at the same cap = duplicate; the same page at a DIFFERENT
        // quality cap is a distinct file and must be addable.
        guard !items.contains(where: { $0.url == url && $0.maxHeight == maxHeight && $0.audioOnly == audioOnly && $0.mediaFormat == (mediaFormat ?? (VideoDetector.ffmpegPath == nil ? "source" : "mp4")) && $0.subtitles == subtitles && $0.playlistItems == playlistItems }) else { return nil }
        let item = DownloadItem(url: url, maxHeight: maxHeight)
        item.destinationDirectory = DownloadItem.destinationFolder(for: item.category).path
        item.connectionCount = DownloadSettings.shared.connections
        item.referrerURL = referrer
        item.cookies = cookies
        item.userAgent = userAgent
        item.forceVideo = forceVideo
        item.audioOnly = audioOnly; item.mediaFormat = mediaFormat ?? (VideoDetector.ffmpegPath == nil ? "source" : "mp4")
        item.subtitles = subtitles; item.playlistItems = playlistItems
        if audioOnly { item.category = .music }
        else if forceVideo { item.category = .videos }
        // the browser's resolved name categorizes (and names) extension-less URLs
        if filename?.isEmpty == false || mime?.isEmpty == false {
            item.category = DownloadCategory.detect(url: url, mimeType: mime, filename: filename)
        }
        if let f = filename, !f.isEmpty, URL(string: url)?.pathExtension.isEmpty != false {
            item.resolvedFilename = sanitizeFilename(f)
        }
        item.destinationDirectory = DownloadItem.destinationFolder(for: item.category).path
        items.append(item)
        if startNow {
            pump()
        } else {
            item.state = .paused   // manual resume via the play button
        }
        onChange?()
        return item
    }

    func retry(_ item: DownloadItem) {
        guard [.paused, .failed, .cancelled].contains(item.state), items.contains(where: { $0.id == item.id }) else { return }
        item.retryCount = 0; item.retryAt = nil; item.scheduledAt = nil
        item.resetSpeed()
        item.error = nil
        item.state = .queued
        onChange?()
        pump()
    }

    /// Stops an in-flight (or queued) download and marks it paused.
    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .fetching || item.state == .queued else { return }
        active[item.id]?.cancel()
        item.retryAt = nil
        item.scheduledAt = nil
        item.state = .paused
        item.resetSpeed()
        onChange?()
        pump()
    }

    /// Replaces a paused/failed download's URL and restarts it from scratch.
    func updateURL(_ item: DownloadItem, newURL raw: String, maxHeight: Int? = nil) {
        guard let url = DownloadInput.url(raw) else { return }
        active[item.id]?.cancel()
        item.cleanupTemporaryFiles()
        item.url = url
        if let h = maxHeight { item.maxHeight = h }
        item.error = nil
        item.receivedBytes = 0
        item.totalBytes = 0
        item.segments = []
        item.state = .queued
        onChange?()
        pump()
    }

    func cancel(_ item: DownloadItem) {
        active[item.id]?.cancel()
        item.retryAt = nil
        item.state = .cancelled
        item.resetSpeed()
        onChange?()
    }

    /// Removes the item; optionally trashes the finished file from disk.
    /// Temporary/partial files are always cleaned up.
    func remove(_ item: DownloadItem, deleteFileFromDisk: Bool) {
        let wasCompleted = item.state == .completed
        cancel(item)
        item.cleanupTemporaryFiles()
        if deleteFileFromDisk, wasCompleted {
            try? FileManager.default.trashItem(at: item.fileURL, resultingItemURL: nil)
        }
        items.removeAll { $0.id == item.id }
        onChange?()
    }

    func revealInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    /// Starts queued items while staying under the concurrency limit.
    nonisolated func pump() {
        Task { @MainActor [self] in
            guard self.online, !self.queueSuspended, DownloadSettings.shared.queueStart == nil else { return }
            for item in self.items where self.activeCount < DownloadSettings.shared.concurrentDownloads {
                guard item.state == .queued, item.retryAt == nil, item.scheduledAt == nil, active[item.id] == nil else { continue }
                let task = Task { [weak self] in
                    await self?.run(item)
                    guard let self else { return }
                    if !Task.isCancelled, item.state == .completed, let expected = item.expectedSHA256 {
                        item.verifying = true
                        do {
                            item.actualSHA256 = try await Integrity.sha256(item.fileURL)
                            if item.actualSHA256 != expected { item.error = "SHA-256 mismatch. File retained for inspection."; item.state = .failed }
                        } catch where Task.isCancelled { }
                        catch { item.error = error.localizedDescription; item.state = .failed }
                        item.verifying = false
                    }
                    if !Task.isCancelled, item.state == .failed, item.retryable,
                       item.retryCount < DownloadSettings.shared.retries {
                        item.retryCount += 1
                        item.retryAt = Date().addingTimeInterval(min(60, pow(2, Double(item.retryCount))))
                        item.state = .queued
                    } else if !Task.isCancelled, [.completed, .failed].contains(item.state) {
                        DownloadServices.shared.notify(item)
                    }
                    item.resetSpeed()
                    self.active[item.id] = nil
                    await BandwidthLimiter.shared.forget(item.id)
                    DownloadServices.shared.updateSleep(active: self.activeCount > 0)
                    self.onChange?(); self.pump()
                }
                active[item.id] = task
            }
        }
    }

    private func run(_ item: DownloadItem) async {
        guard !Task.isCancelled else { return }
        item.retryable = false
        item.resetSpeed()
        // Video/music-site URL or raw HLS/DASH playlist: try plain HTTP first
        // for direct media links, fall back to yt-dlp for page-style URLs,
        // embeds, and playlists (a playlist fetched directly would only save
        // the m3u8/mpd text, not the video).
        if item.forceVideo || VideoDetector.isSupportedSite(item.url) || VideoDetector.isStreamURL(item.url) {
            item.isVideoTask = true
            item.category = item.audioOnly ? .music : .videos
            item.state = .fetching

            let direct = await VideoDetector.isDirectMedia(item.url)
            guard !Task.isCancelled else { return }
            if direct && !item.audioOnly && !item.subtitles && item.playlistItems == nil && (item.mediaFormat == "source" || URL(string: item.url)?.pathExtension.lowercased() == item.mediaFormat) {
                let downloader = SegmentedDownloader(item: item)
                await downloader.start()
                if item.state == .completed {
                    item.videoFormat = item.destination.pathExtension
                    item.videoQuality = DownloadItem.qualityLabel(forHeight: item.maxHeight) ?? "—"
                    return
                }
                guard !Task.isCancelled else { return }
                // direct attempt failed — reset and fall through to yt-dlp
                item.error = nil
                item.receivedBytes = 0
                item.totalBytes = 0
                item.state = .fetching
            }

            do {
                let info = try await VideoDetector.fetchInfo(url: item.url, cookies: item.cookies, userAgent: item.userAgent)
                try Task.checkCancellation()
                item.videoTitle = sanitizeFilename(info.title ?? "video")
                item.usedYtDlp = true
                if info.duration ?? 0 < 600, (info.extractor ?? "").lowercased().contains("soundcloud") {
                    item.category = .music
                }
                item.videoQuality = item.audioOnly ? "Audio" : item.maxHeight.map { "≤\($0)p" } ?? "Best"
                item.state = .downloading
                let finalPath = try await VideoDetector.download(
                    url: item.url,
                    to: item.outputFolder,
                    maxHeight: item.maxHeight,
                    cookies: item.cookies,
                    userAgent: item.userAgent,
                    audioOnly: item.audioOnly, container: item.mediaFormat,
                    subtitles: item.subtitles, playlistItems: item.playlistItems,
                    speedLimit: videoRateLimit(item), identity: item.id.uuidString,
                    onQuality: { height in
                        Task { @MainActor in
                            if item.state == .downloading { item.videoQuality = DownloadItem.qualityLabel(forHeight: height) }
                        }
                    }
                ) { pct, done, total in
                    Task { @MainActor in
                        guard !Task.isCancelled, item.state == .downloading else { return }
                        item.recordProgress(received: done, total: total)
                    }
                }
                try Task.checkCancellation()
                guard let finalPath, FileManager.default.fileExists(atPath: finalPath) else {
                    throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "yt-dlp finished without a readable output file."])
                }
                if let path = Optional(finalPath) {
                    let url = URL(fileURLWithPath: path)
                    item.resolvedFilename = url.lastPathComponent
                    if item.playlistItems != nil { item.videoTitle = url.deletingPathExtension().lastPathComponent }
                    item.videoFormat = url.pathExtension
                    // progress parsing can miss (single-file selection prints
                    // no [download] table) — the file on disk is the truth
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let size = attrs[.size] as? Int64, size > 0 {
                        item.totalBytes = size
                        item.receivedBytes = size
                    }
                }
                item.speedBPS = 0
                item.state = .completed
            } catch where Task.isCancelled {
                return
            } catch {
                let description = error.localizedDescription.lowercased()
                item.retryable = ((error as? URLError).map { [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains($0.code) } ?? false)
                    || ["timed out", "connection reset", "temporary failure", "http error 503", "http error 502", "http error 500", "http error 429", "network is unreachable"].contains(where: description.contains)
                item.error = error.localizedDescription
                item.speedBPS = 0
                item.state = .failed
            }
            return
        }

        let downloader = SegmentedDownloader(item: item)
        await downloader.start()
        item.speedBPS = 0
    }

    private func videoRateLimit(_ item: DownloadItem) -> Int64 {
        let global = DownloadSettings.shared.speedLimit
        let share = global > 0 ? max(1, global / Int64(DownloadSettings.shared.concurrentDownloads)) : 0
        if item.speedLimit > 0 && share > 0 { return min(item.speedLimit, share) }
        return max(item.speedLimit, share)
    }

    private func sanitizeFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: invalid).joined(separator: "_")
    }
}

import AppKit
