import Foundation
import Combine

/// Parallel multi-segment HTTP downloader.
/// Probes the server for Range support and total length, splits the file
/// into `segmentCount` chunks, and downloads them concurrently on URLSession
/// worker queues. Progress is coalesced onto the main actor.
final class SegmentedDownloader {
    let item: DownloadItem
    private let session: URLSession
    private let queue = DispatchQueue(label: "macdm.downloader")
    private var segmentTasks: [URLSessionTask] = []
    private var segmentFiles: [Int: URL] = [:]
    private let segmentCount: Int
    private var cancellables = Set<AnyCancellable>()
    private(set) var onStateChange: ((DownloadItem) -> Void)?

    static let maxConcurrentDownloads = 3
    static let defaultSegments = 6

    init(item: DownloadItem, segments: Int = SegmentedDownloader.defaultSegments) {
        self.item = item
        self.segmentCount = max(1, segments)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    func start() async {
        await MainActor.run { item.state = .fetching }
        do {
            let (totalBytes, acceptsRanges, suggestedName) = try await probe()
            guard totalBytes > 0 else {
                // Unknown size (streaming) — single connection fallback
                try await downloadSingle()
                return
            }
            await MainActor.run {
                item.totalBytes = totalBytes
                item.resolvedFilename = sanitize(suggestedName ?? item.filename)
                item.state = .downloading
            }
            if acceptsRanges {
                try await downloadSegmented(totalBytes: totalBytes)
            } else {
                try await downloadSingle()
            }
            try await assemble()
            await MainActor.run {
                item.state = .completed
                // Reconcile counters with the assembled file so the manager
                // never shows "0 KB" for a finished non-empty download.
                if item.totalBytes > 0 {
                    item.receivedBytes = item.totalBytes
                } else if let attrs = try? FileManager.default.attributesOfItem(atPath: item.destination.path),
                          let size = attrs[.size] as? Int64, size > 0 {
                    item.totalBytes = size
                    item.receivedBytes = size
                }
                onStateChange?(item)
            }
        } catch let e as CancellationError {
            await MainActor.run { if item.state != .paused { item.state = .cancelled } }
        } catch {
            await MainActor.run {
                item.error = error.localizedDescription
                item.state = .failed
                onStateChange?(item)
            }
        }
    }

    func cancel() {
        queue.sync {
            session.invalidateAndCancel()
            segmentTasks.forEach { $0.cancel() }
        }
    }

    // MARK: - Probe

    private func probe() async throws -> (Int64, Bool, String?) {
        guard let url = URL(string: item.url) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        applyBrowserHeaders(to: &req)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? -1
        let accepts = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        let name = http.suggestedFilename
        return (length, accepts, name)
    }

    // MARK: - Segmented transfer

    private func downloadSegmented(totalBytes: Int64) async throws {
        let chunk = totalBytes / Int64(segmentCount)
        var segs: [DownloadSegment] = []
        for i in 0..<segmentCount {
            let start = chunk * Int64(i)
            let end = (i == segmentCount - 1) ? totalBytes - 1 : start + chunk - 1
            let existing = existingBytes(forSegment: i)
            segs.append(DownloadSegment(index: i, start: start, end: end,
                                        downloaded: min(existing, end - start + 1)))
        }
        await MainActor.run { item.segments = segs }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for seg in segs {
                group.addTask { [weak self] in
                    guard let self else { return }
                    // Auto-retry a failing segment: temp bytes are kept, so each
                    // attempt resumes from where the previous one died instead
                    // of restarting the whole file.
                    var lastError: Error?
                    for attempt in 0..<3 {
                        do {
                            try await self.downloadSegment(seg)
                            return
                        } catch {
                            lastError = error
                            if error is CancellationError { throw error }
                            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
                        }
                    }
                    throw lastError ?? URLError(.badServerResponse)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Bytes already on disk for a segment from a previous attempt.
    private func existingBytes(forSegment index: Int) -> Int64 {
        let fileURL = item.tempSegmentsDirectory.appendingPathComponent("seg-\(index)")
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    private func downloadSegment(_ seg: DownloadSegment) async throws {
        guard let url = URL(string: item.url) else { throw URLError(.badURL) }
        let tmpDir = item.tempSegmentsDirectory
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let fileURL = tmpDir.appendingPathComponent("seg-\(seg.index)")
        let segLength = seg.end - seg.start + 1

        // Resume: if a previous attempt left bytes on disk, continue the Range
        // from there instead of restarting the segment (and the file).
        let existing = min(existingBytes(forSegment: seg.index), segLength)
        if existing >= segLength {
            queue.sync { segmentFiles[seg.index] = fileURL }
            await MainActor.run { item.setSegmentDownloaded(seg.index, downloaded: existing) }
            return
        }

        var req = URLRequest(url: url)
        req.setValue("bytes=\(seg.start + existing)-\(seg.end)", forHTTPHeaderField: "Range")
        applyBrowserHeaders(to: &req)

        // Streams the body to disk while reporting byte progress
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        var handle: FileHandle
        if existing > 0, http.statusCode == 206 {
            // appending to the partial segment from the earlier attempt
            handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
        } else {
            // server ignored the Range (200 = full body) or fresh start
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
        }
        var count: Int64 = existing
        var buffer = Data()
        var lastUI = Date.distantPast
        let segIndex = seg.index
        // Streams the body to disk while reporting live byte progress:
        // receivedBytes stays the sum over all segments so the progress bar
        // tracks total file completion, not per-segment completion.
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                count += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = Date()
                if now.timeIntervalSince(lastUI) > 0.1 {
                    lastUI = now
                    await MainActor.run {
                        item.setSegmentDownloaded(segIndex, downloaded: count)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            count += Int64(buffer.count)
        }
        try handle.close()
        // A server can close early yet still declare a matching (short)
        // Content-Length; anything less than the full segment range is an
        // error so the auto-retry resumes from the bytes already on disk.
        guard count == segLength else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "segment short (\(count)/\(segLength) bytes)"])
        }
        await MainActor.run {
            item.setSegmentDownloaded(segIndex, downloaded: count)
        }
        queue.sync { segmentFiles[seg.index] = fileURL }
    }

    // MARK: - Single-stream fallback

    private func downloadSingle() async throws {
        guard let url = URL(string: item.url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        applyBrowserHeaders(to: &req)
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        await MainActor.run {
            item.totalBytes = http.expectedContentLength
            item.resolvedFilename = sanitize(http.suggestedFilename ?? item.filename)
            item.state = .downloading
        }
        let dest = item.destination
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        var handle = try FileHandle(forWritingTo: dest)
        var count: Int64 = 0
        var buffer = Data()
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                count += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let c = count
                await MainActor.run { item.receivedBytes = c }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()
        let c = count
        await MainActor.run { item.receivedBytes = c }
    }

    // MARK: - Assembly

    private func assemble() async throws {
        guard !segmentFiles.isEmpty else { return }
        let dest = item.destination
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        for index in 0..<segmentCount {
            guard let f = segmentFiles[index] else { continue }
            let data = try Data(contentsOf: f)
            try out.write(contentsOf: data)
            try? FileManager.default.removeItem(at: f)
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("macdm-\(item.id.uuidString)", isDirectory: true))
    }

    /// Cookies/User-Agent forwarded from the browser, for auth-gated files.
    private func applyBrowserHeaders(to req: inout URLRequest) {
        if let c = item.cookies, !c.isEmpty {
            req.setValue(c, forHTTPHeaderField: "Cookie")
        }
        if let ua = item.userAgent, !ua.isEmpty {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}
