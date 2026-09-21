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
        case .compressed:return ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "iso", "tgz", "zst", "jar"]
        case .other:   return []
        }
    }

    static func detect(url: String, mimeType: String? = nil) -> DownloadCategory {
        let ext = (URL(string: url)?.pathExtension ?? URL(fileURLWithPath: url).pathExtension).lowercased()
        for cat in [DownloadCategory.videos, .music, .programs, .compressed] where cat.extensions.contains(ext) {
            return cat
        }
        // yt-dlp supported sites are video/music platforms — but only when the
        // URL doesn't point at a concrete file (extension wins over host)
        if ext.isEmpty, VideoDetector.isSupportedSite(url) {
            return .videos
        }
        if let mime = mimeType?.lowercased() {
            if mime.hasPrefix("video/") { return .videos }
            if mime.hasPrefix("audio/") { return .music }
            if mime.contains("zip") || mime.contains("compressed") || mime.contains("gzip") { return .compressed }
            if mime.contains("octet-stream") { return .programs }
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
    let id = UUID()
    var url: String               // mutable: refreshed via "Refresh Download"
    let addedAt = Date()
    /// Page the download was sent from (Chrome extension), used by
    /// "Refresh Download from Browser" and refresh matching.
    var referrerURL: String?
    /// Size shown at intake; -1 unknown. Used for same-file detection.
    var estimatedSize: Int64 = -1
    /// Browser context forwarded by the extension for authenticated downloads.
    var cookies: String?
    var userAgent: String?
    var resolvedFilename: String?
    @Published var category: DownloadCategory
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

    init(url: String, maxHeight: Int? = nil) {
        self.url = url
        self.maxHeight = maxHeight
        self.category = DownloadCategory.detect(url: url)
    }

    var progress: Double {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
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
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDM", isDirectory: true)
            .appendingPathComponent(category.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var destination: URL {
        Self.destinationFolder(for: category).appendingPathComponent(filename)
    }

    var tempSegmentsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macdm-\(id.uuidString)", isDirectory: true)
    }

    /// Removes partial segment files and yt-dlp `.part` leftovers for this item.
    func cleanupTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempSegmentsDirectory)
        guard isVideoTask, let title = videoTitle else { return }
        let folder = Self.destinationFolder(for: category)
        let prefix = String(title.prefix(24))
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "part" || f.pathExtension == "ytdl" {
            if f.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
