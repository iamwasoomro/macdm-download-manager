import Foundation
import AppKit

Task { @MainActor in
    UserDefaults(suiteName: "MacDM.Regression")!.removePersistentDomain(forName: "MacDM.Regression")
    for path in ["tiny", "ranges", "unknown", "no-head", "ignored"] {
        let item = DownloadItem(url: "http://127.0.0.1:17211/\(path)")
        await SegmentedDownloader(item: item).start()
        precondition(item.state == .completed, "\(path): \(item.error ?? item.state.rawValue)")
        let data = try! Data(contentsOf: item.destination)
        precondition(data.count == (path == "tiny" ? 3 : 262144), "incorrect byte count")
        precondition(item.receivedBytes == Int64(data.count))
        if path == "tiny" { precondition(data == Data("abc".utf8)) }
        else { precondition(data == Data((0..<262144).map { UInt8($0 % 256) })) }
        try! FileManager.default.removeItem(at: item.destination)
        item.cleanupTemporaryFiles()
        print("PASS: \(path)")
    }
    let resume = DownloadItem(url: "http://127.0.0.1:17211/single-resume")
    resume.connectionCount = 1
    try! FileManager.default.createDirectory(at: resume.tempSegmentsDirectory, withIntermediateDirectories: true)
    let part = Data((0..<65536).map { UInt8($0 % 256) })
    try! part.write(to: resume.tempSegmentsDirectory.appendingPathComponent("single"))
    let identity = "\(resume.url)\n262144\n\"fixture-v1\"\n1"
    try! identity.write(to: resume.tempSegmentsDirectory.appendingPathComponent("identity"), atomically: true, encoding: .utf8)
    await SegmentedDownloader(item: resume).start()
    precondition(resume.state == .completed, resume.error ?? "resume failed")
    precondition(try! Data(contentsOf: resume.fileURL) == Data((0..<262144).map { UInt8($0 % 256) }))
    try! FileManager.default.removeItem(at: resume.fileURL)
    print("PASS: validated single-stream partial resume")
    let first = DownloadItem(url: "http://127.0.0.1:17211/tiny")
    await SegmentedDownloader(item: first).start()
    let second = DownloadItem(url: "http://127.0.0.1:17211/tiny")
    await SegmentedDownloader(item: second).start()
    precondition(first.destination != second.destination)
    precondition(try! Data(contentsOf: first.destination) == Data("abc".utf8))
    precondition(try! Data(contentsOf: second.destination) == Data("abc".utf8))
    try! FileManager.default.removeItem(at: first.destination)
    try! FileManager.default.removeItem(at: second.destination)
    print("PASS: filename collision preserves both files")
    let owner = DownloadItem(url: "https://example.test/video")
    owner.isVideoTask = true; owner.videoTitle = "Shared title"
    let mine = owner.outputFolder.appendingPathComponent("Shared title (\(owner.id.uuidString.prefix(8))).mp4.part")
    let other = owner.outputFolder.appendingPathComponent("Shared title (other-id).mp4.part")
    try! Data().write(to: mine); try! Data().write(to: other)
    owner.cleanupTemporaryFiles()
    precondition(!FileManager.default.fileExists(atPath: mine.path))
    precondition(FileManager.default.fileExists(atPath: other.path))
    try! FileManager.default.removeItem(at: other)
    print("PASS: removing a video preserves other downloads’ partial files")
    let limited = DownloadItem(url: "http://127.0.0.1:17211/tiny")
    limited.speedLimit = 6
    let started = Date()
    await SegmentedDownloader(item: limited).start()
    precondition(limited.state == .completed && Date().timeIntervalSince(started) >= 0.45)
    try! FileManager.default.removeItem(at: limited.fileURL)
    print("PASS: per-file bandwidth pacing")
    let original = DownloadItem(url: "https://example.test/file", maxHeight: 720)
    original.state = .downloading; original.cookies = "secret"
    original.speedLimit = 1234; original.audioOnly = true; original.mediaFormat = "mp3"
    original.subtitles = true; original.playlistItems = "2"; original.connectionCount = 4
    original.expectedSHA256 = String(repeating: "a", count: 64)
    let encoded = try! JSONEncoder().encode(DownloadRecord(original))
    precondition(!String(data: encoded, encoding: .utf8)!.contains("secret"))
    let restored = try! JSONDecoder().decode(DownloadRecord.self, from: encoded).restore()
    precondition(restored.id == original.id && restored.state == .paused && restored.maxHeight == 720)
    precondition(restored.speedLimit == 1234 && restored.audioOnly && restored.mediaFormat == "mp3")
    precondition(restored.subtitles && restored.playlistItems == "2" && restored.connectionCount == 4)
    precondition(restored.expectedSHA256 == original.expectedSHA256)
    print("PASS: history/options round-trip and cookie exclusion")
    precondition(DownloadInput.url("file:///etc/passwd") == nil)
    precondition(DownloadInput.url("javascript://alert") == nil)
    precondition(DownloadInput.url("example.com/file") == "https://example.com/file")
    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let hashFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! Data("abc".utf8).write(to: hashFile)
    let hash = try! await Integrity.sha256(hashFile)
    precondition(hash == expected)
    try! FileManager.default.removeItem(at: hashFile)
    precondition(DownloadInput.checksum(expected.uppercased()) == expected)
    print("PASS: URL validation and SHA-256 known vector")
    let manager = DownloadManager()
    let scheduled = manager.add(url: "http://127.0.0.1:17211/tiny", startNow: false)!
    scheduled.scheduledAt = Date().addingTimeInterval(3600); scheduled.state = .queued
    manager.tick()
    try! await Task.sleep(nanoseconds: 50_000_000)
    precondition(scheduled.state == .queued)
    scheduled.scheduledAt = Date().addingTimeInterval(-1)
    manager.tick()
    for _ in 0..<100 where scheduled.state != .completed { try! await Task.sleep(nanoseconds: 50_000_000) }
    precondition(scheduled.state == .completed)
    try! FileManager.default.removeItem(at: scheduled.fileURL)
    let retrying = manager.add(url: "http://127.0.0.1:17211/retry")!
    for _ in 0..<160 where retrying.state != .completed {
        try! await Task.sleep(nanoseconds: 50_000_000)
        manager.tick()
    }
    precondition(retrying.state == .completed && retrying.retryCount == 1, retrying.error ?? "retry failed")
    try! FileManager.default.removeItem(at: retrying.fileURL)
    print("PASS: transient HTTP failure automatically recovers")
    let batch = manager.addBatch("https://example.test/a\nfile:///etc/passwd\nhttps://example.test/b", startNow: false)
    precondition(batch.added == 2 && batch.rejected == 1)
    let last = manager.items.last!; manager.prioritize(last)
    precondition(manager.items.first?.id == last.id)
    print("PASS: scheduler, batch validation, queue priority")
    UserDefaults(suiteName: "MacDM.Regression")!.removePersistentDomain(forName: "MacDM.Regression")
    exit(0)
}
RunLoop.main.run()
