import Foundation

/// Wraps yt-dlp to detect whether a URL points to a downloadable video/music
/// page (YouTube, Vimeo, Twitter, 1000+ sites) and to fetch media with it.
enum VideoDetector {
    static let binaryPath = "/Library/Frameworks/Python.framework/Versions/3.13/bin/yt-dlp"

    static let knownHosts: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "twitter.com", "x.com",
        "tiktok.com", "instagram.com", "facebook.com", "twitch.tv",
        "soundcloud.com", "dailymotion.com", "reddit.com", "bandcamp.com",
        "rumble.com", "odysee.com", "bitchute.com", "bilibili.com"
    ]

    static func isSupportedSite(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return knownHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// HLS/DASH playlist links (m3u8/m3u/mpd). A plain HTTP fetch would only
    /// save the tiny playlist text — these must always go through yt-dlp,
    /// which resolves the stream and hands back a real media file.
    static func isStreamURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }

    struct Format: Codable {
        let formatId: String?
        let height: Int?
        let ext: String?
        let vcodec: String?
        let acodec: String?
        let fps: Double?
        let filesize: Int64?
        enum CodingKeys: String, CodingKey {
            case formatId = "format_id", height, ext, vcodec, acodec, fps, filesize
        }
    }

    struct Info: Codable {
        let title: String?
        let extractor: String?
        let duration: Double?
        let formats: [Format]?
    }

    /// Distinct video qualities (resolutions) available for a URL, best first.
    static func availableHeights(_ info: Info) -> [Int] {
        let hs = Set((info.formats ?? []).compactMap { $0.height }.filter { $0 > 0 })
        return hs.sorted(by: >)
    }

    /// Quick probe: does yt-dlp recognize this URL?
    static func fetchInfo(url: String, cookies: String? = nil, userAgent: String? = nil) async throws -> Info {
        var args = ["-J", "--no-playlist"]
        args += await impersonateArgs()
        args += headerArgs(cookies: cookies, userAgent: userAgent)
        args += [url]
        let out = try await run(arguments: args)
        _ = args.removeAll()
        return try JSONDecoder().decode(Info.self, from: Data(out.utf8))
    }

    /// ffmpeg locations probed to decide whether stream merging is possible.
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Download media with yt-dlp into the item's category folder.
    /// Reports progress by parsing yt-dlp's progress lines.
    /// Returns the final downloaded file path (via --print after_move:filepath).
    static func download(url: String, to folder: URL, maxHeight: Int? = nil,
                         cookies: String? = nil, userAgent: String? = nil,
                         onProgress: @escaping (Double, Int64, Int64) -> Void) async throws -> String? {
        // A capped quality is part of the file's identity — bake the cap into
        // the name so 1080p and 360p copies of the same video coexist instead
        // of the second run hitting "has already been downloaded".
        let template = maxHeight.map { folder.path + "/%(title)s (\($0)p).%(ext)s" }
            ?? folder.path + "/%(title)s.%(ext)s"
        // Single-file policy: exactly ONE file must land on disk.
        // With ffmpeg: merge best video+audio into one file.
        // Without ffmpeg: combined stream if one exists, else the single best
        // video-only stream (bv*) — never the video+audio pair that used to
        // produce both an .mp4 and a .webm.
        let selector: String
        if let h = maxHeight {
            selector = ffmpegPath != nil
                ? "bv*[height<=\(h)]+ba/b[height<=\(h)]/b/bv*[height<=\(h)]/bv*"
                : "b[height<=\(h)]/b/bv*[height<=\(h)]/bv*"
        } else {
            selector = ffmpegPath != nil ? "bv*+ba/b/bv*" : "b/bv*"
        }
        var args = [
            "-f", selector,
            "--newline", "--no-playlist",
            "--print", "after_move:filepath",
            "-o", template, url
        ]
        args += headerArgs(cookies: cookies, userAgent: userAgent)
        args += await impersonateArgs()
        if let ff = ffmpegPath {
            // GUI apps don't inherit the shell PATH, so point yt-dlp at ffmpeg
            // explicitly. Every download then ends as .mp4: merged video+audio
            // and single-format files (HLS .ts, .webm, .mkv) are REMUXED —
            // stream copy, no re-encode — so the resolution of what was
            // downloaded is preserved exactly (240p stays 240p, never 1080p).
            args += ["--ffmpeg-location", ff,
                     "--merge-output-format", "mp4",
                     "--remux-video", "mp4"]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        final class Box { var finalPath: String? }
        let box = Box()
        let reader = DispatchQueue(label: "macdm.ytdlp.reader")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            reader.async {
                for l in line.split(separator: "\n") {
                    let s = String(l).trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("[") {
                        parseProgress(s, onProgress)
                    } else if !s.isEmpty, s.contains("/") {
                        // bare path line from --print
                        box.finalPath = s
                    }
                }
            }
        }

        try proc.run()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: URLError(.cannotDecodeContentData, userInfo: [
                        NSLocalizedDescriptionKey: "yt-dlp exited with status \(p.terminationStatus)"
                    ]))
                }
            }
        }
        return box.finalPath
    }

    private static func parseProgress(_ line: String, _ onProgress: @escaping (Double, Int64, Int64) -> Void) {
        // [download]  42.3% of ~10.00MiB at 1.20MiB/s ETA 00:05
        guard line.hasPrefix("[download]") else { return }
        let parts = line.dropFirst("[download]".count).split(separator: " ")
        guard let pctStr = parts.first(where: { $0.hasSuffix("%") }) else { return }
        let pct = Double(pctStr.dropLast()) ?? 0
        let total = parts.first(where: { $0.hasSuffix("MiB") || $0.hasSuffix("GiB") || $0.hasSuffix("KiB") }).map(parseSize) ?? 0
        onProgress(pct / 100.0, Int64(pct / 100.0 * Double(total)), total)
    }

    private static func parseSize(_ s: Substring) -> Int64 {
        let num = Double(s.dropLast(3)) ?? 0
        switch s.suffix(3) {
        case "GiB": return Int64(num * 1_073_741_824)
        case "MiB": return Int64(num * 1_048_576)
        default: return Int64(num * 1024)
        }
    }

    /// Cookie/User-Agent helpers for authenticated downloads.
    static func headerArgs(cookies: String?, userAgent: String?) -> [String] {
        var args: [String] = []
        if let c = cookies, !c.isEmpty { args += ["--add-headers", "Cookie:\(c)"] }
        if let ua = userAgent, !ua.isEmpty { args += ["--user-agent", ua] }
        return args
    }

    /// Cached capability probe: yt-dlp browser impersonation (curl_cffi).
    /// Sites like Rumble 403 plain HTTP clients; impersonating Chrome gets
    /// past that. Requires no extra args when unavailable.
    private static var impersonateProbed = false
    private static var impersonateTarget: String?

    private static func impersonateArgs() async -> [String] {
        if !impersonateProbed {
            impersonateProbed = true
            if let out = try? await run(arguments: ["--list-impersonate-targets"]) {
                for line in out.split(separator: "\n") {
                    let l = line.lowercased()
                    if l.hasPrefix("chrome") && !l.contains("unavailable") {
                        impersonateTarget = "chrome"
                        break
                    }
                }
            }
        }
        return impersonateTarget.map { ["--impersonate", $0] } ?? []
    }

    /// Quick check whether a URL is directly downloadable media (no yt-dlp needed):
    /// content-type video/* or audio/*, or a media file extension. Stream
    /// playlists (m3u8/mpd) are never "direct" — some servers report them as
    /// audio/x-mpegurl, but fetching one only saves the playlist text.
    static func isDirectMedia(_ urlString: String) async -> Bool {
        if isStreamURL(urlString) { return false }
        guard let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension.lowercased()
        let mediaExts: Set<String> = ["mp4","m4v","mov","webm","mkv","avi","flv","mp3","m4a","aac","flac","wav","ogg","opus","ts"]
        if mediaExts.contains(ext) { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if mime.contains("mpegurl") || mime.contains("dash+xml") { return false }
        return mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/octet-stream" && http.expectedContentLength > 1_000_000
    }

    private static func run(arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "yt-dlp failed"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
