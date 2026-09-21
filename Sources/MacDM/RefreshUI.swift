import AppKit

/// Small "Please wait" modal-looking panel with a spinner, shown while the
/// app checks a link's file size (HEAD / yt-dlp metadata).
@MainActor
enum WaitPanel {
    private static var panel: NSPanel?

    static func show(on window: NSWindow?, text: String) {
        hide()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Please Wait"
        p.isFloatingPanel = true
        p.level = .floating

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle

        let content = NSView()
        [spinner, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
        p.contentView = content

        if let w = window {
            let rect = NSRect(x: w.frame.midX - 160, y: w.frame.midY - 60, width: 320, height: 120)
            p.setFrame(rect, display: false)
        } else {
            p.center()
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// "Refresh Download" sheet for a paused/failed download: edit the URL, or
/// press "Refresh Download from Browser" to reopen the referring page.
@MainActor
final class RefreshPanelController: NSObject {
    static var current: RefreshPanelController?
    private var panel: NSPanel?
    private var urlField: NSTextField?
    private unowned let item: DownloadItem
    private unowned let manager: DownloadManager
    private weak var mainWindow: NSWindow?

    init(item: DownloadItem, manager: DownloadManager, window: NSWindow?) {
        self.item = item
        self.manager = manager
        self.mainWindow = window
        super.init()
    }

    static func present(item: DownloadItem, manager: DownloadManager, on window: NSWindow?) {
        let ctrl = RefreshPanelController(item: item, manager: manager, window: window)
        ctrl.show(on: window)
        current = ctrl
    }

    private func show(on window: NSWindow?) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 232),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = "Refresh Download"
        panel = p

        let currentLabel = NSTextField(labelWithString: "Current URL")
        currentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        currentLabel.textColor = .secondaryLabelColor

        let currentURL = NSTextField(labelWithString: item.url)
        currentURL.font = .systemFont(ofSize: 11)
        currentURL.textColor = .tertiaryLabelColor
        currentURL.lineBreakMode = .byTruncatingMiddle
        currentURL.maximumNumberOfLines = 1

        let newLabel = NSTextField(labelWithString: "New URL")
        newLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let field = NSTextField()
        field.placeholderString = "https://… updated download link"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.controlSize = .large
        field.stringValue = item.url
        field.usesSingleLineMode = true
        urlField = field

        let note = NSTextField(labelWithString: item.referrerURL != nil
            ? "Tip: use “Refresh Download from Browser”, then send the download again from that page."
            : "Paste an updated link, or reopen the source page in your browser.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor

        let update = NSButton(title: "Update URL", target: self, action: #selector(updateClicked))
        update.bezelStyle = .rounded
        update.controlSize = .large
        update.keyEquivalent = "\r"

        let fromBrowser = NSButton(title: "Refresh Download from Browser",
                                   target: self, action: #selector(fromBrowserClicked))
        fromBrowser.bezelStyle = .rounded
        fromBrowser.controlSize = .large
        fromBrowser.isEnabled = item.referrerURL != nil || item.state != .completed

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView()
        [currentLabel, currentURL, newLabel, field, note, update, fromBrowser, cancel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            currentLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            currentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            currentURL.centerYAnchor.constraint(equalTo: currentLabel.centerYAnchor),
            currentURL.leadingAnchor.constraint(equalTo: currentLabel.trailingAnchor, constant: 8),
            currentURL.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            newLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            newLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: newLabel.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: newLabel.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 14),
            field.heightAnchor.constraint(equalToConstant: 30),

            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 34),

            cancel.trailingAnchor.constraint(equalTo: fromBrowser.leadingAnchor, constant: -8),
            fromBrowser.trailingAnchor.constraint(equalTo: update.leadingAnchor, constant: -8),
            update.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            update.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: update.centerYAnchor),
            fromBrowser.centerYAnchor.constraint(equalTo: update.centerYAnchor),
        ])

        p.contentView = content
        window?.beginSheet(p) { _ in }
        field.becomeFirstResponder()
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
    }

    @objc private func updateClicked() {
        let raw = urlField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != item.url else { close(); return }
        let window = mainWindow
        close()
        Task { @MainActor in
            await DownloadIntake.confirmManualRefresh(manager: self.manager, target: self.item,
                                                      newURL: raw, window: window)
        }
    }

    @objc private func fromBrowserClicked() {
        // Reopen the referring page (fall back to the file URL itself) so the
        // user can trigger the download again; the extension will send it back
        // with the same referrer and the app will match it to this item.
        let target = item.referrerURL ?? item.url
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func close() {
        if let p = panel, let parent = p.sheetParent {
            parent.endSheet(p)
        }
        panel = nil
        RefreshPanelController.current = nil
    }
}
