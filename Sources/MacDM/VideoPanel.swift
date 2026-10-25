import AppKit

// MARK: - Add Video sheet

/// "Add Video" flow: paste a link → loader while yt-dlp checks it →
/// quality picker (Best / 4K / 1080p / 720p …) → download.
/// The link must yield a video (video site, HLS/DASH stream, or direct media
/// file); anything else shows an error. The item is forced into the Videos
/// category and the given link is recorded as its referrer.
@MainActor
final class VideoPanelControllerImpl: NSObject {
    unowned let manager: DownloadManager
    /// Fired after a download is queued so the window can reveal the Videos list.
    var onSubmitted: (() -> Void)?
    var panel: NSPanel?
    var urlField: NSTextField?
    private var sizeLabel: NSTextField?
    private var qualityPopup: NSPopUpButton?
    private var lastURL: String?
    private var lastInfo: VideoDetector.Info?
    private var fetchGeneration = 0
    private var optionsPanel: MediaOptionsPanel?

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func present(on window: NSWindow) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                        styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        p.title = "Add Video"
        p.isFloatingPanel = false
        p.worksWhenModal = true
        panel = p
        setContent(makeInputView(), height: 150)
        window.beginSheet(p) { _ in }
        urlField?.becomeFirstResponder()
    }

    // MARK: state 1 — input

    private func makeInputView() -> NSView {
        let label = NSTextField(labelWithString: "URL")
        label.font = .systemFont(ofSize: 12, weight: .semibold)

        let field = NSTextField()
        field.placeholderString = "YouTube / X / any video page, stream or .mp4 link"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(fetchClicked)
        urlField = field

        let hint = NSTextField(labelWithString: "MacDM checks the link and lists the available qualities.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let fetch = NSButton(title: "Get Video", target: self, action: #selector(fetchClicked))
        fetch.bezelStyle = .rounded
        fetch.controlSize = .large
        fetch.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView()
        [label, field, hint, cancel, fetch].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),

            cancel.trailingAnchor.constraint(equalTo: fetch.leadingAnchor, constant: -8),
            fetch.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            fetch.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: fetch.centerYAnchor),
        ])
        return content
    }

    // MARK: state 2 — loader

    private func makeLoadingView() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)

        let text = NSTextField(labelWithString: "Checking link — resolving video…")
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .secondaryLabelColor

        let content = NSView()
        [spinner, text].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -6),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            text.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
        ])
        return content
    }

    // MARK: state 3 — results

    private func makeResultsView(title: String, heights: [Int], info: VideoDetector.Info?) -> NSView {
        let icon = NSTextField(labelWithString: "🎬")
        icon.font = .systemFont(ofSize: 22)

        let titleField = NSTextField(labelWithString: "Video found — \(title)")
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor

        let qLabel = NSTextField(labelWithString: "Quality")
        qLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let popup = NSPopUpButton()
        popup.addItem(withTitle: "Best available")
        for h in heights {
            popup.addItem(withTitle: h >= 2160 ? "4K (2160p)" : h >= 1440 ? "1440p" : "\(h)p")
            popup.lastItem?.representedObject = h
        }
        popup.target = self
        popup.action = #selector(qualityChanged)
        qualityPopup = popup

        let sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        self.sizeLabel = sizeLabel

        let download = NSButton(title: "Start Download", target: self, action: #selector(startDownload))
        download.bezelStyle = .rounded
        download.controlSize = .large
        download.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        let options = NSButton(title: "Audio, Format, Subtitles / Playlist…", target: self, action: #selector(advanced))
        let content = NSView()
        [icon, titleField, qLabel, popup, sizeLabel, options, cancel, download].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleField.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            qLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            qLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            popup.centerYAnchor.constraint(equalTo: qLabel.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: qLabel.trailingAnchor, constant: 8),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            sizeLabel.centerYAnchor.constraint(equalTo: qLabel.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 12),

            options.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            options.topAnchor.constraint(equalTo: qLabel.bottomAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: download.leadingAnchor, constant: -8),
            download.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            download.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: download.centerYAnchor),
        ])
        updateSizeLabel(sizeLabel, popup: popup, info: info)
        return content
    }

    private func updateSizeLabel(_ label: NSTextField?, popup: NSPopUpButton, info: VideoDetector.Info?) {
        guard let label else { return }
        guard let info else { label.stringValue = ""; return }
        let h = popup.selectedItem?.representedObject as? Int
        let bytes = DownloadIntake.estimateSize(info, maxHeight: h)
        label.stringValue = bytes > 0
            ? "≈ \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            : "size unknown"
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        updateSizeLabel(sizeLabel, popup: sender, info: lastInfo)
    }

    // MARK: content swapping

    private func setContent(_ view: NSView, height: CGFloat) {
        guard let panel else { return }
        panel.contentView = view
        panel.setContentSize(NSSize(width: 520, height: height))
    }

    // MARK: actions

    @objc private func fetchClicked() {
        guard let text = urlField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            close()
            return
        }
        var url = text
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "https://" + url }
        lastURL = url
        lastInfo = nil
        fetchGeneration += 1
        let gen = fetchGeneration
        setContent(makeLoadingView(), height: 120)

        Task { @MainActor in
            let result = await self.check(url: url)
            guard gen == self.fetchGeneration, self.panel != nil else { return }
            switch result {
            case .video(let info):
                self.lastInfo = info
                let title = String((info.title ?? url).prefix(52))
                self.setContent(self.makeResultsView(title: title,
                                                     heights: VideoDetector.availableHeights(info),
                                                     info: info),
                                height: 240)
            case .direct(let name):
                self.setContent(self.makeResultsView(title: name, heights: [], info: nil), height: 240)
            case .stream:
                self.setContent(self.makeResultsView(title: url, heights: [], info: nil), height: 240)
            case .notVideo(let reason):
                self.showNotVideo(reason)
            }
        }
    }

    private enum VideoCheck {
        case video(VideoDetector.Info)
        case direct(String)
        case stream
        case notVideo(String)
    }

    private func check(url: String) async -> VideoCheck {
        if VideoDetector.isStreamURL(url) {
            if let info = try? await VideoDetector.fetchInfo(url: url) { return .video(info) }
            return .stream
        }
        if await VideoDetector.isDirectMedia(url) {
            return .direct(URL(string: url)?.lastPathComponent ?? url)
        }
        do {
            let info = try await VideoDetector.fetchInfo(url: url)
            let hasVideo = (info.formats ?? []).contains { ($0.vcodec ?? "none") != "none" }
            if hasVideo {
                return .video(info)
            }
            return .notVideo("No video streams at this link (audio only, or an unsupported page).")
        } catch {
            return .notVideo("yt-dlp couldn't find a video here — \(error.localizedDescription)")
        }
    }

    private func showNotVideo(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This link isn't a video"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        setContent(makeInputView(), height: 150)
        if let panel {
            alert.beginSheetModal(for: panel) { [weak self] _ in
                self?.urlField?.becomeFirstResponder()
            }
        }
    }

    @objc private func advanced() {
        guard let window = panel?.sheetParent else { return }
        let url = lastURL ?? ""
        close()
        let options = MediaOptionsPanel(manager: manager, url: url)
        optionsPanel = options; options.present(on: window)
    }

    @objc private func startDownload() {
        guard let url = lastURL else { close(); return }
        let height = qualityPopup?.selectedItem?.representedObject as? Int
        guard let item = manager.add(url: url, maxHeight: height, referrer: url, startNow: true, forceVideo: true) else {
            let alert = NSAlert(); alert.messageText = "This video and quality are already in the list."
            if let panel { alert.beginSheetModal(for: panel) }
            return
        }
        // Video button semantics: always the Videos category, link is its referrer,
        // and page-style links route through yt-dlp even for unknown hosts.
        item.category = .videos
        item.forceVideo = true
        manager.onChange?()
        onSubmitted?()
        close()
    }

    @objc private func close() {
        fetchGeneration += 1
        if let p = panel, let sheetParent = p.sheetParent {
            sheetParent.endSheet(p)
        }
        panel = nil
    }
}

typealias VideoPanelController = VideoPanelControllerImpl
