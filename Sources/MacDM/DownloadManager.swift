import Foundation
import Combine

/// Central coordinator: owns the item list, enforces max parallel downloads,
/// routes video URLs to yt-dlp and plain files to the segmented downloader.
@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    /// Fired whenever the list or an item's coarse state changes so the UI can refresh.
    var onChange: (() -> Void)?

    private var active: [UUID: Task<Void, Never>] = [:]
    private var activeCount: Int { active.count }

    @discardableResult
    func add(url raw: String, maxHeight: Int? = nil, referrer: String? = nil,
             cookies: String? = nil, userAgent: String? = nil,
             startNow: Bool = true) -> DownloadItem? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        // Same URL at the same cap = duplicate; the same page at a DIFFERENT
        // quality cap is a distinct file and must be addable.
        guard !items.contains(where: { $0.url == url && $0.maxHeight == maxHeight }) else { return nil }
        let item = DownloadItem(url: url, maxHeight: maxHeight)
        item.referrerURL = referrer
        item.cookies = cookies
        item.userAgent = userAgent
        items.insert(item, at: 0)
        if startNow {
            pump()
        } else {
            item.state = .paused   // manual resume via the play button
        }
        onChange?()
        return item
    }

    func retry(_ item: DownloadItem) {
        item.error = nil
        item.state = .queued
        onChange?()
        pump()
    }

    /// Stops an in-flight (or queued) download and marks it paused.
    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .fetching || item.state == .queued else { return }
        active[item.id]?.cancel()
        active[item.id] = nil
        item.state = .paused
        onChange?()
    }

    /// Replaces a paused/failed download's URL and restarts it from scratch.
    func updateURL(_ item: DownloadItem, newURL raw: String, maxHeight: Int? = nil) {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        active[item.id]?.cancel()
        active[item.id] = nil
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
        active[item.id] = nil
        item.state = .cancelled
        onChange?()
    }

    /// Removes the item; optionally trashes the finished file from disk.
    /// Temporary/partial files are always cleaned up.
    func remove(_ item: DownloadItem, deleteFileFromDisk: Bool) {
        cancel(item)
        item.cleanupTemporaryFiles()
        if deleteFileFromDisk, item.state == .completed {
            try? FileManager.default.trashItem(at: item.destination, resultingItemURL: nil)
        }
        items.removeAll { $0.id == item.id }
        onChange?()
    }

    func revealInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    /// Starts queued items while staying under the concurrency limit.
    nonisolated func pump() {
        Task { @MainActor in
            for item in self.items where self.activeCount < SegmentedDownloader.maxConcurrentDownloads {
                guard item.state == .queued, active[item.id] == nil else { continue }
                let task = Task { [weak self] in
                    await self?.run(item)
                    await MainActor.run { self?.active[item.id] = nil; self?.pump() }
                }
                active[item.id] = task
            }
        }
    }

    private func run(_ item: DownloadItem) async {
        // Video/music-site URL or raw HLS/DASH playlist: try plain HTTP first
        // for direct media links, fall back to yt-dlp for page-style URLs,
        // embeds, and playlists (a playlist fetched directly would only save
        // the m3u8/mpd text, not the video).
        if VideoDetector.isSupportedSite(item.url) || VideoDetector.isStreamURL(item.url) {
            item.isVideoTask = true
            item.category = .videos
            item.state = .fetching

            if await VideoDetector.isDirectMedia(item.url) {
                let downloader = SegmentedDownloader(item: item)
                await downloader.start()
                if item.state == .completed {
                    item.videoFormat = item.destination.pathExtension
                    item.videoQuality = DownloadItem.qualityLabel(forHeight: item.maxHeight) ?? "—"
                    return
                }
                // direct attempt failed — reset and fall through to yt-dlp
                item.error = nil
                item.receivedBytes = 0
                item.totalBytes = 0
                item.state = .fetching
            }

            do {
                let info = try await VideoDetector.fetchInfo(url: item.url)
                item.videoTitle = sanitizeFilename(info.title ?? "video")
                item.usedYtDlp = true
                if info.duration ?? 0 < 600, (info.extractor ?? "").lowercased().contains("soundcloud") {
                    item.category = .music
                }
                item.videoQuality = DownloadItem.qualityLabel(forHeight: item.maxHeight) ?? "Best"
                item.state = .downloading
                let finalPath = try await VideoDetector.download(
                    url: item.url,
                    to: DownloadItem.destinationFolder(for: item.category),
                    maxHeight: item.maxHeight,
                    cookies: item.cookies,
                    userAgent: item.userAgent
                ) { pct, done, total in
                    Task { @MainActor in
                        item.recordProgress(received: done, total: total)
                    }
                }
                if let path = finalPath {
                    let url = URL(fileURLWithPath: path)
                    item.resolvedFilename = url.lastPathComponent
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
            } catch {
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

    private func sanitizeFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: invalid).joined(separator: "_")
    }
}

import AppKit
