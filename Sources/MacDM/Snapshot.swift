import AppKit

/// Debug/CI helpers, off unless requested on the command line:
///   MacDM --demo                       inject cosmetic demo downloads
///   MacDM --demo --snapshot out.png    render the window to a PNG, then quit
/// Used to produce README screenshots without screen-recording permission
/// (an application may always capture its own windows).
@MainActor
enum Snapshotter {

    static func runIfNeeded(window: NSWindow, manager: DownloadManager) {
        let args = CommandLine.arguments
        if args.contains("--demo") {
            DemoContent.inject(into: manager)
        }
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let path = args[i + 1]
        // let the window, effect views and table settle before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            capture(window: window, to: path)
            NSApp.terminate(nil)
        }
    }

    private static func capture(window: NSWindow, to path: String) {
        // C shim (capture.c): the legacy CGWindowListCreateImage is unavailable
        // in the macOS 27 SDK but still works for capturing your own window
        guard let img = macdm_capture_window(UInt32(window.windowNumber)) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("MacDM: snapshot written to \(path)")
    }
}

/// See capture.c — own-window snapshot without Screen Recording permission.
@_silgen_name("macdm_capture_window")
private func macdm_capture_window(_ wid: UInt32) -> CGImage?

/// Cosmetic rows for screenshots — never touches the network.
@MainActor
private enum DemoContent {

    static func inject(into manager: DownloadManager) {
        func item(_ url: String, state: DownloadState, total: Int64, received: Int64,
                  speed: Double = 0, title: String? = nil, format: String? = nil,
                  quality: String? = nil, file: String? = nil, maxHeight: Int? = nil,
                  category: DownloadCategory? = nil) -> DownloadItem {
            let it = DownloadItem(url: url, maxHeight: maxHeight)
            if let category { it.category = category }
            it.state = state
            it.isVideoTask = title != nil
            it.videoTitle = title
            it.videoFormat = format
            it.videoQuality = quality
            it.resolvedFilename = file
            it.totalBytes = total
            it.recordProgress(received: received, total: total)
            it.speedBPS = speed
            return it
        }

        // appended oldest-first; the manager shows newest at the top
        let items = [
            item("https://mirror.example.org/sintel-4k.mkv", state: .completed,
                 total: 4_396_595_200, received: 4_396_595_200,
                 title: "Sintel", format: "mp4", quality: "4K"),
            item("https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-arm64.iso",
                 state: .completed, total: 2_604_177_408, received: 2_604_177_408,
                 category: .programs),
            item("https://music.example.org/mixes/midnight-lofi-vol3",
                 state: .downloading, total: 84_233_216, received: 57_294_848, speed: 11_400_000,
                 title: "Midnight Lo-Fi Mix Vol. 3", format: "mp3", quality: "Best",
                 category: .music),
            item("https://cdn.example.org/packs/project-assets-2026.zip",
                 state: .paused, total: 1_288_490_188, received: 594_627_072,
                 file: "project-assets-2026.zip"),
            item("https://video.example.org/watch/big-buck-bunny", state: .downloading,
                 total: 894_784_853, received: 773_209_600, speed: 12_900_000,
                 title: "Big Buck Bunny", format: "mp4", quality: "1080p", maxHeight: 1080,
                 category: .videos),
        ]
        manager.items.append(contentsOf: items)
        manager.onChange?()
    }
}
