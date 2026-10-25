import Foundation

final class DownloadSettings {
    static let shared = DownloadSettings()
    private let defaults = UserDefaults.standard
    var concurrentDownloads: Int {
        get { max(1, min(12, defaults.object(forKey: "concurrency") as? Int ?? 3)) }
        set { defaults.set(max(1, min(12, newValue)), forKey: "concurrency") }
    }
    var connections: Int {
        get { max(1, min(16, defaults.object(forKey: "connections") as? Int ?? 6)) }
        set { defaults.set(max(1, min(16, newValue)), forKey: "connections") }
    }
    var retries: Int {
        get { max(0, min(10, defaults.object(forKey: "retries") as? Int ?? 3)) }
        set { defaults.set(max(0, min(10, newValue)), forKey: "retries") }
    }
    var speedLimit: Int64 {
        get { max(0, Int64(defaults.double(forKey: "speedLimit"))) }
        set { defaults.set(Double(max(0, newValue)), forKey: "speedLimit") }
    }
    var preventSleep: Bool {
        get { defaults.object(forKey: "preventSleep") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "preventSleep") }
    }
    var notifications: Bool {
        get { defaults.bool(forKey: "notifications") }
        set { defaults.set(newValue, forKey: "notifications") }
    }
    var folder: URL {
        get {
            if let path = defaults.string(forKey: "downloadFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("MacDM", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "downloadFolder") }
    }
    var queueStart: Date? {
        get { defaults.object(forKey: "queueStart") as? Date }
        set { defaults.set(newValue, forKey: "queueStart") }
    }
    var queueStop: Date? {
        get { defaults.object(forKey: "queueStop") as? Date }
        set { defaults.set(newValue, forKey: "queueStop") }
    }
}

/// One shared HTTP budget plus separate per-file budgets; all connections count.
actor BandwidthLimiter {
    static let shared = BandwidthLimiter()
    private var globalNext = Date.distantPast
    private var fileNext: [UUID: Date] = [:]
    func consume(_ bytes: Int, id: UUID, limit: Int64) async throws {
        let now = Date()
        var deadline = now
        let global = DownloadSettings.shared.speedLimit
        if global > 0 {
            globalNext = max(now, globalNext).addingTimeInterval(Double(bytes) / Double(global))
            deadline = max(deadline, globalNext)
        }
        if limit > 0 {
            let next = max(now, fileNext[id] ?? now).addingTimeInterval(Double(bytes) / Double(limit))
            fileNext[id] = next
            deadline = max(deadline, next)
        }
        let delay = deadline.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000)) }
    }
    func forget(_ id: UUID) { fileNext[id] = nil }
}

enum DownloadInput {
    static func url(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let normalHost = host.lowercased()
        let hostname = normalHost.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil
        let ipv6 = normalHost.range(of: "^\\[[0-9a-f:]+\\]$", options: .regularExpression) != nil
        guard host.count <= 253, hostname || ipv6 else { return nil }
        return url.absoluteString
    }
    static func checksum(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) } ? text : nil
    }
}
