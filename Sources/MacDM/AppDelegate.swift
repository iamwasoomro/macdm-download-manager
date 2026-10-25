import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toolbarDelegate: ToolbarDelegate?
    private var historyTimer: Timer?
    var window: NSWindow!
    let manager = DownloadManager()
    var sidebar: CategorySidebar!
    var content: DownloadsContentController!
    var statusBar: StatusBarController!
    var addPanelController: AddPanelController!
    var videoPanelController: VideoPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.restoreHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.manager.tick()
                self?.content?.reload()
                if Int(Date().timeIntervalSince1970) % 5 == 0 { self?.manager.saveHistory() }
            }
        }
        content = DownloadsContentController(manager: manager)
        sidebar = CategorySidebar(manager: manager) { [weak self] category in
            self?.content.show(category: category)
        }
        content.onAdd = { [weak self] in
            guard let w = self?.window else { return }
            self?.addPanelController.present(on: w)
        }
        content.onAddVideo = { [weak self] in
            guard let w = self?.window else { return }
            self?.videoPanelController.present(on: w)
        }
        addPanelController = AddPanelController(manager: manager)
        videoPanelController = VideoPanelController(manager: manager)
        videoPanelController.onSubmitted = { [weak self] in
            self?.content.show(category: .videos)
        }
        statusBar = StatusBarController(manager: manager) { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar.outlineView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.backgroundColor = .clear

        // Real translucent-sidebar material: blurs the desktop behind the window
        // instead of letting the wallpaper showing through raw. No forced
        // appearance — the material follows light/dark mode so labels stay readable.
        let sidebarEffect = NSVisualEffectView()
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .active
        sidebarEffect.isEmphasized = false
        sidebarEffect.addSubview(sidebarScroll)
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),
        ])

        // Hand-rolled split: SDK's NSSplitViewItem convenience inits are broken on this CLT
        let split = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        [sidebarEffect, divider, content.viewController.view].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            split.addSubview($0)
        }
        NSLayoutConstraint.activate([
            sidebarEffect.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            sidebarEffect.topAnchor.constraint(equalTo: split.topAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            sidebarEffect.widthAnchor.constraint(equalToConstant: 210),
            divider.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            divider.topAnchor.constraint(equalTo: split.topAnchor),
            divider.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            content.viewController.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.viewController.view.topAnchor.constraint(equalTo: split.topAnchor),
            content.viewController.view.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            content.viewController.view.trailingAnchor.constraint(equalTo: split.trailingAnchor),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "MacDM"
        window.titlebarAppearsTransparent = true
        window.contentView = split
        window.toolbar = makeToolbar()
        window.minSize = NSSize(width: 980, height: 600)
        makeMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Route URLs arriving from the Chrome extension
        ExtensionServer.shared.onURL = { [weak self] incoming in
            DispatchQueue.main.async {
                guard let self else { return }
                Task { @MainActor in
                    await DownloadIntake.confirmAndAdd(manager: self.manager,
                                                       incoming: incoming, window: self.window)
                    self.content.show(category: nil)
                }
            }
        }
        ExtensionServer.shared.start()

        manager.onChange = { [weak self] in
            self?.manager.saveHistory()
            self?.content.reload()
            self?.sidebar.reload()
            self?.statusBar.refresh()
        }

        // README/screenshot helpers: `--demo`, `--video-panel`, `--snapshot out.png`
        Snapshotter.runIfNeeded(window: window, manager: manager, videoPanel: videoPanelController)
    }

    private func makeMenu() {
        let main = NSMenu()
        let application = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = application; main.addItem(appItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(DownloadsContentController.settings), keyEquivalent: ",")
        settings.target = content; application.addItem(settings)
        application.addItem(.separator())
        application.addItem(withTitle: "Quit MacDM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let downloads = NSMenu(); let downloadsItem = NSMenuItem(title: "Downloads", action: nil, keyEquivalent: ""); downloadsItem.submenu = downloads; main.addItem(downloadsItem)
        for (title, action, key) in [("Add Multiple Links…", #selector(DownloadsContentController.batch), "d"),
                                     ("Video Options / Playlist…", #selector(DownloadsContentController.media), ""),
                                     ("Pause All", #selector(DownloadsContentController.pauseAll), ""),
                                     ("Resume All", #selector(DownloadsContentController.resumeAll), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = content; downloads.addItem(item)
        }
        let edit = NSMenu(title: "Edit"), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar()
        toolbarDelegate = ToolbarDelegate(
            addAction: { [weak self] in
                guard let w = self?.window else { return }
                self?.addPanelController.present(on: w)
            },
            videoAction: { [weak self] in
                guard let w = self?.window else { return }
                self?.videoPanelController.present(on: w)
            })
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.insertItem(withItemIdentifier: .init("add"), at: 0)
        toolbar.insertItem(withItemIdentifier: .init("video"), at: 1)
        return toolbar
    }

    func applicationWillTerminate(_ notification: Notification) {
        historyTimer?.invalidate()
        manager.pauseAll()
        manager.saveHistory()
        DownloadServices.shared.updateSleep(active: false)
        ExtensionServer.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Toolbar with the Add Download and Add Video buttons.
@MainActor
final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    let addAction: () -> Void
    let videoAction: () -> Void
    private var keeper: AddButtonController?
    private var videoKeeper: AddButtonController?

    init(addAction: @escaping () -> Void, videoAction: @escaping () -> Void) {
        self.addAction = addAction
        self.videoAction = videoAction
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id.rawValue {
        case "add":
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Add Download"
            item.paletteLabel = "Add Download"
            let ctrl = AddButtonController(action: addAction, title: " Add Download", symbol: "plus")
            keeper = ctrl
            item.view = ctrl.makeButton()
            return item
        case "video":
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Add Video"
            item.paletteLabel = "Add Video"
            let ctrl = AddButtonController(action: videoAction, title: " Add Video", symbol: "video")
            videoKeeper = ctrl
            item.view = ctrl.makeButton()
            return item
        default:
            return nil
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add"), .init("video")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add"), .init("video")] }
}

/// Retains a toolbar button and fires its action.
@MainActor
final class AddButtonController {
    let action: () -> Void
    let title: String
    let symbol: String
    init(action: @escaping () -> Void, title: String = " Add Download", symbol: String = "plus") {
        self.action = action
        self.title = title
        self.symbol = symbol
    }

    func makeButton() -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(fire))
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.controlSize = .large
        button.focusRingType = .none
        return button
    }

    @objc func fire() { action() }
}
