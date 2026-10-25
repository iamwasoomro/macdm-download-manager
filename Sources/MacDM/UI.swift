import AppKit
import Combine

// MARK: - Category metadata

extension DownloadCategory {
    var symbol: String {
        switch self {
        case .music: return "music.note.list"
        case .videos: return "film.stack"
        case .programs: return "shippingbox.fill"
        case .compressed: return "doc.zipper"
        case .other: return "doc.text"
        }
    }

    var accent: NSColor {
        switch self {
        case .music: return .systemRed
        case .videos: return .systemPurple
        case .programs: return .systemBlue
        case .compressed: return .systemTeal
        case .other: return .systemGray
        }
    }

    var emptyTitle: String {
        switch self {
        case .music: return "No music yet"
        case .videos: return "No videos yet"
        case .programs: return "No programs yet"
        case .compressed: return "No compressed files yet"
        case .other: return "Nothing here yet"
        }
    }

    var emptyMessage: String {
        "Add a download with the ＋ button, paste a URL,\nor send one from the Chrome extension."
    }
}

// MARK: - Sidebar

/// Sidebar with SF Symbol icons, per-category counts and All Downloads row.
@MainActor
final class CategorySidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = NSOutlineView()
    private let manager: DownloadManager
    private let onSelect: (DownloadCategory?) -> Void
    private var rows: [(name: String, symbol: String, color: NSColor, category: DownloadCategory?, count: Int)] = []

    init(manager: DownloadManager, onSelect: @escaping (DownloadCategory?) -> Void) {
        self.manager = manager
        self.onSelect = onSelect
        super.init()
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .sourceList
        outlineView.rowHeight = 34
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cat"))
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        reload()
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func reload() {
        rows = [("All Downloads", "tray.full", .labelColor, nil, manager.items.count)]
        rows += DownloadCategory.allCases.map { c in
            (c.folderName, c.symbol, c.accent, c, manager.items.filter { $0.category == c }.count)
        }
        outlineView.reloadData()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { rows.count }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { rows[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let idx = outlineView.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        onSelect(rows[idx].category)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? (name: String, symbol: String, color: NSColor, category: DownloadCategory?, count: Int) else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebar")

        let cell = NSTableCellView()
        cell.identifier = id

        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.name)
        icon.contentTintColor = row.color

        let label = NSTextField(labelWithString: row.name)
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let countLabel = NSTextField(labelWithString: row.count > 0 ? "\(row.count)" : "")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.addSubview(countLabel)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Content area

/// Header + download list + empty state for the selected category.
@MainActor
final class DownloadsContentController: NSObject {
    let viewController = NSViewController()
    private(set) var manager: DownloadManager!
    /// Fired when the user clicks an in-content "add" affordance.
    var onAdd: (() -> Void)?
    var onAddVideo: (() -> Void)?
    private var category: DownloadCategory?
    private var tableView = NSTableView()
    private var emptyView = NSView()
    private var headerField = NSTextField(labelWithString: "All Downloads")
    private var subheaderField = NSTextField(labelWithString: "")
    private var observed: [UUID: AnyCancellable] = [:]
    private let search = NSSearchField()
    private let statusFilter = NSPopUpButton()
    private let sortPicker = NSPopUpButton()
    private var controlPanel: FormPanel?
    private var menuItemID: UUID?
    private var menuSelection: [UUID] = []
    private var displayedIDs: [UUID] = []


    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
        buildUI()
        observeItems()
    }

    private var items: [DownloadItem] {
        var list = category.map { c in manager.items.filter { $0.category == c } } ?? manager.items
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { list = list.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) } }
        let states: [[DownloadState]] = [[], [.fetching, .downloading], [.queued], [.paused], [.failed], [.completed], [.cancelled]]
        let index = statusFilter.indexOfSelectedItem
        if index > 0, index < states.count { list = list.filter { states[index].contains($0.state) } }
        switch sortPicker.indexOfSelectedItem {
        case 1: list.sort { $0.addedAt > $1.addedAt }
        case 2: list.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case 3: list.sort { $0.totalBytes > $1.totalBytes }
        default: break
        }
        return list
    }

    func show(category: DownloadCategory?) {
        self.category = category
        reload()
    }

    /// Delete flow: completed items get a dialog with an (unchecked) "delete
    /// file from disk" checkbox; incomplete/failed items get a confirmation
    /// that also clears temporary files.
    func requestDelete(_ item: DownloadItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \"\(item.filename)\"?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        var deleteFile = false
        if item.state == .completed {
            alert.informativeText = "This removes the download from the list."
            let checkbox = NSButton(checkboxWithTitle: "Also delete file from disk", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox
            if alert.runModal() == .alertFirstButtonReturn {
                deleteFile = checkbox.state == .on
                manager.remove(item, deleteFileFromDisk: deleteFile)
            }
        } else {
            alert.informativeText = "Any partially downloaded temporary files will be deleted."
            if alert.runModal() == .alertFirstButtonReturn {
                manager.remove(item, deleteFileFromDisk: false)
            }
        }
    }

    func reload() {
        observeItems()
        headerField.stringValue = category?.folderName ?? "All Downloads"
        let selected = Set(tableView.selectedRowIndexes.compactMap { displayedIDs[safe: $0] })
        let list = items
        let active = list.filter { $0.state == .downloading || $0.state == .fetching }.count
        let speed = ByteCountFormatter.string(fromByteCount: Int64(manager.aggregateSpeed), countStyle: .file)
        subheaderField.stringValue = "\(list.count) \(itemS(list.count)) · \(active) active · \(speed)/s"
        displayedIDs = list.map { $0.id }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(displayedIDs.enumerated().compactMap { selected.contains($0.element) ? $0.offset : nil }), byExtendingSelection: false)
        emptyView.isHidden = !list.isEmpty
        tableView.isHidden = list.isEmpty
    }

    private func observeItems() {
        let ids = Set(manager.items.map { $0.id })
        observed = observed.filter { ids.contains($0.key) }
        for item in manager.items where observed[item.id] == nil {
            observed[item.id] = item.objectWillChange
                .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in self?.reload() }
        }
    }

    private func buildUI() {
        let header = makeHeader()
        let controls = makeControls()
        let list = makeList()
        emptyView = makeEmptyState()

        let container = NSView()
        container.addSubview(header)
        container.addSubview(controls)
        container.addSubview(list)
        container.addSubview(emptyView)
        header.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // below the transparent titlebar/toolbar (fullSizeContentView window)
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            list.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 20),
        ])
        viewController.view = container
    }

    private func makeHeader() -> NSView {
        headerField.font = .systemFont(ofSize: 26, weight: .bold)
        subheaderField.font = .systemFont(ofSize: 12)
        subheaderField.textColor = .secondaryLabelColor

        let addButton = NSButton(title: " Add Link", target: self, action: #selector(addClicked))
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add link")
        addButton.imagePosition = .imageLeading
        addButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addButton.controlSize = .regular

        let videoButton = NSButton(title: " Add Video", target: self, action: #selector(addVideoClicked))
        videoButton.bezelStyle = .rounded
        videoButton.image = NSImage(systemSymbolName: "video", accessibilityDescription: "Add video")
        videoButton.imagePosition = .imageLeading
        videoButton.font = .systemFont(ofSize: 12, weight: .semibold)
        videoButton.controlSize = .regular

        let titles = NSStackView(views: [headerField, subheaderField])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let row = NSStackView(views: [titles, videoButton, addButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        // keep the button right-aligned as the window resizes
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeControls() -> NSView {
        search.placeholderString = "Search downloads"; search.target = self; search.action = #selector(filterChanged)
        statusFilter.addItems(withTitles: ["All states", "Active", "Queued", "Paused", "Failed", "Completed", "Cancelled"])
        sortPicker.addItems(withTitles: ["Queue order", "Newest first", "Name", "Largest first"])
        for picker in [statusFilter, sortPicker] { picker.target = self; picker.action = #selector(filterChanged) }
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        actions.addItem(withTitle: "Actions")
        for (title, selector) in [("Pause All", #selector(pauseAll)), ("Resume All", #selector(resumeAll)),
                                  ("Add Multiple Links…", #selector(batch)), ("Video Options / Playlist…", #selector(media)),
                                  ("Schedule Queue…", #selector(scheduleQueue)), ("Settings…", #selector(settings)),
                                  ("Clear Completed History", #selector(clearCompleted))] {
            actions.addItem(withTitle: title); actions.lastItem?.target = self; actions.lastItem?.action = selector
        }
        let row = NSStackView(views: [search, statusFilter, sortPicker, actions]); row.spacing = 6
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return row
    }
    @objc private func filterChanged() { reload() }
    @objc func pauseAll() { manager.pauseAll() }
    @objc func resumeAll() { manager.resumeAll() }
    @objc func batch() { showPanel(BatchPanel(manager: manager)) }
    @objc func media() { showPanel(MediaOptionsPanel(manager: manager)) }
    @objc func settings() { showPanel(SettingsPanel(manager: manager)) }
    @objc private func scheduleQueue() { showPanel(QueueSchedulePanel(manager: manager)) }
    private func showPanel(_ panel: FormPanel) {
        guard let window = viewController.view.window, window.attachedSheet == nil else { return }
        controlPanel = panel; panel.present(on: window)
    }
    @objc private func clearCompleted() {
        for item in manager.items where item.state == .completed { manager.remove(item, deleteFileFromDisk: false) }
    }

    @objc private func addClicked() { onAdd?() }
    @objc private func addVideoClicked() { onAddVideo?() }

    // MARK: - Right-click menu

    private func menuTargets() -> [NSMenuItem] { [] }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard let item = items[safe: row] else { return }
        menuItemID = item.id
        menuSelection = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes.compactMap { items[safe: $0]?.id } : [item.id]

        func add(_ title: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }

        switch item.state {
        case .downloading, .fetching, .queued:
            add("Pause Download", #selector(menuPause(_:)))
        case .paused, .failed, .cancelled:
            add("Resume Download", #selector(menuResume(_:)))
        case .completed:
            add("Reveal in Finder", #selector(menuReveal(_:)))
        }
        if item.state == .paused || item.state == .failed {
            add("Refresh Download…", #selector(menuRefresh(_:)))
        }
        menu.addItem(.separator())
        add("Move Earlier", #selector(moveEarlier))
        add("Move Later", #selector(moveLater))
        add("Prioritize", #selector(prioritize))
        add("Download Options…", #selector(itemOptions))
        if item.state == .completed { add("Verify SHA-256…", #selector(verify)) }
        if menuSelection.count > 1 {
            add("Pause Selected", #selector(pauseSelected))
            add("Resume Selected", #selector(resumeSelected))
            add("Remove Selected…", #selector(removeSelected))
        }
        add("Remove…", #selector(menuRemove(_:)))
    }

    private func menuItemAt(_ row: Int) -> DownloadItem? {
        guard let item = items[safe: row] else { return nil }
        // capture the row's item at click time (clickedRow is still valid
        // while the menu action fires)
        return item
    }

    @objc private func menuPause(_ sender: Any?) {
        if let item = contextItem { manager.pause(item) }
    }
    @objc private func menuResume(_ sender: Any?) {
        if let item = contextItem { manager.retry(item) }
    }
    @objc private func menuReveal(_ sender: Any?) {
        if let item = contextItem { manager.revealInFinder(item) }
    }
    @objc private func menuRemove(_ sender: Any?) {
        if let item = contextItem { requestDelete(item) }
    }
    @objc private func menuRefresh(_ sender: Any?) {
        guard let item = contextItem else { return }
        RefreshPanelController.present(item: item, manager: manager,
                                       on: viewController.view.window)
    }

    private var contextItem: DownloadItem? { manager.items.first { $0.id == menuItemID } }
    @objc private func moveEarlier() { if let item = contextItem { manager.move(item, offset: -1) } }
    @objc private func moveLater() { if let item = contextItem { manager.move(item, offset: 1) } }
    @objc private func prioritize() { if let item = contextItem { manager.prioritize(item) } }
    @objc private func itemOptions() { if let item = contextItem { showPanel(ItemOptionsPanel(manager: manager, item: item)) } }
    @objc private func pauseSelected() { for item in manager.items where menuSelection.contains(item.id) { manager.pause(item) } }
    @objc private func resumeSelected() { for item in manager.items where menuSelection.contains(item.id) { manager.retry(item) } }
    @objc private func removeSelected() {
        let alert = NSAlert(); alert.messageText = "Remove \(menuSelection.count) downloads?"
        alert.informativeText = "Completed files stay on disk; partial files are deleted."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            for item in manager.items where menuSelection.contains(item.id) { manager.remove(item, deleteFileFromDisk: false) }
        }
    }
    @objc private func verify() {
        guard let item = contextItem else { return }
        let alert = NSAlert(); alert.messageText = "Verify SHA-256"
        alert.informativeText = "Paste an expected checksum, or leave blank to calculate it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 450, height: 24)); field.stringValue = item.expectedSHA256 ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "Verify"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty || DownloadInput.checksum(raw) != nil else {
            let error = NSAlert(); error.messageText = "SHA-256 must contain 64 hexadecimal characters."; error.runModal(); return
        }
        let expected = DownloadInput.checksum(raw)
        Task { @MainActor in
            let result = NSAlert()
            do {
                let hash = try await Integrity.sha256(item.fileURL)
                item.actualSHA256 = hash; item.expectedSHA256 = expected
                result.messageText = expected == nil ? "SHA-256 calculated" : expected == hash ? "Checksum matches" : "Checksum mismatch"
                result.informativeText = hash
                manager.saveHistory()
            } catch { result.messageText = "Verification failed"; result.informativeText = error.localizedDescription }
            result.runModal()
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let item = items[safe: tableView.clickedRow], item.state == .completed else { return }
        NSWorkspace.shared.open(item.fileURL)
    }

    private func makeList() -> NSView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil   // single card column — no header chrome
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.rowHeight = 84
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.registerForDraggedTypes([.URL, .string])
        tableView.backgroundColor = .clear
        // double-clicking a finished download opens it with its default app
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        let ctxMenu = NSMenu()
        ctxMenu.delegate = self
        tableView.menu = ctxMenu
        tableView.enclosingScrollView?.autohidesScrollers = true
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let clip = scroll.contentView
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = NSEdgeInsets(top: 4, left: 16, bottom: 12, right: 16)
        return scroll
    }

    private func makeEmptyState() -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: category?.symbol ?? "arrow.down.circle",
                               accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 52, weight: .light)
        symbol.contentTintColor = .quaternaryLabelColor

        let title = NSTextField(labelWithString: "No downloads yet")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let message = NSTextField(labelWithString: "Click ＋ Add Download in the toolbar to add one,\nor send a link from the Chrome extension.")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .tertiaryLabelColor
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 3

        let addButton = NSButton(title: " Add Download", target: self, action: #selector(addClicked))
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add download")
        addButton.imagePosition = .imageLeading
        addButton.font = .systemFont(ofSize: 13, weight: .semibold)
        addButton.controlSize = .large

        let stack = NSStackView(views: [symbol, title, message, addButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyView = stack
        return stack
    }
}

extension DownloadsContentController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation { .copy }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pasteboard = info.draggingPasteboard
        guard let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) else { return false }
        return manager.addBatch(text).added > 0
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        return tableView.makeView(withIdentifier: id, owner: nil) as? CardRowView
            ?? CardRowView(reuseID: id)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? DownloadCardCell) ?? DownloadCardCell(reuseID: id)
        cell.configure(with: items[safe: row], controller: self)
        return cell
    }
}

/// Rounded "card" row background.
@MainActor
final class CardRowView: NSTableRowView {
    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSRect(x: 0, y: 2, width: bounds.width, height: bounds.height - 4)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
    }
}

/// A single download card: category icon, filename, status pill, progress, actions.
@MainActor
final class DownloadCardCell: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let pctLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let trashButton = NSButton()
    private var pill = NSView()
    private var pillLabel = NSTextField(labelWithString: "")
    private var current: DownloadItem?
    private weak var controller: DownloadsContentController?

    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID

        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        progress.style = .bar
        progress.controlSize = .small

        pctLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pctLabel.textColor = .secondaryLabelColor

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 7
        pillLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        pillLabel.alignment = .center

        actionButton.bezelStyle = .texturedRounded
        actionButton.controlSize = .small
        actionButton.imagePosition = .imageOnly

        trashButton.bezelStyle = .texturedRounded
        trashButton.controlSize = .small
        trashButton.imagePosition = .imageOnly
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(progress)
        addSubview(pctLabel)
        addSubview(pill)
        pill.addSubview(pillLabel)
        addSubview(actionButton)
        addSubview(trashButton)

        [icon, titleLabel, subtitleLabel, progress, pctLabel, pill, pillLabel, actionButton, trashButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            pill.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            pill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: 58),
            pill.heightAnchor.constraint(equalToConstant: 15),

            subtitleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            progress.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            progress.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 5),
            progress.widthAnchor.constraint(equalToConstant: 320),
            pctLabel.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 6),
            pctLabel.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
            progress.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),

            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        pillLabel.centerXAnchor.constraint(equalTo: pill.centerXAnchor).isActive = true
        pillLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: DownloadItem?, controller: DownloadsContentController) {
        guard let item = item else { return }
        self.current = item
        self.controller = controller
        icon.image = NSImage(systemSymbolName: item.category.symbol, accessibilityDescription: nil)
        icon.contentTintColor = item.category.accent
        titleLabel.stringValue = item.displayTitle
        titleLabel.toolTip = item.displayTitle

        let size = item.state == .completed
            ? Self.sizeString(item).components(separatedBy: " / ").last ?? Self.sizeString(item)
            : Self.sizeString(item)
        var subtitle = size
        if item.state == .downloading && item.speedBPS > 1 {
            subtitle += " · \(Self.speedString(item.speedBPS))"
            if let eta = item.eta { subtitle += " · \(eta) left" }
        }
        if item.state == .downloading && !item.segments.isEmpty && !item.usedYtDlp {
            subtitle += " · \(item.segments.count) segments"
        } else if item.usedYtDlp {
            subtitle += " · yt-dlp"
        }
        if item.verifying { subtitle += " · verifying SHA-256…" }
        if item.state == .failed { subtitle = item.error ?? "Download failed" }
        if let retry = item.retryAt { subtitle += " · retry \(item.retryCount) in \(max(0, Int(retry.timeIntervalSinceNow)))s" }
        if let scheduled = item.scheduledAt { subtitle += " · \(scheduled.formatted(date: .abbreviated, time: .shortened))" }
        subtitleLabel.stringValue = subtitle
        subtitleLabel.toolTip = item.error ?? subtitle

        pctLabel.stringValue = item.totalBytes > 0
            ? "\(Int((item.progress * 100).rounded()))%" : ""

        let isDone = item.state == .completed
        progress.isHidden = isDone
        pctLabel.isHidden = isDone || item.totalBytes <= 0
        progress.isIndeterminate = item.totalBytes <= 0 && (item.state == .downloading || item.state == .fetching)
        if progress.isIndeterminate {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            progress.doubleValue = item.progress * 100
        }

        configurePill(for: item)
        configureButton(for: item)
    }

    private func configurePill(for item: DownloadItem) {
        let text: String
        let fg: NSColor, bg: NSColor
        switch item.state {
        case .completed: text = "DONE"; fg = NSColor.systemGreen; bg = NSColor.systemGreen.withAlphaComponent(0.15)
        case .failed: text = "FAILED"; fg = .systemRed; bg = NSColor.systemRed.withAlphaComponent(0.15)
        case .downloading: text = "ACTIVE"; fg = .controlAccentColor; bg = NSColor.controlAccentColor.withAlphaComponent(0.15)
        case .fetching: text = "LINKING"; fg = .systemOrange; bg = NSColor.systemOrange.withAlphaComponent(0.15)
        case .queued: text = "QUEUED"; fg = .secondaryLabelColor; bg = NSColor.quaternaryLabelColor.withAlphaComponent(0.3)
        case .cancelled: text = "STOPPED"; fg = .secondaryLabelColor; bg = NSColor.quaternaryLabelColor.withAlphaComponent(0.3)
        case .paused: text = "PAUSED"; fg = .systemOrange; bg = NSColor.systemOrange.withAlphaComponent(0.15)
        }
        pillLabel.stringValue = text
        pillLabel.textColor = fg
        pill.layer?.backgroundColor = bg.cgColor
        pill.isHidden = false
    }

    private func configureButton(for item: DownloadItem) {
        let manager = controller?.manager
        switch item.state {
        case .queued, .failed, .cancelled:
            actionButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry")
            actionButton.action = #selector(retry)
        case .paused:
            actionButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
            actionButton.action = #selector(retry)
        case .downloading, .fetching:
            actionButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
            actionButton.action = #selector(cancel)
        case .completed:
            actionButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Reveal")
            actionButton.action = #selector(reveal)
        }
        actionButton.target = self
        actionButton.isEnabled = manager != nil
        actionButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        trashButton.target = self
        trashButton.action = #selector(deleteClicked)
    }

    @objc private func deleteClicked() { current.map { controller?.requestDelete($0) } }
    @objc private func retry() { current.map { controller?.manager.retry($0) } }
    @objc private func cancel() { current.map { controller?.manager.cancel($0) } }
    @objc private func reveal() { current.map { controller?.manager.revealInFinder($0) } }

    private static func speedString(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }

    private static func sizeString(_ item: DownloadItem) -> String {
        func fmt(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .file) }
        return item.totalBytes > 0 ? "\(fmt(item.receivedBytes)) / \(fmt(item.totalBytes))" : fmt(item.receivedBytes)
    }
}

func itemS(_ n: Int) -> String { n == 1 ? "item" : "items" }

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
