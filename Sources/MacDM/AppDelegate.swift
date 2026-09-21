import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let manager = DownloadManager()
    var sidebar: CategorySidebar!
    var content: DownloadsContentController!
    var statusBar: StatusBarController!
    var addPanelController: AddPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        content = DownloadsContentController(manager: manager)
        sidebar = CategorySidebar(manager: manager) { [weak self] category in
            self?.content.show(category: category)
        }
        content.onAdd = { [weak self] in
            guard let w = self?.window else { return }
            self?.addPanelController.present(on: w)
        }
        addPanelController = AddPanelController(manager: manager)
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
            self?.content.reload()
            self?.sidebar.reload()
            self?.statusBar.refresh()
        }

        // README/screenshot helpers: `--demo` and `--snapshot out.png`
        Snapshotter.runIfNeeded(window: window, manager: manager)
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar()
        toolbar.delegate = ToolbarDelegate(addAction: { [weak self] in
            guard let w = self?.window else { return }
            self?.addPanelController.present(on: w)
        })
        toolbar.displayMode = .iconOnly
        toolbar.insertItem(withItemIdentifier: .init("add"), at: 0)
        return toolbar
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Toolbar with a prominent Add Download button.
@MainActor
final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    let addAction: () -> Void
    private var keeper: AddButtonController?

    init(addAction: @escaping () -> Void) { self.addAction = addAction }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id.rawValue == "add" else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Add Download"
        item.paletteLabel = "Add Download"
        let ctrl = AddButtonController(action: addAction)
        keeper = ctrl
        item.view = ctrl.makeButton()
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add")] }
}

/// Retains the Add button and fires its action.
@MainActor
final class AddButtonController {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }

    func makeButton() -> NSButton {
        let button = NSButton(title: " Add Download", target: self, action: #selector(fire))
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.controlSize = .large
        button.focusRingType = .none
        return button
    }

    @objc func fire() { action() }
}
