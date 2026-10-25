import AppKit

@MainActor
final class MediaOptionsPanel: FormPanel, NSTableViewDataSource, NSTableViewDelegate {
    let manager: DownloadManager
    var urlField: NSTextField!
    var height: NSTextField!
    let format = NSPopUpButton()
    let audio = NSButton(checkboxWithTitle: "Audio only", target: nil, action: nil)
    let subtitles = NSButton(checkboxWithTitle: "Download and embed English subtitles when available", target: nil, action: nil)
    let paused = NSButton(checkboxWithTitle: "Add paused", target: nil, action: nil)
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    var entries: [VideoDetector.PlaylistEntry] = []
    private var lookup: Task<Void, Never>?
    private var loadedURL: String?

    init(manager: DownloadManager, url: String = "") {
        self.manager = manager
        super.init(title: "Video Options & Playlists", width: 640, height: 570)
        urlField = field("Video or playlist URL", value: url)
        height = field("Maximum height", placeholder: "Blank = best, e.g. 1080")
        format.addItems(withTitles: ["Source", "MP4", "MKV", "WebM", "M4A (audio)", "MP3 (audio)"])
        row("Output format", format)
        stack.addArrangedSubview(audio); stack.addArrangedSubview(subtitles)
        hint("MP4/MKV/WebM, audio conversion, and embedded subtitles require ffmpeg. Source preserves the downloaded format. Quality is never upscaled.")
        stack.addArrangedSubview(NSButton(title: "Load Playlist / Available Qualities", target: self, action: #selector(load)))
        status.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let col = NSTableColumn(identifier: .init("title")); col.title = "Select playlist items (⌘ or ⇧ for multiple)"; col.width = 550
        table.addTableColumn(col); table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(paused)
        buttons("Add Selected / Download", action: #selector(add))
    }
    override func close() { lookup?.cancel(); super.close() }
    @objc private func load() {
        guard let url = DownloadInput.url(urlField.stringValue) else { error("Enter a valid HTTP or HTTPS URL."); return }
        loadedURL = url
        lookup?.cancel(); entries = []; table.reloadData(); status.stringValue = "Looking up media…"
        lookup = Task { @MainActor in
            do {
                let list = try await VideoDetector.playlist(url: url)
                try Task.checkCancellation()
                guard DownloadInput.url(urlField.stringValue) == url else { status.stringValue = "URL changed; load the new link."; return }
                entries = list; table.reloadData()
                if !list.isEmpty {
                    table.selectAll(nil)
                    status.stringValue = "\(list.count) items (up to 500). Select the items to download."
                } else {
                    let info = try await VideoDetector.fetchInfo(url: url)
                    try Task.checkCancellation()
                    status.stringValue = (info.title ?? "Video") + " · " + VideoDetector.availableHeights(info).map { "\($0)p" }.joined(separator: ", ")
                }
            } catch where Task.isCancelled { return }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func add() {
        guard let url = DownloadInput.url(urlField.stringValue) else { error("Enter a valid HTTP or HTTPS URL."); return }
        let text = height.stringValue.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || (Int(text).map { (144...8640).contains($0) } ?? false) else { error("Maximum height must be 144–8640, or blank."); return }
        let containers = ["source", "mp4", "mkv", "webm", "m4a", "mp3"]
        let container = containers[max(0, format.indexOfSelectedItem)]
        let audioOnly = audio.state == .on || ["m4a", "mp3"].contains(container)
        guard !(audioOnly && ["mp4", "mkv", "webm"].contains(container)) else { error("For audio only, select Source, M4A, or MP3."); return }
        if (container != "source" || subtitles.state == .on), VideoDetector.ffmpegPath == nil {
            error("Install ffmpeg to use conversion or embedded subtitles, or select Source."); return
        }
        guard entries.isEmpty || loadedURL == url else { error("The URL changed. Load the playlist again before adding items."); return }
        let selected = table.selectedRowIndexes
        guard entries.isEmpty || !selected.isEmpty else { error("Select at least one playlist item."); return }
        var added = 0
        let indices: [Int?] = entries.isEmpty ? [nil] : selected.map { Optional($0) }
        for index in indices {
            let raw = index.flatMap { entries[$0].webpage_url ?? entries[$0].url }
            let entryURL = raw.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? DownloadInput.url($0) : nil }
            let target = entryURL ?? url
            let playlistIndex = entryURL == nil ? index.map { String($0 + 1) } : nil
            if manager.add(url: target, maxHeight: Int(text), referrer: url,
                           startNow: paused.state == .off, forceVideo: true,
                           audioOnly: audioOnly, mediaFormat: container,
                           subtitles: subtitles.state == .on, playlistItems: playlistIndex) != nil { added += 1 }
        }
        if added == 0 { error("These downloads already exist in the list.") } else { close() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "\(row + 1). \(entries[row].title ?? "Untitled")")
        label.lineBreakMode = .byTruncatingTail; return label
    }
}
