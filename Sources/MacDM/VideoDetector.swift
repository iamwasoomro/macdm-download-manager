import Foundation

/// Wraps yt-dlp to detect whether a URL points to a downloadable video/music
/// page (YouTube, Vimeo, Twitter, 1000+ sites) and to fetch media with it.
enum VideoDetector {
    static var binaryPath: String {
        let paths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/Library/Frameworks/Python.framework/Versions/3.13/bin/yt-dlp"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? paths[0]
    }

    static let knownHosts: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "twitter.com", "x.com",
        "tiktok.com", "instagram.com", "facebook.com", "twitch.tv",
        "soundcloud.com", "dailymotion.com", "reddit.com", "bandcamp.com",
        "rumble.com", "odysee.com", "bitchute.com", "bilibili.com",
        "kick.com"
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
    /// Forwarded browser cookies are tried first (login walls need them) —
    /// but forcing a raw Cookie header breaks CSRF-sensitive APIs (X/Twitter:
    /// "Could not authenticate you"), so a failure retries without cookies.
    static func fetchInfo(url: String, cookies: String? = nil, userAgent: String? = nil) async throws -> Info {
        func attempt(withCookies: Bool) async throws -> Info {
            var args = ["-J", "--no-playlist"]
            args += await impersonateArgs()
            args += headerArgs(cookies: withCookies ? cookies : nil, userAgent: userAgent)
            args += [url]
            let out = try await run(arguments: args)
            return try JSONDecoder().decode(Info.self, from: Data(out.utf8))
        }
        do {
            return try await attempt(withCookies: true)
        } catch {
            try Task.checkCancellation()
            guard cookies?.isEmpty == false else { throw error }
            return try await attempt(withCookies: false)
        }
    }

    /// ffmpeg locations probed to decide whether stream merging is possible.
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Download media with yt-dlp into the item's category folder.
    /// Reports progress by parsing yt-dlp's progress lines.
    /// Returns the final downloaded file path (via --print after_move:filepath).
    /// Forwarded cookies are tried first, then a clean retry: forcing a raw
    /// Cookie header breaks CSRF-sensitive APIs (X/Twitter) at extraction time.
    static func download(url: String, to folder: URL, maxHeight: Int? = nil,
                         cookies: String? = nil, userAgent: String? = nil,
                         audioOnly: Bool = false, container: String = "mp4",
                         subtitles: Bool = false, playlistItems: String? = nil,
                         speedLimit: Int64 = 0, identity: String = UUID().uuidString,
                         onQuality: ((Int) -> Void)? = nil,
                         onProgress: @escaping (Double, Int64, Int64) -> Void) async throws -> String? {
        func attempt(withCookies: Bool) async throws -> String? {
        // A capped quality is part of the file's identity — bake the cap into
        // the name so 1080p and 360p copies of the same video coexist instead
        // of the second run hitting "has already been downloaded".
        let suffix = String(identity.prefix(8)) + (audioOnly ? "-audio" : "")
        let template = folder.path + "/%(title).180B [%(id)s] (" + suffix + ").%(ext)s"
        if (audioOnly && ["mp3", "m4a"].contains(container) || subtitles || container != "source"), ffmpegPath == nil {
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "Install ffmpeg to use this format or subtitles; choose Source to download without conversion."])
        }
        // Single-file policy: exactly ONE file must land on disk.
        // With ffmpeg: merge best video+audio into one file.
        // Without ffmpeg: combined stream if one exists, else the single best
        // video-only stream (bv*) — never the video+audio pair that used to
        // produce both an .mp4 and a .webm.
        var selector: String
        if let h = maxHeight {
            selector = ffmpegPath != nil
                ? "bv*[height<=\(h)]+ba/b[height<=\(h)]"
                : "b[height<=\(h)]/bv*[height<=\(h)]"
        } else {
            selector = ffmpegPath != nil ? "bv*+ba/b/bv*" : "b/bv*"
        }
        if audioOnly { selector = ffmpegPath == nil ? "bestaudio" : "bestaudio/best" }
        var args = [
            "-f", selector,
            "--newline", "--progress", "--no-simulate", "--no-playlist", "--continue", "--no-overwrites",
            "--socket-timeout", "30", "--retries", "3",
            "--print", "before_dl:MACDM_QUALITY:%(height)s",
            "--print", "after_move:filepath",
            "-o", template, url
        ]
        if let playlistItems {
            args.removeAll { $0 == "--no-playlist" }
            args += ["--yes-playlist", "--playlist-items", playlistItems]
        }
        if speedLimit > 0 { args += ["--limit-rate", String(speedLimit)] }
        if subtitles { args += ["--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en", "--embed-subs"] }
        if audioOnly, ffmpegPath != nil {
            args += ["-x", "--audio-format", ["mp3", "m4a"].contains(container) ? container : "best"]
        }
        args += headerArgs(cookies: withCookies ? cookies : nil, userAgent: userAgent)
        args += await impersonateArgs()
        if let ff = ffmpegPath {
            args += ["--ffmpeg-location", ff]
            if !audioOnly && container != "source" {
                args += ["--merge-output-format", container, "--remux-video", container]
            }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        let pipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = errPipe
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try proc.run()
            if Task.isCancelled, proc.isRunning { proc.terminate() }
            let output = Task.detached { () throws -> String? in
                var pending = Data(), finalPath: String?
                func consume(_ data: Data) {
                    let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("MACDM_QUALITY:"), let h = Int(line.dropFirst("MACDM_QUALITY:".count)) { onQuality?(h) }
                    else if line.hasPrefix("[") { parseProgress(line, onProgress) }
                    else if line.hasPrefix("/") { finalPath = line }
                }
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        consume(Data(pending[..<newline])); pending.removeSubrange(...newline)
                    }
                }
                if !pending.isEmpty { consume(pending) }
                return finalPath
            }
            let errors = Task.detached { () throws -> Data in
                var tail = Data()
                while let chunk = try errPipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    tail.append(chunk)
                    if tail.count > 65536 { tail = tail.suffix(65536) }
                }
                return tail
            }
            let path = try await output.value
            let stderr = try await errors.value
            await Task.detached { proc.waitUntilExit() }.value
            try Task.checkCancellation()
            guard proc.terminationStatus == 0 else {
                let message = String(decoding: stderr, as: UTF8.self)
                throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "yt-dlp exited with status \(proc.terminationStatus)" : String(message.suffix(600))])
            }
            return path
        }, onCancel: { if proc.isRunning { proc.terminate() } })
        }
        do {
            return try await attempt(withCookies: true)
        } catch {
            try Task.checkCancellation()
            guard cookies?.isEmpty == false else { throw error }
            return try await attempt(withCookies: false)
        }
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

    struct PlaylistEntry: Decodable {
        let title: String?
        let url: String?
        let webpage_url: String?
    }
    static func playlist(url: String) async throws -> [PlaylistEntry] {
        struct List: Decodable { let entries: [PlaylistEntry?]? }
        let output = try await run(arguments: ["--flat-playlist", "--dump-single-json", "--playlist-end", "500", "--socket-timeout", "30", url])
        return try JSONDecoder().decode(List.self, from: Data(output.utf8)).entries?.compactMap { $0 } ?? []
    }

    private static func run(arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--socket-timeout", "30"] + arguments
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try proc.run()
            if Task.isCancelled, proc.isRunning { proc.terminate() }
            async let stdout: Data = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr: Data = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (output, errors) = await (stdout, stderr)
            await Task.detached { proc.waitUntilExit() }.value
            try Task.checkCancellation()
            guard proc.terminationStatus == 0 else {
                let message = String(data: errors, encoding: .utf8) ?? "yt-dlp failed"
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: String(message.suffix(600))])
            }
            return String(data: output, encoding: .utf8) ?? ""
        }, onCancel: { if proc.isRunning { proc.terminate() } })
    }
}
