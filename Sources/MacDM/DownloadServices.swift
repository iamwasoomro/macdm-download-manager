import AppKit
import CryptoKit
import UserNotifications
import IOKit.pwr_mgt

struct Integrity {
    static func sha256(_ url: URL) async throws -> String {
        let work = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

actor FilePublisher {
    static let shared = FilePublisher()
    func publish(_ temporary: URL, to original: URL) throws -> URL {
        var destination = original, suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let ext = original.pathExtension
            destination = original.deletingLastPathComponent().appendingPathComponent(
                "\(original.deletingPathExtension().lastPathComponent) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

@MainActor
final class DownloadServices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DownloadServices()
    private var assertion: IOPMAssertionID = 0
    func updateSleep(active: Bool) {
        if active && DownloadSettings.shared.preventSleep && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacDM downloads" as CFString, &assertion)
        } else if (!active || !DownloadSettings.shared.preventSleep) && assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }
    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func notify(_ item: DownloadItem) {
        guard DownloadSettings.shared.notifications, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        let content = UNMutableNotificationContent()
        content.title = item.state == .completed ? "Download complete" : "Download failed"
        content.body = item.state == .completed ? item.filename : "\(item.filename): \(item.error ?? "Unknown error")"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }
}
