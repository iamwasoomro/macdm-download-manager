import AppKit

// MARK: - Add sheet

@MainActor
final class AddPanelControllerImpl: NSObject {
    unowned let manager: DownloadManager
    var panel: NSPanel?
    var urlField: NSTextField?
    var categoryPopup: NSPopUpButton?
    var hint: NSTextField?
    var qualityPopup: NSPopUpButton?
    var qualityLabel: NSTextField?
    private var fetchGeneration = 0

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func present(on window: NSWindow) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 232),
                        styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        p.title = "Add Download"
        p.isFloatingPanel = false
        p.worksWhenModal = true
        panel = p

        let label = NSTextField(labelWithString: "URL")
        label.font = .systemFont(ofSize: 12, weight: .semibold)

        let field = NSTextField()
        field.placeholderString = "https://… or a YouTube / Vimeo link"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(addNow)
        urlField = field

        let catLabel = NSTextField(labelWithString: "Category")
        catLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Auto-detect"] + DownloadCategory.allCases.map(\.folderName))
        categoryPopup = popup

        let qLabel = NSTextField(labelWithString: "Quality")
        qLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        qualityLabel = qLabel

        let qPopup = NSPopUpButton()
        qPopup.addItem(withTitle: "Best available")
        qPopup.isEnabled = false
        qualityPopup = qPopup

        let hintField = NSTextField(labelWithString: "")
        hintField.font = .systemFont(ofSize: 11)
        hintField.textColor = .secondaryLabelColor
        hint = hintField

        let add = NSButton(title: "Start Download", target: self, action: #selector(addNow))
        add.bezelStyle = .rounded
        add.controlSize = .large
        add.keyEquivalent = "\r"

        let later = NSButton(title: "Download Later", target: self, action: #selector(addLater))
        later.bezelStyle = .rounded
        later.controlSize = .large

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView()
        [label, field, catLabel, popup, qLabel, qPopup, hintField, later, add, cancel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            catLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            catLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            popup.centerYAnchor.constraint(equalTo: catLabel.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: catLabel.trailingAnchor, constant: 8),

            qLabel.centerYAnchor.constraint(equalTo: catLabel.centerYAnchor),
            qLabel.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 16),
            qPopup.centerYAnchor.constraint(equalTo: catLabel.centerYAnchor),
            qPopup.leadingAnchor.constraint(equalTo: qLabel.trailingAnchor, constant: 8),

            hintField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hintField.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 10),

            cancel.trailingAnchor.constraint(equalTo: later.leadingAnchor, constant: -8),
            later.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -8),
            later.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            add.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: add.centerYAnchor),
        ])
        p.contentView = content
        window.beginSheet(p) { _ in }
        field.becomeFirstResponder()
        // live category preview while typing
        NotificationCenter.default.addObserver(self, selector: #selector(fieldChanged),
                                               name: NSControl.textDidChangeNotification, object: field)
    }

    @objc private func fieldChanged() {
        let text = urlField?.stringValue ?? ""
        guard !text.isEmpty else { hint?.stringValue = ""; return }
        let cat = DownloadCategory.detect(url: text)
        if VideoDetector.isSupportedSite(text) {
            hint?.stringValue = "Video site detected — checking available qualities…"
            fetchQualities(for: text)
        } else {
            hint?.stringValue = "Will be saved to \(cat.folderName)"
            qualityPopup?.removeAllItems()
            qualityPopup?.addItem(withTitle: "Best available")
            qualityPopup?.isEnabled = false
        }
    }

    /// Asks yt-dlp for the video's available resolutions and fills the quality popup.
    private func fetchQualities(for text: String) {
        fetchGeneration += 1
        let gen = fetchGeneration
        var url = text
        if !url.hasPrefix("http") { url = "https://" + url }
        Task { @MainActor in
            guard let info = try? await VideoDetector.fetchInfo(url: url) else {
                if gen == self.fetchGeneration {
                    self.hint?.stringValue = "Video site detected — quality lookup unavailable"
                    self.qualityPopup?.isEnabled = false
                }
                return
            }
            guard gen == self.fetchGeneration else { return }
            let title = (info.title ?? "video").prefix(40)
            let heights = VideoDetector.availableHeights(info)
            let popup = self.qualityPopup
            popup?.removeAllItems()
            popup?.addItem(withTitle: "Best available")
            for h in heights {
                let label = h >= 2160 ? "4K (2160p)" : h >= 1440 ? "1440p" : "\(h)p"
                popup?.addItem(withTitle: label)
                popup?.lastItem?.representedObject = h
            }
            popup?.isEnabled = !(heights.isEmpty)
            self.hint?.stringValue = heights.isEmpty
                ? "\"\(title)\" — single quality available"
                : "\"\(title)\" — \(heights.count) qualities available"
        }
    }

    @objc private func addNow() { submit(startNow: true) }
    @objc private func addLater() { submit(startNow: false) }

    private func submit(startNow: Bool) {
        guard let text = urlField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            close()
            return
        }
        let height = qualityPopup?.selectedItem?.representedObject as? Int
        guard let added = manager.add(url: text, maxHeight: height, startNow: startNow) else {
            let alert = NSAlert(); alert.messageText = "Enter a valid HTTP/HTTPS link that isn’t already in the list."
            if let panel { alert.beginSheetModal(for: panel) }
            return
        }
        // Manual category override if the user chose one
        if let idx = categoryPopup?.indexOfSelectedItem, idx > 0 {
            let cat = DownloadCategory.allCases[idx - 1]
            added.category = cat
        }
        manager.onChange?()
        close()
    }

    @objc private func close() {
        if let p = panel, let sheetParent = p.sheetParent {
            sheetParent.endSheet(p)
        }
        panel = nil
    }
}

// typealias keeps AppDelegate's property type simple
typealias AddPanelController = AddPanelControllerImpl

// MARK: - Menu bar (status item)

/// Menu bar icon with live download status and quick actions.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let manager: DownloadManager
    private let onClick: () -> Void
    private var menu = NSMenu()

    init(manager: DownloadManager, onClick: @escaping () -> Void) {
        self.manager = manager
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "MacDM")
        refresh()
    }

    func refresh() {
        menu.removeAllItems()

        let active = manager.items.filter { $0.state == .downloading || $0.state == .fetching }
        let done = manager.items.filter { $0.state == .completed }

        let title = active.isEmpty
            ? "MacDM — idle"
            : "MacDM — \(active.count) active download\(active.count == 1 ? "" : "s")"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")

        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open MacDM", action: #selector(openApp), keyEquivalent: "")
        open.target = self

        if let current = active.first {
            menu.addItem(.separator())
            let line = menu.addItem(withTitle: "\(current.filename) — \(Int((current.progress * 100).rounded()))%", action: nil, keyEquivalent: "")
            line.isEnabled = false
        }

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit MacDM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu

        // Visual state on the menu bar icon
        if active.isEmpty {
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "MacDM")
            statusItem.button?.contentTintColor = nil
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "MacDM downloading")
            statusItem.button?.contentTintColor = .controlAccentColor
        }
        _ = done
    }

    @objc private func openApp() { onClick() }
    @objc private func quit() { NSApp.terminate(nil) }
}
