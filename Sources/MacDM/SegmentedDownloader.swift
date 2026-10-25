import Foundation
import Combine

/// Parallel multi-segment HTTP downloader.
/// Probes the server for Range support and total length, splits the file
/// into `segmentCount` chunks, and downloads them concurrently on URLSession
/// worker queues. Progress is coalesced onto the main actor.
enum TransferFailure: Error, LocalizedError {
    case http(Int), rangeIgnored, sourceChanged
    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)" + (code == 401 || code == 403 ? " — refresh this link from your browser." : "")
        case .rangeIgnored: return "Server ignored byte ranges."
        case .sourceChanged: return "The remote file changed during transfer."
        }
    }
}

final class SegmentedDownloader {
    let item: DownloadItem
    private let session: URLSession
    private let queue = DispatchQueue(label: "macdm.downloader")
    private var segmentTasks: [URLSessionTask] = []
    private var segmentFiles: [Int: URL] = [:]
    private let segmentCount: Int
    private var validator: String?
    private var canResume = false
    private var cancellables = Set<AnyCancellable>()
    private(set) var onStateChange: ((DownloadItem) -> Void)?

    static let maxConcurrentDownloads = 3
    static let defaultSegments = 6

    init(item: DownloadItem, segments: Int = SegmentedDownloader.defaultSegments) {
        self.item = item
        self.segmentCount = max(1, item.connectionCount > 0 ? item.connectionCount : segments)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 24 * 3600
        config.timeoutIntervalForRequest = 45
        self.session = URLSession(configuration: config)
    }

    func start() async {
        defer { session.invalidateAndCancel() }
        await MainActor.run { item.state = .fetching }
        do {
            let (totalBytes, acceptsRanges, suggestedName) = try await probe()
            guard totalBytes > 0 else {
                // Unknown size (streaming) — single connection fallback
                try await downloadSingle()
                try Task.checkCancellation()
                await MainActor.run { item.state = .completed }
                return
            }
            await MainActor.run {
                item.totalBytes = totalBytes
                item.resolvedFilename = sanitize(suggestedName ?? item.filename)
                // extension-less URLs default to Other — once the real name is
                // known (Content-Disposition), a "get/12345" that is really a
                // .zip/.rar/.7z moves to Compressed (etc.)
                if item.category == .other {
                    item.category = DownloadCategory.detect(url: item.url, filename: item.resolvedFilename)
                }
                item.state = .downloading
            }
            if acceptsRanges {
                do { try await downloadSegmented(totalBytes: totalBytes) }
                catch TransferFailure.rangeIgnored {
                    try Task.checkCancellation()
                    segmentFiles.removeAll()
                    await MainActor.run { item.segments = []; item.receivedBytes = 0 }
                    try await downloadSingle()
                }
            } else {
                try await downloadSingle()
            }
            try Task.checkCancellation()
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
        } catch where Task.isCancelled {
            // The manager owns the paused/cancelled state.
        } catch is CancellationError {
            await MainActor.run { if item.state != .paused { item.state = .cancelled } }
        } catch {
            await MainActor.run {
                let code = (error as? URLError)?.code
                item.retryable = code.map { [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains($0) } ?? false
                if case TransferFailure.http(let status) = error { item.retryable = status == 408 || status == 429 || status >= 500 }
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
        if http.statusCode == 405 || http.statusCode == 501 {
            try? FileManager.default.removeItem(at: item.tempSegmentsDirectory)
            return (-1, false, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransferFailure.http(http.statusCode)
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? -1
        let accepts = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        // Reuse partial ranges only when the server supplies a stable validator.
        let etag = http.value(forHTTPHeaderField: "ETag")
        validator = (etag?.hasPrefix("W/") == false ? etag : nil) ?? http.value(forHTTPHeaderField: "Last-Modified")
        canResume = validator != nil
        let marker = item.tempSegmentsDirectory.appendingPathComponent("identity")
        let identity = "\(item.url)\n\(length)\n\(validator ?? "")\n\(segmentCount)"
        let previous = try? String(contentsOf: marker, encoding: .utf8)
        if validator == nil || previous != identity {
            try? FileManager.default.removeItem(at: item.tempSegmentsDirectory)
        }
        try FileManager.default.createDirectory(at: item.tempSegmentsDirectory, withIntermediateDirectories: true)
        try identity.write(to: marker, atomically: true, encoding: .utf8)
        let name = http.suggestedFilename
        return (length, accepts, name)
    }

    // MARK: - Segmented transfer

    private func downloadSegmented(totalBytes: Int64) async throws {
        let count = min(segmentCount, Int(totalBytes))
        let chunk = totalBytes / Int64(count)
        var segs: [DownloadSegment] = []
        for i in 0..<count {
            let start = chunk * Int64(i)
            let end = (i == count - 1) ? totalBytes - 1 : start + chunk - 1
            let existing = existingBytes(forSegment: i)
            segs.append(DownloadSegment(index: i, start: start, end: end,
                                        downloaded: min(existing, end - start + 1)))
        }
        let prepared = segs
        await MainActor.run { item.segments = prepared }

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
                            try Task.checkCancellation()
                            try await self.downloadSegment(seg)
                            return
                        } catch {
                            lastError = error
                            if error is CancellationError || Task.isCancelled { throw error }
                            if case TransferFailure.rangeIgnored = error { throw error }
                            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
                        }
                    }
                    throw lastError ?? URLError(.badServerResponse)
                }
            }
            do { while let _ = try await group.next() {} }
            catch { group.cancelAll(); throw error }
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
        if let validator { req.setValue(validator, forHTTPHeaderField: "If-Range") }
        applyBrowserHeaders(to: &req)

        // Streams the body to disk while reporting byte progress
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 200 { throw TransferFailure.rangeIgnored }
        guard http.statusCode == 206 else { throw TransferFailure.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Range")?.lowercased() == "bytes \(seg.start + existing)-\(seg.end)/\(item.totalBytes)" else { throw TransferFailure.sourceChanged }
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
        defer { try? handle.close() }
        var count: Int64 = existing
        var buffer = Data()
        var blockSize = transferBufferSize
        var lastUI = Date.distantPast
        let segIndex = seg.index
        // Streams the body to disk while reporting live byte progress:
        // receivedBytes stays the sum over all segments so the progress bar
        // tracks total file completion, not per-segment completion.
        for try await b in bytes {
            try Task.checkCancellation()
            buffer.append(b)
            if buffer.count >= blockSize {
                try await throttle(buffer.count)
                try handle.write(contentsOf: buffer)
                count += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                blockSize = transferBufferSize
                let now = Date()
                if now.timeIntervalSince(lastUI) > 0.1 {
                    lastUI = now
                    let sampled = count
                    await MainActor.run { item.setSegmentDownloaded(segIndex, downloaded: sampled) }
                }
            }
        }
        if !buffer.isEmpty {
            try await throttle(buffer.count)
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
        let downloaded = count
        await MainActor.run { item.setSegmentDownloaded(segIndex, downloaded: downloaded) }
        queue.sync { segmentFiles[seg.index] = fileURL }
    }

    // MARK: - Single-stream fallback

    private func downloadSingle() async throws {
        guard let url = URL(string: item.url) else { throw URLError(.badURL) }
        try FileManager.default.createDirectory(at: item.tempSegmentsDirectory, withIntermediateDirectories: true)
        let dest = item.tempSegmentsDirectory.appendingPathComponent("single")
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let existing = canResume ? (attrs?[.size] as? Int64 ?? 0) : 0
        var req = URLRequest(url: url)
        if existing > 0 {
            req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            req.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        applyBrowserHeaders(to: &req)
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw TransferFailure.http(http.statusCode) }
        var offset: Int64 = 0
        var total = http.expectedContentLength
        if http.statusCode == 206 {
            guard existing > 0, let range = http.value(forHTTPHeaderField: "Content-Range"),
                  range.hasPrefix("bytes \(existing)-"), let full = Int64(range.split(separator: "/").last ?? ""),
                  full >= existing, total == full - existing else { throw TransferFailure.sourceChanged }
            offset = existing; total = full
        } else {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
        }
        let finalTotal = total
        await MainActor.run {
            item.totalBytes = finalTotal
            item.resolvedFilename = sanitize(http.suggestedFilename ?? item.filename)
            if item.category == .other {
                item.category = DownloadCategory.detect(url: item.url, mimeType: http.mimeType, filename: item.resolvedFilename)
            }
            item.state = .downloading
        }
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var count = offset
        var buffer = Data()
        var blockSize = transferBufferSize
        for try await b in bytes {
            try Task.checkCancellation()
            buffer.append(b)
            if buffer.count >= blockSize {
                try await throttle(buffer.count)
                try handle.write(contentsOf: buffer)
                count += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                blockSize = transferBufferSize
                let c = count
                await MainActor.run { item.recordProgress(received: c) }
            }
        }
        if !buffer.isEmpty {
            try await throttle(buffer.count)
            try handle.write(contentsOf: buffer)
            count += Int64(buffer.count)
        }
        if total >= 0, count != total { throw URLError(.networkConnectionLost) }
        try handle.close()
        let c = count
        await MainActor.run { item.recordProgress(received: c, total: c) }
        try Task.checkCancellation()
        try await publishFile(dest)
        try? FileManager.default.removeItem(at: item.tempSegmentsDirectory)
    }

    private var effectiveRate: Int64 {
        let global = DownloadSettings.shared.speedLimit
        let share = global > 0 ? max(1, global / Int64(DownloadSettings.shared.concurrentDownloads)) : 0
        return item.speedLimit > 0 && share > 0 ? min(item.speedLimit, share) : max(item.speedLimit, share)
    }
    private var transferBufferSize: Int {
        let rate = effectiveRate
        return rate > 0 ? max(1, min(64 * 1024, Int(rate / 10))) : 64 * 1024
    }
    private func throttle(_ bytes: Int) async throws {
        try await BandwidthLimiter.shared.consume(bytes, id: item.id, limit: effectiveRate)
    }

    // MARK: - Assembly

    private func assemble() async throws {
        guard !segmentFiles.isEmpty else { return }
        let dest = item.tempSegmentsDirectory.appendingPathComponent("assembled")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        for index in 0..<segmentCount {
            guard let f = segmentFiles[index] else { continue }
            let input = try FileHandle(forReadingFrom: f)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try out.write(contentsOf: data)
            }
        }
        try out.close()
        try await publishFile(dest)
        try? FileManager.default.removeItem(at: item.tempSegmentsDirectory)
    }

    /// Publish only a finished file; existing user files are never overwritten.
    private func publishFile(_ temporary: URL) async throws {
        try Task.checkCancellation()
        let destination = try await FilePublisher.shared.publish(temporary, to: item.destination)
        let name = destination.lastPathComponent
        await MainActor.run { item.resolvedFilename = name }
    }

    /// Cookies/User-Agent forwarded from the browser, for auth-gated files.
    private func applyBrowserHeaders(to req: inout URLRequest) {
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referrer = item.referrerURL { req.setValue(referrer, forHTTPHeaderField: "Referer") }
        if let c = item.cookies, !c.isEmpty {
            req.setValue(c, forHTTPHeaderField: "Cookie")
        }
        if let ua = item.userAgent, !ua.isEmpty {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "download" : safe
    }
}
