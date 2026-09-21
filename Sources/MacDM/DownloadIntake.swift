import AppKit

/// Confirmation shown when a download arrives (from the Chrome extension):
/// estimated file size + destination, with Start Download / Download Later /
/// Cancel. "Download Later" adds the item in a paused state for manual resume.
@MainActor
enum DownloadIntake {

    struct Estimate {
        var name: String
        var size: Int64      // -1 = unknown
        var path: String
    }

    /// Burst guard: if more than `burstLimit` downloads arrive within
    /// `burstWindow`, the rest are dropped — a client replaying its history
    /// must not bury the user under dialogs.
    private static var arrivals: [Date] = []
    private static let burstLimit = 5
    private static let burstWindow: TimeInterval = 20

    private static func admitsArrival() -> Bool {
        arrivals = arrivals.filter { Date().timeIntervalSince($0) < burstWindow }
        guard arrivals.count < burstLimit else { return false }
        arrivals.append(Date())
        return true
    }

    static func confirmAndAdd(manager: DownloadManager, incoming: IncomingDownload,
                              window: NSWindow?) async {
        var url = incoming.url
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        guard admitsArrival() else {
            NSLog("MacDM: burst guard dropped incoming download \(url)")
            return
        }
        let maxHeight = incoming.maxHeight
        let referrer = incoming.referrer

        // Browser round-trip: if this came from the same page as a paused or
        // failed download, treat it as that download's replacement link.
        if let referrer = referrer,
           let target = manager.items.first(where: {
               ($0.state == .paused || $0.state == .failed)
                   && $0.referrerURL == referrer && $0.url != url
           }) {
            await refreshFromBrowser(manager: manager, target: target,
                                     url: url, maxHeight: maxHeight, window: window)
            return
        }

        let est = await estimate(url: url, maxHeight: maxHeight,
                                 cookies: incoming.cookies, userAgent: incoming.userAgent)

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.messageText = "Download “\(trim(est.name))”?"

        let sizeText = est.size > 0
            ? ByteCountFormatter.string(fromByteCount: est.size, countStyle: .file)
            : "Unknown"
        alert.informativeText = "Estimated size: \(sizeText)\nSaved to: \(abbreviate(est.path))"
        alert.addButton(withTitle: "Start Download")
        alert.addButton(withTitle: "Download Later")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            manager.add(url: url, maxHeight: maxHeight, referrer: referrer,
                        cookies: incoming.cookies, userAgent: incoming.userAgent,
                        startNow: true)?.estimatedSize = est.size
        case .alertSecondButtonReturn:
            manager.add(url: url, maxHeight: maxHeight, referrer: referrer,
                        cookies: incoming.cookies, userAgent: incoming.userAgent,
                        startNow: false)?.estimatedSize = est.size
        default:
            break
        }
    }

    /// A link sent back from the browser for a paused/failed download:
    /// checks whether it points at the same file (size comparison) before
    /// swapping the URL and restarting.
    static func refreshFromBrowser(manager: DownloadManager, target: DownloadItem,
                                   url: String, maxHeight: Int?, window: NSWindow?) async {
        WaitPanel.show(on: window, text: "Please wait — checking link from browser…")
        let est = await estimate(url: url, maxHeight: maxHeight)
        WaitPanel.hide()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        let previous = target.totalBytes > 0 ? target.totalBytes : target.estimatedSize
        let sameFile = est.size > 0 && previous > 0 && est.size == previous

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        let sizeText = est.size > 0
            ? ByteCountFormatter.string(fromByteCount: est.size, countStyle: .file)
            : "Unknown"
        if sameFile {
            alert.messageText = "Same file detected"
            alert.informativeText = "The link points to the same file (size matches: \(sizeText)).\nUpdate “\(trim(target.filename))” with this link?"
        } else if previous > 0 {
            alert.messageText = "Different file detected"
            alert.informativeText = "New file is \(sizeText); the previous download was \(ByteCountFormatter.string(fromByteCount: previous, countStyle: .file)).\nUpdate “\(trim(target.filename))” anyway?"
        } else {
            alert.messageText = "New link received"
            alert.informativeText = "Previous size unknown; new file is estimated at \(sizeText).\nUpdate “\(trim(target.filename))” with this link?"
        }
        alert.addButton(withTitle: "Update Download")
        alert.addButton(withTitle: "Add as New Download")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            manager.updateURL(target, newURL: url, maxHeight: maxHeight)
        case .alertSecondButtonReturn:
            manager.add(url: url, maxHeight: maxHeight, cookies: target.cookies,
                        userAgent: target.userAgent, startNow: true)?.estimatedSize = est.size
        default:
            break
        }
    }

    /// Confirms a manually entered replacement URL for the refresh dialog.
    static func confirmManualRefresh(manager: DownloadManager, target: DownloadItem,
                                     newURL: String, window: NSWindow?) async {
        WaitPanel.show(on: window, text: "Please wait — checking new link…")
        let est = await estimate(url: newURL, maxHeight: target.maxHeight)
        WaitPanel.hide()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        let previous = target.totalBytes > 0 ? target.totalBytes : target.estimatedSize
        let sameFile = est.size > 0 && previous > 0 && est.size == previous
        let sizeText = est.size > 0
            ? ByteCountFormatter.string(fromByteCount: est.size, countStyle: .file)
            : "Unknown"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        alert.messageText = sameFile ? "Same file detected"
            : (previous > 0 ? "Different file detected" : "New link")
        alert.informativeText = sameFile
            ? "The new URL points to the same file (size matches: \(sizeText)).\nRestart “\(trim(target.filename))” with it?"
            : "New file is \(sizeText); previous was \(previous > 0 ? ByteCountFormatter.string(fromByteCount: previous, countStyle: .file) : "unknown").\nRestart “\(trim(target.filename))” with it?"
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            manager.updateURL(target, newURL: newURL, maxHeight: target.maxHeight)
        }
    }

    // MARK: - Estimation

    static func estimate(url urlString: String, maxHeight: Int?,
                         cookies: String? = nil, userAgent: String? = nil) async -> Estimate {
        // Video sites AND raw HLS/DASH playlists: metadata comes from yt-dlp
        // (a HEAD on a playlist would measure the playlist text, not the video)
        if VideoDetector.isSupportedSite(urlString) || VideoDetector.isStreamURL(urlString),
           let info = try? await VideoDetector.fetchInfo(url: urlString, cookies: cookies, userAgent: userAgent) {
            let title = info.title ?? URL(string: urlString)?.lastPathComponent ?? "video"
            let cat: DownloadCategory = (info.duration ?? 0) < 600
                && (info.extractor ?? "").lowercased().contains("soundcloud") ? .music : .videos
            return Estimate(name: title,
                            size: estimateSize(info, maxHeight: maxHeight),
                            path: DownloadItem.destinationFolder(for: cat).path)
        }

        // Plain URL: HEAD probe for size / filename / type
        if let url = URL(string: urlString) {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            if let c = cookies, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
            if let ua = userAgent, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? -1
                let name = http.suggestedFilename ?? url.lastPathComponent
                let cat = DownloadCategory.detect(url: urlString,
                    mimeType: http.value(forHTTPHeaderField: "Content-Type"))
                return Estimate(name: name, size: length,
                                path: DownloadItem.destinationFolder(for: cat).path)
            }
        }

        let cat = DownloadCategory.detect(url: urlString)
        let name = URL(string: urlString)?.lastPathComponent ?? urlString
        return Estimate(name: name, size: -1,
                        path: DownloadItem.destinationFolder(for: cat).path)
    }

    /// yt-dlp size estimate: best video at/below the chosen height plus audio.
    static func estimateSize(_ info: VideoDetector.Info, maxHeight: Int?) -> Int64 {
        let formats = info.formats ?? []
        let videos = formats.filter { ($0.vcodec ?? "none") != "none" && ($0.height ?? 0) > 0 }
        let audios = formats.filter { ($0.acodec ?? "none") != "none" }
        var candidates = videos
        if let h = maxHeight {
            let capped = videos.filter { ($0.height ?? 0) <= h }
            if !capped.isEmpty { candidates = capped }
        }
        // yt-dlp lists formats worst→best; take the best one with a known size
        let videoBytes = candidates.last(where: { $0.filesize != nil })?.filesize
        let audioBytes = audios.first(where: { $0.filesize != nil })?.filesize
        if let v = videoBytes {
            return v + (audioBytes ?? 0)
        }
        return -1
    }

    private static func trim(_ s: String) -> String {
        s.count > 48 ? String(s.prefix(45)) + "…" : s
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
