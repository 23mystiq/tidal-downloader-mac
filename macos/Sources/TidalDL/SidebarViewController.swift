import AppKit

private final class Section {
    let title: String
    var entries: [ListEntry] = []

    init(_ title: String) { self.title = title }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let playlists = Section("Playlists")
    private let mixes = Section("Mixes")
    private let favorites = Section("Favorites")
    private var sections: [Section] { [playlists, mixes, favorites] }
    private let reloadButton = NSButton()
    private let downloadButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var pendingShow: DispatchWorkItem?

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.autosaveExpandedItems = false
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityLabel("Your lists")

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.addSubview(scroll)

        reloadButton.image = NSImage.symbol("arrow.clockwise", 13, weight: .medium)
        reloadButton.bezelStyle = .glass
        reloadButton.borderShape = .circle
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.toolTip = "Reload lists (⌘R)"
        reloadButton.setAccessibilityLabel("Reload lists")

        downloadButton.title = "Download List"
        downloadButton.image = NSImage.symbol("arrow.down", 12, weight: .semibold)
        downloadButton.imagePosition = .imageLeading
        downloadButton.bezelStyle = .glass
        downloadButton.borderShape = .capsule
        downloadButton.target = self
        downloadButton.action = #selector(downloadSelectedLists)
        downloadButton.toolTip = "Download the selected playlists and mixes (⇧⌘D)"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let footer = NSStackView(views: [reloadButton, spinner, NSView(), downloadButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(listsChanged), name: .listsChanged, object: nil)
        center.addObserver(self, selector: #selector(loadingChanged), name: .listsLoadingChanged, object: nil)
        listsChanged()
        loadingChanged()
    }

    @objc private func listsChanged() {
        let state = AppState.shared
        playlists.entries = state.playlists
        mixes.entries = state.mixes
        favorites.entries = state.favorites
        outline.reloadData()
        sections.forEach { outline.expandItem($0) }
    }

    @objc private func loadingChanged() {
        let loading = AppState.shared.listsLoading
        reloadButton.isEnabled = !loading
        loading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        reloadButton.toolTip = loading ? "Reloading…" : "Reload lists (⌘R)"
        outline.reloadItem(playlists)
    }

    @objc func reload() { AppState.shared.reloadLists() }

    /// Port of `on_download_list_media`: every selected list goes to the queue.
    @objc func downloadSelectedLists() {
        let entries = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ListEntry }
        guard !entries.isEmpty else {
            AppState.shared.log("error", "Please select a mix or playlist first.")
            return
        }
        AppState.shared.download(handles: entries.map(\.handle))
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.entries.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! Section).entries[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ListEntry }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let cell = outlineView.makeView(withIdentifier: .init("header"), owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = .init("header")
                let label = NSTextField.label(size: 11, weight: .semibold, color: .secondaryLabelColor)
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            var title = section.title
            if section === playlists, AppState.shared.listsLoading { title += " — Loading…" }
            else if section !== favorites, !section.entries.isEmpty { title += " (\(section.entries.count))" }
            cell.textField?.stringValue = title
            return cell
        }

        guard let entry = item as? ListEntry else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("entry"), owner: nil) as? ListCell ?? ListCell()
        cell.configure(entry)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? ListEntry)?.kind == .favorite || item is Section ? 28 : 34
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Port of `on_list_items_show`; debounced so arrowing through the list stays light.
        pendingShow?.cancel()
        guard outline.selectedRowIndexes.count == 1,
              let entry = outline.item(atRow: outline.selectedRow) as? ListEntry else { return }
        let work = DispatchWorkItem {
            AppState.shared.results.show(list: entry)
            if entry.kind != .favorite {
                AppState.shared.showCover(url: entry.cover, placeholder: entry.thumb, title: entry.name, subtitle: entry.info)
            }
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let entry = outline.item(atRow: row) as? ListEntry, entry.kind != .favorite else { return }
        let download = NSMenuItem(title: "Download Playlist", action: #selector(menuDownload(_:)), keyEquivalent: "")
        download.representedObject = entry
        download.image = NSImage.symbol("arrow.down.circle")
        let copy = NSMenuItem(title: "Copy Share URL", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copy.representedObject = entry
        copy.image = NSImage.symbol("link")
        [download, copy].forEach {
            $0.target = self
            menu.addItem($0)
        }
    }

    @objc private func menuDownload(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ListEntry else { return }
        AppState.shared.download(handles: [entry.handle])
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ListEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.share, forType: .string)
    }
}

private final class ListCell: NSTableCellView {
    private let art = ArtworkView(size: 24, radius: 5)
    private let symbolView = NSImageView()
    private let title = NSTextField.label(size: 13)

    init() {
        super.init(frame: .zero)
        identifier = .init("entry")
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentTintColor = .controlAccentColor
        addSubview(art)
        addSubview(symbolView)
        addSubview(title)
        textField = title
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: ListEntry) {
        title.stringValue = entry.name
        toolTip = entry.info.isEmpty ? entry.name : "\(entry.name)\n\(entry.info)"
        let isFavorite = entry.kind == .favorite
        art.isHidden = isFavorite
        symbolView.isHidden = !isFavorite
        if isFavorite {
            symbolView.image = NSImage.symbol(entry.symbol, 14, weight: .medium)
        } else {
            art.placeholderSymbol = entry.symbol
            art.set(entry.thumb)
        }
    }
}
