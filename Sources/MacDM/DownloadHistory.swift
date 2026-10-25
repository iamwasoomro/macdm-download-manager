import Foundation

/// Browser cookies are deliberately kept in memory, never in history.
struct DownloadRecord: Codable {
    var id: UUID
    var url: String
    var addedAt: Date
    var category: DownloadCategory
    var state: DownloadState
    var maxHeight: Int?
    var referrer: String?
    var filename: String?
    var title: String?
    var total: Int64
    var received: Int64
    var forceVideo: Bool
    var isVideo: Bool
    var format: String?
    var quality: String?
    var directory: String?
    var limit: Int64?
    var scheduled: Date?
    var checksum: String?
    var actualChecksum: String?
    var audio: Bool?
    var container: String?
    var subtitles: Bool?
    var playlist: String?
    var connections: Int?


    init(_ item: DownloadItem) {
        id = item.id; url = item.url; addedAt = item.addedAt
        category = item.category; state = item.state; maxHeight = item.maxHeight
        referrer = item.referrerURL; filename = item.resolvedFilename; title = item.videoTitle
        total = item.totalBytes; received = item.receivedBytes
        forceVideo = item.forceVideo; isVideo = item.isVideoTask
        format = item.videoFormat; quality = item.videoQuality
        directory = item.outputFolder.path; limit = item.speedLimit; scheduled = item.scheduledAt
        checksum = item.expectedSHA256; actualChecksum = item.actualSHA256
        connections = item.connectionCount
        audio = item.audioOnly; container = item.mediaFormat; subtitles = item.subtitles; playlist = item.playlistItems
    }

    func restore() -> DownloadItem {
        let item = DownloadItem(url: url, maxHeight: maxHeight, id: id, addedAt: addedAt)
        item.category = category
        item.state = [.queued, .fetching, .downloading].contains(state) ? .paused : state
        item.referrerURL = referrer; item.resolvedFilename = filename; item.videoTitle = title
        item.totalBytes = total; item.receivedBytes = received; item.estimatedSize = total
        item.forceVideo = forceVideo; item.isVideoTask = isVideo
        item.videoFormat = format; item.videoQuality = quality
        item.destinationDirectory = directory ?? DownloadItem.destinationFolder(for: category).path; item.speedLimit = limit ?? 0; item.scheduledAt = scheduled
        item.expectedSHA256 = checksum; item.actualSHA256 = actualChecksum
        item.connectionCount = connections ?? DownloadSettings.shared.connections
        item.audioOnly = audio ?? false; item.mediaFormat = container ?? "mp4"
        item.subtitles = subtitles ?? false; item.playlistItems = playlist
        if scheduled != nil && state != .completed { item.state = .queued }
        return item
    }
}

@MainActor
extension DownloadManager {
    static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDM/downloads.json")
    }

    func restoreHistory() {
        guard !CommandLine.arguments.contains("--demo"),
              let data = try? Data(contentsOf: Self.historyURL) else { return }
        do {
            items = try JSONDecoder().decode([DownloadRecord].self, from: data).map { $0.restore() }
        } catch {
            NSLog("MacDM: could not read download history: %@", error.localizedDescription)
        }
    }

    func saveHistory() {
        guard !CommandLine.arguments.contains("--demo") else { return }
        do {
            let url = Self.historyURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items.map(DownloadRecord.init))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("MacDM: could not save download history: %@", error.localizedDescription)
        }
    }
}
