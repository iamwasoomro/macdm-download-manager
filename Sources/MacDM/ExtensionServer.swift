import Foundation
import CryptoKit

final class ExtensionServer {
    static let shared = ExtensionServer()
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var clients = 0
    var onURL: ((IncomingDownload) -> Void)?
    func start(port: Int = 7210) {
        guard listener < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 16) == 0 else { close(fd); NSLog("MacDM: cannot bind extension port"); return }
        listener = fd
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self.lock.lock()
                let allowed = self.clients < 16
                if allowed { self.clients += 1 }
                self.lock.unlock()
                if !allowed { close(client); continue }
                Thread.detachNewThread {
                    self.handle(clientFD: client)
                    self.lock.lock(); self.clients -= 1; self.lock.unlock()
                }
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(clientFD, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            if data.count > 65536 { respond(clientFD, status: "431 Request Header Fields Too Large"); return }
        }
        guard let end = headerEnd, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return }
        let lines = head.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3 else { respond(clientFD, status: "400 Bad Request"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { respond(clientFD, status: "400 Bad Request"); return }
            let key = line[..<split].lowercased()
            guard headers[key] == nil else { respond(clientFD, status: "400 Bad Request"); return }
            headers[key] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
        }
        let origin = headers["origin"]
        guard origin == nil || (origin?.range(of: "^chrome-extension://[a-p]{32}$", options: .regularExpression) != nil) else {
            respond(clientFD, status: "403 Forbidden"); return
        }
        let method = String(request[0]), path = String(request[1])
        guard ["/add", "/info"].contains(path) else { respond(clientFD, status: "404 Not Found", origin: origin); return }
        if method == "OPTIONS" { respond(clientFD, status: "204 No Content", origin: origin); return }
        guard method == "POST" else { respond(clientFD, status: "405 Method Not Allowed", origin: origin); return }
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? ""), (1...262144).contains(length) else {
            respond(clientFD, status: "400 Bad Request", origin: origin); return
        }
        while data.count < end.upperBound + length {
            let count = recv(clientFD, &buffer, min(buffer.count, end.upperBound + length - data.count), 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
        let body = data.subdata(in: end.upperBound..<(end.upperBound + length))
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = object["url"] as? String, raw.count <= 16384, let url = DownloadInput.url(raw) else {
            respond(clientFD, status: "400 Bad Request", origin: origin); return
        }
        for key in ["cookies", "userAgent", "referrer", "filename"] {
            if let value = object[key] as? String, value.rangeOfCharacter(from: .newlines) != nil {
                respond(clientFD, status: "400 Bad Request", origin: origin); return
            }
        }
        if let height = object["maxHeight"] as? Int, !(144...8640).contains(height) { respond(clientFD, status: "400 Bad Request", origin: origin); return }
        if path == "/info" {
            let payload = Self.lookupInfo(url: url, cookies: object["cookies"] as? String, userAgent: object["userAgent"] as? String)
            respond(clientFD, status: payload == nil ? "502 Bad Gateway" : "200 OK", body: payload ?? "{\"error\":\"lookup failed\"}", origin: origin)
        } else {
            let incoming = IncomingDownload(url: url, maxHeight: object["maxHeight"] as? Int,
                referrer: object["referrer"] as? String, cookies: object["cookies"] as? String,
                userAgent: object["userAgent"] as? String, filename: object["filename"] as? String,
                mimeType: object["mime"] as? String, forceVideo: object["forceVideo"] as? Bool ?? false)
            DispatchQueue.main.async { self.onURL?(incoming) }
            respond(clientFD, status: "200 OK", body: "{\"ok\":true}", origin: origin)
        }
    }
    private func respond(_ fd: Int32, status: String, body: String = "{}", origin: String? = nil) {
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nConnection: close\r\n"
        if let origin {
            headers += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n"
        }
        let responseBody = status.hasPrefix("204") ? "" : body
        let bytes = Data((headers + "Content-Length: \(responseBody.utf8.count)\r\n\r\n" + responseBody).utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if sent <= 0 { break }; offset += sent
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var infoCache: [String: (date: Date, payload: String?)] = [:]
    private static let cacheTTL: TimeInterval = 300

    /// Blocking yt-dlp metadata lookup (runs on the connection's own thread).
    /// Retries transient failures and serves a 5-minute cache so the popup
    /// doesn't degrade to "best available" on a flaky fetch.
    private static func lookupInfo(url: String, cookies: String? = nil, userAgent: String? = nil) -> String? {
        let key = SHA256.hash(data: Data((url + "\n" + (cookies ?? "") + "\n" + (userAgent ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        cacheLock.lock()
        if let hit = infoCache[key], Date().timeIntervalSince(hit.date) < cacheTTL {
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
        if infoCache.count > 100 { infoCache.removeAll() }
        if result != nil { infoCache[key] = (Date(), result) }
        cacheLock.unlock()
        return result
    }

    private static func attemptInfo(url: String, cookies: String?, userAgent: String?) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        let lookup = Task {
            defer { sem.signal() }
            guard let info = try? await VideoDetector.fetchInfo(url: url, cookies: cookies, userAgent: userAgent) else { return }
            let heights = VideoDetector.availableHeights(info)
            let obj: [String: Any] = [
                "title": info.title ?? "",
                "heights": heights,
            ]
            result = String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8)
        }
        // 20s: cookie-less fallback retry inside fetchInfo adds a second run
        if sem.wait(timeout: .now() + 20) == .timedOut {
            lookup.cancel()
            return nil
        }
        return result
    }

    func stop() {
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
    }
}
