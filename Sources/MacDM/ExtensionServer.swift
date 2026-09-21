import Foundation

/// Minimal local HTTP server (port 7210) so the Chrome extension can POST
/// URLs into the app:  POST /add  {"url": "..."}
/// CORS-enabled so the extension's fetch succeeds.
final class ExtensionServer {
    static let shared = ExtensionServer()
    private var server: SocketPort?
    private var running = false
    var onURL: ((IncomingDownload) -> Void)?

    func start(port: Int = 7210) {
        guard !running else { return }
        guard let socket = try? SocketPort(tcpPort: UInt16(port)) else {
            NSLog("MacDM: cannot bind port \(port)")
            return
        }
        running = true
        server = socket
        receiveLoop(on: socket)
        NSLog("MacDM extension server listening on 127.0.0.1:\(port)")
    }

    private func receiveLoop(on socket: SocketPort) {
        // We use a raw accept loop via file descriptor through NSFileStream-free
        // approach: SocketPort messages are macOS-native; for HTTP we instead
        // poll the accepted connections through a background thread.
        Thread.detachNewThread {
            let fd = socket.socket
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            while self.running {
                var addr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(fd, &addr, &len)
                guard client >= 0 else { break }
                Thread.detachNewThread { self.handle(clientFD: client) }
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        // Read until end of headers + body per Content-Length (small requests)
        var request = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = recv(clientFD, &buffer, bufferSize, 0)
            guard n > 0 else { break }
            request.append(contentsOf: buffer[0..<n])
            if let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = headers
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count >= headerEnd.upperBound + contentLength { break }
            }
            if request.count > 1_048_576 { break }
        }

        let head = String(data: request.prefix(while: { $0 != 0x0D }), encoding: .utf8) ?? ""
        let body: Data
        if let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) {
            body = request[headerEnd.upperBound...]
        } else {
            body = Data()
        }

        var status = "200 OK"
        var responseBody = "{\"ok\":true}"
        if head.hasPrefix("OPTIONS") {
            // CORS preflight
            let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = response.withCString { ptr in send(clientFD, ptr, Darwin.strlen(ptr), 0) }
            return
        }
        if head.hasPrefix("POST") {
            // First line looks like "POST /info HTTP/1.1"
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path.hasPrefix("/info") {
                // Quality/title lookup for the extension popup: {"url": "..."} →
                // {"title": "...", "heights": [2160, 1080, ...]}
                if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let url = obj["url"] as? String {
                    let payload = Self.lookupInfo(url: url,
                                                  cookies: obj["cookies"] as? String,
                                                  userAgent: obj["userAgent"] as? String)
                    responseBody = payload ?? "{\"error\":\"lookup failed\"}"
                    if payload == nil { status = "502 Bad Gateway" }
                } else {
                    status = "400 Bad Request"
                    responseBody = "{\"error\":\"expected {\\\"url\\\": ...}\"}"
                }
            } else if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let url = obj["url"] as? String {
                let incoming = IncomingDownload(
                    url: url,
                    maxHeight: obj["maxHeight"] as? Int,
                    referrer: obj["referrer"] as? String,
                    cookies: obj["cookies"] as? String,
                    userAgent: obj["userAgent"] as? String
                )
                DispatchQueue.main.async { self.onURL?(incoming) }
                responseBody = "{\"ok\":true,\"url\":\"\(url)\"}"
            } else {
                status = "400 Bad Request"
                responseBody = "{\"error\":\"expected {\\\"url\\\": ...}\"}"
            }
        }

        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { ptr in send(clientFD, ptr, Darwin.strlen(ptr), 0) }
    }

    private static let cacheLock = NSLock()
    private static var infoCache: [String: (date: Date, payload: String?)] = [:]
    private static let cacheTTL: TimeInterval = 300

    /// Blocking yt-dlp metadata lookup (runs on the connection's own thread).
    /// Retries transient failures and serves a 5-minute cache so the popup
    /// doesn't degrade to "best available" on a flaky fetch.
    private static func lookupInfo(url: String, cookies: String? = nil, userAgent: String? = nil) -> String? {
        cacheLock.lock()
        if let hit = infoCache[url], Date().timeIntervalSince(hit.date) < cacheTTL {
            let payload = hit.payload
            cacheLock.unlock()
            return payload
        }
        cacheLock.unlock()

        var result: String?
        for _ in 0..<3 {
            result = attemptInfo(url: url, cookies: cookies, userAgent: userAgent)
            if result != nil { break }
            Thread.sleep(forTimeInterval: 1)
        }

        cacheLock.lock()
        infoCache[url] = (Date(), result)
        cacheLock.unlock()
        return result
    }

    private static func attemptInfo(url: String, cookies: String?, userAgent: String?) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        Task {
            defer { sem.signal() }
            guard let info = try? await VideoDetector.fetchInfo(url: url, cookies: cookies, userAgent: userAgent) else { return }
            let heights = VideoDetector.availableHeights(info)
            let obj: [String: Any] = [
                "title": info.title ?? "",
                "heights": heights,
            ]
            result = String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8)
        }
        if sem.wait(timeout: .now() + 12) == .timedOut {
            return nil
        }
        return result
    }

    func stop() {
        running = false
        server?.invalidate()
        server = nil
    }
}
