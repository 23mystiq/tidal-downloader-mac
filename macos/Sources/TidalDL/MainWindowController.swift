import AppKit

private extension NSToolbarItem.Identifier {
    static let searchType = Self("searchType")
    static let search = Self("search")
    static let download = Self("download")
    static let audioQuality = Self("audioQuality")
    static let videoQuality = Self("videoQuality")
}

final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let results = ResultsViewController()
    let inspector = InspectorViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "MainSplit"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: results)
        contentItem.minimumThickness = 440
        contentItem.automaticallyAdjustsSafeAreaInsets = true
        contentItem.addTopAlignedAccessoryViewController(results.filterBar)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 270
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true

        [sidebarItem, contentItem, inspectorItem].forEach(addSplitViewItem)
    }
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let split = MainSplitViewController()
    private var searchItem: NSSearchToolbarItem?
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var audioItem: NSMenuToolbarItem?
    private var videoItem: NSMenuToolbarItem?
    private static let searchTypes = ["Artist", "Album", "Track", "Video", "Playlist"]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "TIDAL Downloader"
        window.minSize = NSSize(width: 980, height: 600)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1360, height: 840))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .searchType, .search, .flexibleSpace,
         .audioQuality, .videoQuality, .download, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search TIDAL or paste a link"
            item.searchField.sendsWholeSearchString = true
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.target = self
            item.searchField.action = #selector(search(_:))
            item.preferredWidthForSearchField = 300
            item.resignsFirstResponderWithCancel = true
            item.label = "Search"
            searchItem = item
            return item

        case .searchType:
            let item = NSToolbarItem(itemIdentifier: id)
            typePopup.removeAllItems()
            for type in Self.searchTypes {
                typePopup.addItem(withTitle: type + "s")
                typePopup.lastItem?.representedObject = type
            }
            typePopup.selectItem(at: 2)  // Track, as in the Qt GUI.
            typePopup.toolTip = "What to search for"
            typePopup.target = self
            typePopup.action = #selector(searchTypeChanged)
            item.view = typePopup
            item.label = "Search For"
            return item

        case .download:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage.symbol("arrow.down", 14, weight: .semibold)
            item.label = "Download"
            item.toolTip = "Download the selected results (⌘D)"
            item.target = split.results
            item.action = #selector(ResultsViewController.downloadSelected)
            item.isBordered = true
            item.style = .prominent
            return item

        case .audioQuality:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage.symbol("waveform", 13, weight: .medium)
            item.label = "Audio Quality"
            item.toolTip = "Audio download quality"
            item.showsIndicator = true
            audioItem = item
            rebuildQualityMenus()
            return item

        case .videoQuality:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage.symbol("film", 13, weight: .medium)
            item.label = "Video Quality"
            item.toolTip = "Video download quality"
            item.showsIndicator = true
            videoItem = item
            rebuildQualityMenus()
            return item

        default:
            return nil
        }
    }

    @objc private func search(_ sender: NSSearchField) {
        let type = typePopup.selectedItem?.representedObject as? String ?? "Track"
        AppState.shared.results.search(sender.stringValue, type: type)
    }

    @objc private func searchTypeChanged() {
        guard let field = searchItem?.searchField, !field.stringValue.isEmpty else { return }
        search(field)
    }

    func focusSearch() {
        searchItem?.beginSearchInteraction()
    }

    // MARK: Quality menus (ports of `on_quality_set_audio` / `on_quality_set_video`)

    @objc private func settingsChanged() { rebuildQualityMenus() }

    private func rebuildQualityMenus() {
        guard let settings = AppState.shared.settings else {
            audioItem?.isEnabled = false
            videoItem?.isEnabled = false
            return
        }
        if let audioItem {
            let current = settings.string("quality_audio")
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: "Audio Quality"))
            for option in settings.options["quality_audio"] ?? [] {
                let (title, detail) = Fmt.audioOption(option.value)
                let item = NSMenuItem(title: title, action: #selector(pickQuality(_:)), keyEquivalent: "")
                item.subtitle = detail
                item.target = self
                item.representedObject = ["quality_audio", option.value]
                item.state = option.value == current ? .on : .off
                menu.addItem(item)
            }
            if !AppState.shared.isPkce, AppState.shared.loggedIn {
                menu.addItem(.separator())
                let note = NSMenuItem(title: "Lossless needs the browser sign-in…", action: #selector(AppDelegate.signInForLossless(_:)), keyEquivalent: "")
                note.image = NSImage.symbol("exclamationmark.triangle")
                menu.addItem(note)
            }
            audioItem.menu = menu
            audioItem.title = Fmt.audioOption(current).title
            audioItem.isEnabled = true
        }
        if let videoItem {
            let current = settings.string("quality_video")
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: "Video Quality"))
            for option in settings.options["quality_video"] ?? [] {
                let item = NSMenuItem(title: Fmt.videoOption(option.value), action: #selector(pickQuality(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["quality_video", option.value]
                item.state = option.value == current ? .on : .off
                menu.addItem(item)
            }
            videoItem.menu = menu
            videoItem.title = Fmt.videoOption(current)
            videoItem.isEnabled = true
        }
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        AppState.shared.updateSettings([pair[0]: pair[1]])
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
