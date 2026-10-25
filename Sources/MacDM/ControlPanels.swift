import AppKit

@MainActor
class FormPanel: NSObject {
    let panel: NSPanel
    let stack = NSStackView()
    init(title: String, width: CGFloat = 560, height: CGFloat = 500) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let content = NSView()
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])
        panel.contentView = content
    }
    func present(on window: NSWindow) { window.beginSheet(panel); panel.makeFirstResponder(stack) }
    @objc func close() { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
    func field(_ title: String, value: String = "", placeholder: String = "") -> NSTextField {
        let text = NSTextField(string: value); text.placeholderString = placeholder
        row(title, text); return text
    }
    func row(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label, control]); row.spacing = 10; row.alignment = .centerY
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func hint(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func buttons(_ title: String, action: Selector) {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close)); cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: title, target: self, action: action); apply.keyEquivalent = "\r"
        [cancel, apply].forEach { $0.bezelStyle = .rounded }
        stack.addArrangedSubview(NSStackView(views: [cancel, apply]))
    }
    func error(_ text: String) {
        let alert = NSAlert(); alert.messageText = text
        alert.beginSheetModal(for: panel)
    }
}

@MainActor
final class SettingsPanel: FormPanel {
    private let manager: DownloadManager
    private var folder: NSTextField!
    private var concurrency: NSTextField!
    private var connections: NSTextField!
    private var retries: NSTextField!
    private var limit: NSTextField!
    private let sleep = NSButton(checkboxWithTitle: "Prevent idle sleep while downloading", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "Notify on completion or failure", target: nil, action: nil)
    init(manager: DownloadManager) {
        self.manager = manager
        super.init(title: "Download Settings", height: 530)
        let settings = DownloadSettings.shared
        folder = field("Download folder", value: settings.folder.path)
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder)); stack.addArrangedSubview(choose)
        concurrency = field("Simultaneous files", value: String(settings.concurrentDownloads))
        connections = field("Connections per file", value: String(settings.connections))
        retries = field("Automatic retries", value: String(settings.retries))
        limit = field("Global limit (KB/s)", value: String(settings.speedLimit / 1024))
        sleep.state = settings.preventSleep ? .on : .off; notifications.state = settings.notifications ? .on : .off
        stack.addArrangedSubview(sleep); stack.addArrangedSubview(notifications)
        hint("0 KB/s means unlimited. Bandwidth is shared conservatively across available slots. Folder and connection changes apply to new downloads; running video limits apply on restart.")
        buttons("Save", action: #selector(save))
    }
    @objc private func chooseFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.beginSheetModal(for: panel) { [weak self] result in
            if result == .OK, let url = picker.url { self?.folder.stringValue = url.path }
        }
    }
    @objc private func save() {
        guard let c = Int(concurrency.stringValue), (1...12).contains(c),
              let n = Int(connections.stringValue), (1...16).contains(n),
              let r = Int(retries.stringValue), (0...10).contains(r),
              let k = Int64(limit.stringValue), (0...1_000_000_000).contains(k), folder.stringValue.hasPrefix("/") else {
            error("Use 1–12 files, 1–16 connections, 0–10 retries, a nonnegative speed, and an absolute folder path."); return
        }
        let destination = URL(fileURLWithPath: folder.stringValue, isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { self.error(error.localizedDescription); return }
        let settings = DownloadSettings.shared
        settings.folder = destination; settings.concurrentDownloads = c; settings.connections = n
        settings.retries = r; settings.speedLimit = k * 1024; settings.preventSleep = sleep.state == .on
        settings.notifications = notifications.state == .on
        if settings.notifications { DownloadServices.shared.requestNotifications() }
        manager.tick(); close()
    }
}

@MainActor
final class QueueSchedulePanel: FormPanel {
    let manager: DownloadManager
    let start = NSDatePicker(), stop = NSDatePicker()
    let startEnabled = NSButton(checkboxWithTitle: "Start / resume queue", target: nil, action: nil)
    let stopEnabled = NSButton(checkboxWithTitle: "Stop / pause queue", target: nil, action: nil)
    init(manager: DownloadManager) {
        self.manager = manager
        super.init(title: "Schedule Queue", height: 290)
        for picker in [start, stop] { picker.datePickerElements = [.yearMonthDay, .hourMinute]; picker.dateValue = Date().addingTimeInterval(3600) }
        start.dateValue = DownloadSettings.shared.queueStart ?? start.dateValue
        stop.dateValue = DownloadSettings.shared.queueStop ?? Date().addingTimeInterval(7200)
        startEnabled.state = DownloadSettings.shared.queueStart == nil ? .off : .on
        stopEnabled.state = DownloadSettings.shared.queueStop == nil ? .off : .on
        stack.addArrangedSubview(startEnabled); row("Start time", start)
        stack.addArrangedSubview(stopEnabled); row("Stop time", stop)
        hint("Times use your Mac’s local time zone. MacDM must be running and the Mac awake. Uncheck both to clear the schedule.")
        buttons("Save Schedule", action: #selector(save))
    }
    @objc private func save() {
        guard (startEnabled.state == .off || start.dateValue > Date()),
              (stopEnabled.state == .off || stop.dateValue > Date()),
              !(startEnabled.state == .on && stopEnabled.state == .on && stop.dateValue <= start.dateValue) else {
            error("Choose future times with stop after start."); return
        }
        DownloadSettings.shared.queueStart = startEnabled.state == .on ? start.dateValue : nil
        DownloadSettings.shared.queueStop = stopEnabled.state == .on ? stop.dateValue : nil
        if startEnabled.state == .on { manager.pauseAll() }
        manager.onChange?(); close()
    }
}

@MainActor
final class ItemOptionsPanel: FormPanel {
    let manager: DownloadManager
    let item: DownloadItem
    var limit: NSTextField!
    var checksum: NSTextField!
    let date = NSDatePicker()
    let schedule = NSButton(checkboxWithTitle: "Start at selected time", target: nil, action: nil)
    init(manager: DownloadManager, item: DownloadItem) {
        self.manager = manager; self.item = item
        super.init(title: "Download Options", height: 330)
        hint(item.displayTitle)
        limit = field("Limit (KB/s)", value: String(item.speedLimit / 1024))
        checksum = field("Expected SHA-256", value: item.expectedSHA256 ?? "", placeholder: "Optional, 64 hexadecimal characters")
        date.datePickerElements = [.yearMonthDay, .hourMinute]; date.dateValue = item.scheduledAt ?? Date().addingTimeInterval(3600)
        schedule.state = item.scheduledAt == nil ? .off : .on
        if item.state == .completed { schedule.state = .off; schedule.isEnabled = false; date.isEnabled = false }
        stack.addArrangedSubview(schedule); row("Start time", date)
        hint("0 KB/s means unlimited. Changing options pauses active transfers. Resume to apply. A scheduled transfer starts automatically while MacDM is running.")
        buttons("Apply", action: #selector(save))
    }
    @objc private func save() {
        let hash = checksum.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(limit.stringValue), (0...1_000_000_000).contains(value),
              hash.isEmpty || DownloadInput.checksum(hash) != nil,
              schedule.state == .off || date.dateValue > Date() else {
            error("Enter a nonnegative speed, a valid SHA-256, and a future start time."); return
        }
        manager.pause(item)
        item.speedLimit = value * 1024; item.expectedSHA256 = DownloadInput.checksum(hash)
        item.scheduledAt = schedule.state == .on ? date.dateValue : nil
        if item.scheduledAt != nil && item.state != .completed { item.state = .queued }
        manager.onChange?(); manager.pump(); close()
    }
}

@MainActor
final class BatchPanel: FormPanel {
    let manager: DownloadManager
    let text = NSTextView()
    let later = NSButton(checkboxWithTitle: "Add paused", target: nil, action: nil)
    init(manager: DownloadManager) {
        self.manager = manager
        super.init(title: "Add Multiple Links", height: 420)
        hint("Paste one HTTP or HTTPS link per line, or import a UTF-8 text file.")
        text.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        text.minSize = NSSize(width: 0, height: 220)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        text.string = clipboard.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return (line.hasPrefix("https://") || line.hasPrefix("http://")) && DownloadInput.url(line) != nil
        }.joined(separator: "\n")
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        stack.addArrangedSubview(NSButton(title: "Import Text File…", target: self, action: #selector(importFile)))
        stack.addArrangedSubview(later); buttons("Add Links", action: #selector(add))
    }
    @objc private func importFile() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = false
        picker.beginSheetModal(for: panel) { [weak self] result in
            guard result == .OK, let url = picker.url, let self else { return }
            do { self.text.string = try String(contentsOf: url, encoding: .utf8) }
            catch { self.error(error.localizedDescription) }
        }
    }
    @objc private func add() {
        let result = manager.addBatch(text.string, startNow: later.state == .off)
        if result.rejected > 0 {
            text.string = text.string.components(separatedBy: .newlines).filter { DownloadInput.url($0) == nil && !$0.isEmpty }.joined(separator: "\n")
            error("Added \(result.added) links; skipped \(result.rejected) invalid or duplicate links.")
        } else { close() }
    }
}
