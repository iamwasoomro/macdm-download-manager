import Foundation
Task {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACDM_VIDEO_DIR"]!)
    let result = try! await VideoDetector.download(url: "https://example.test/video", to: folder,
                                                  maxHeight: 720, audioOnly: true, container: "mp3",
                                                  subtitles: true, playlistItems: "2", speedLimit: 2048, identity: "fixture-identity") { _, _, _ in }
    precondition(result == folder.appendingPathComponent("fixture.mp4").path)
    let playlist = try! await VideoDetector.playlist(url: "https://example.test/list")
    precondition(playlist.count == 2)
    let task = Task { try await VideoDetector.download(url: "https://example.test/slow", to: folder, container: "source") { _, _, _ in } }
    try! await Task.sleep(nanoseconds: 100_000_000)
    let started = Date()
    task.cancel()
    do { _ = try await task.value; fatalError("cancelled process succeeded") }
    catch { precondition(Date().timeIntervalSince(started) < 3) }
    print("PASS: video output framing, playlist lookup, process cancellation")
    exit(0)
}
RunLoop.main.run()
