import Foundation

enum DownloadCategory: String, Codable, CaseIterable, Identifiable {
    case music, videos, programs, compressed, other
    var id: String { rawValue }

    var folderName: String { rawValue.capitalized }

    /// Known file extensions used to auto-categorize plain HTTP downloads.
    var extensions: Set<String> {
        switch self {
        case .music:   return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma"]
        case .videos:  return ["mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "ts", "m3u8", "m3u", "mpd"]
        case .programs:return ["dmg", "pkg", "exe", "app", "deb", "rpm", "apk", "ipa"]
        case .compressed:return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "iso", "tgz",
                                 "tbz2", "txz", "jar", "lz4", "lzma", "cab", "lzh", "arj"]
        case .other:   return []
        }
    }

    static func detect(url: String, mimeType: String? = nil, filename: String? = nil) -> DownloadCategory {
        // the browser-resolved filename is the strongest signal — URLs like
        // example.com/get/12345 carry no extension but Content-Disposition does
        let fext = filename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let ext = (URL(string: url)?.pathExtension ?? URL(fileURLWithPath: url).pathExtension).lowercased()
        for cat in [DownloadCategory.videos, .music, .programs, .compressed] where cat.extensions.contains(fext) {
            return cat
        }
        for cat in [DownloadCategory.videos, .music, .programs, .compressed] where cat.extensions.contains(ext) {
            return cat
        }
        // yt-dlp supported sites are video/music platforms — but only when the
        // URL doesn't point at a concrete file (extensions and mime win over host)
        if let mime = mimeType?.lowercased() {
            if mime.hasPrefix("video/") { return .videos }
            if mime.hasPrefix("audio/") { return .music }
            if mime.contains("zip") || mime.contains("compressed") || mime.contains("gzip") { return .compressed }
            if mime.contains("octet-stream") { return .programs }
        }
        if ext.isEmpty, VideoDetector.isSupportedSite(url) {
            return .videos
        }
        return .other
    }
}

/// A download request arriving from the Chrome extension.
struct IncomingDownload {
    var url: String
    var maxHeight: Int?
    var referrer: String?
    var cookies: String?
    var userAgent: String?
    /// Browser-resolved save name (Content-Disposition) — categorization and
    /// the save name fall back to it when the URL carries no extension.
    var filename: String?
    var mimeType: String?
    /// The extension verified video intent (overlay pill, popup page row): the
    /// link must go through yt-dlp even when the host isn't a known video
    /// site — otherwise page-style URLs get saved as HTML.
    var forceVideo: Bool = false
}

enum DownloadState: String, Codable {
    case queued, fetching, downloading, completed, failed, cancelled, paused
}

struct DownloadSegment: Codable {
    let index: Int
    let start: Int64
    let end: Int64   // inclusive
    var downloaded: Int64 = 0
}

final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID
    var url: String               // mutable: refreshed via "Refresh Download"
    let addedAt: Date
    /// Page the download was sent from (Chrome extension), used by
    /// "Refresh Download from Browser" and refresh matching.
    var referrerURL: String?
    /// Size shown at intake; -1 unknown. Used for same-file detection.
    var estimatedSize: Int64 = -1
    /// Browser context forwarded by the extension for authenticated downloads.
    var cookies: String?
    var userAgent: String?
    var resolvedFilename: String?
    @Published var category: DownloadCategory {
        didSet {
            if let directory = destinationDirectory, URL(fileURLWithPath: directory).lastPathComponent == oldValue.folderName {
                destinationDirectory = URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent(category.folderName).path
            }
        }
    }
    @Published var state: DownloadState = .queued
    @Published var totalBytes: Int64 = 0
    @Published var receivedBytes: Int64 = 0
    @Published var segments: [DownloadSegment] = []
    @Published var error: String?
    @Published var isVideoTask = false           // video-site URL
    @Published var usedYtDlp = false             // actually fetched via yt-dlp
    @Published var videoTitle: String?
    @Published var speedBPS: Double = 0   // smoothed bytes/sec while running
    private var lastSpeedSample: (date: Date, bytes: Int64)?
    @Published var videoFormat: String?   // e.g. "mp4"
    @Published var videoQuality: String?  // e.g. "1080p", "4K", "Best"
    /// Preferred maximum resolution height for video downloads (nil = best).
    var maxHeight: Int?
    /// Set by the Add Video sheet: the link was verified to yield a video, so
    /// it must go through yt-dlp even when the host isn't a known video site.
    var forceVideo = false
    var destinationDirectory: String?
    var speedLimit: Int64 = 0
    var scheduledAt: Date?
    var expectedSHA256: String?
    @Published var actualSHA256: String?
    @Published var verifying = false
    @Published var retryCount = 0
    @Published var retryAt: Date?
    var audioOnly = false
    var mediaFormat = "mp4"
    var subtitles = false
    var playlistItems: String?
    var connectionCount = 0
    var retryable = false

    var outputFolder: URL {
        let folder = destinationDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.destinationFolder(for: category)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    var eta: String? {
        guard state == .downloading, speedBPS > 0, totalBytes > receivedBytes else { return nil }
        let seconds = Int(Double(totalBytes - receivedBytes) / speedBPS)
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds / 60 % 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
    func resetSpeed() { speedBPS = 0; lastSpeedSample = nil }


    init(url: String, maxHeight: Int? = nil, id: UUID = UUID(), addedAt: Date = Date()) {
        self.id = id
        self.addedAt = addedAt
        self.url = url
        self.maxHeight = maxHeight
        self.category = DownloadCategory.detect(url: url)
    }

    var progress: Double {
        totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0
    }

    /// Live progress bookkeeping (main actor): records one segment's bytes and
    /// recomputes the aggregate so receivedBytes always reflects the whole file.
    func setSegmentDownloaded(_ index: Int, downloaded: Int64) {
        if let i = segments.firstIndex(where: { $0.index == index }) {
            segments[i].downloaded = downloaded
        }
        recordProgress(received: segments.reduce(0) { $0 + $1.downloaded })
    }

    /// Updates counters and maintains a smoothed speed estimate (samples at
    /// most every 0.5s, exponential moving average).
    func recordProgress(received: Int64, total: Int64? = nil) {
        if let t = total, t > 0 { totalBytes = t }
        let now = Date()
        if let last = lastSpeedSample {
            let dt = now.timeIntervalSince(last.date)
            if dt >= 0.5 {
                let bps = Double(max(0, received - last.bytes)) / dt
                speedBPS = speedBPS <= 0 ? bps : speedBPS * 0.6 + bps * 0.4
                lastSpeedSample = (now, received)
            }
        } else {
            lastSpeedSample = (now, received)
        }
        receivedBytes = received
    }

    var filename: String {
        if let t = videoTitle { return t }
        if let f = resolvedFilename { return f }
        return URL(string: url)?.lastPathComponent ?? url
    }

    /// Video rows render as "NAME | MP4 | 1080p".
    var displayTitle: String {
        guard isVideoTask else { return filename }
        var parts = [filename]
        if let f = videoFormat { parts.append(f.uppercased()) }
        if let q = videoQuality { parts.append(q) }
        return parts.count > 1 ? parts.joined(separator: " | ") : filename
    }

    static func qualityLabel(forHeight h: Int?) -> String? {
        guard let h = h else { return nil }
        if h >= 2160 { return "4K" }
        if h >= 1440 { return "1440p" }
        return "\(h)p"
    }

    /// Destination folder: ~/Downloads/MacDM/<Category>
    static func destinationFolder(for category: DownloadCategory) -> URL {
        let base = DownloadSettings.shared.folder
            .appendingPathComponent(category.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var destination: URL {
        outputFolder.appendingPathComponent(resolvedFilename ?? filename)
    }

    /// The file actually on disk. yt-dlp items resolve under a different name
    /// ("Title (360p).mp4") than `filename` (the bare title), so the resolved
    /// name wins when it exists; prefix matching catches the rest. Reveal,
    /// open-on-double-click and delete-from-disk all go through this.
    var fileURL: URL {
        let folder = outputFolder
        if let r = resolvedFilename {
            let u = folder.appendingPathComponent(r)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let d = destination
        if FileManager.default.fileExists(atPath: d.path) { return d }
        return d
    }

    var tempSegmentsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDM/Partials/\(id.uuidString)", isDirectory: true)
    }

    /// Removes partial segment files and yt-dlp `.part` leftovers for this item.
    func cleanupTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempSegmentsDirectory)
        guard isVideoTask else { return }
        let folder = outputFolder
        let marker = "(" + String(id.uuidString.prefix(8))
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.contains(marker) {
            if file.pathExtension == "part" || file.pathExtension == "ytdl" || file.lastPathComponent.contains(".part-Frag") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
