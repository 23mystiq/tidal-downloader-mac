import AppKit

enum ResultColumn: String, CaseIterable {
    case position, art, title, artist, album, duration, quality, added

    var title: String {
        switch self {
        case .position: "#"
        case .art: ""
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .duration: "Time"
        case .quality: "Quality"
        case .added: "Date Added"
        }
    }

    var width: (CGFloat, CGFloat, CGFloat) {  // ideal, min, max
        switch self {
        case .position: (58, 44, 120)
        case .art: (34, 34, 34)
        case .title: (280, 100, 1000)
        case .artist: (200, 80, 800)
        case .album: (220, 80, 800)
        case .duration: (64, 50, 100)
        case .quality: (86, 70, 140)
        case .added: (130, 90, 200)
        }
    }

    var filterable: Bool { self != .art }

    /// Columns hidden while every loaded row leaves them empty.
    var hidesWhenEmpty: Bool { [.title, .album, .duration, .quality, .added].contains(self) }

    func text(_ node: ResultNode) -> String {
        switch self {
        case .position: "\(node.position + 1)"
        case .art: ""
        case .title: node.title
        case .artist: node.artist
        case .album: node.album
        case .duration: Fmt.duration(node.duration)
        case .quality: Fmt.quality(node.quality)
        case .added: node.added
        }
    }

    /// Text the column filter matches against (the visible text plus TIDAL's raw value).
    func filterText(_ node: ResultNode) -> String {
        self == .quality ? "\(Fmt.quality(node.quality)) \(node.quality)" : text(node)
    }
}

final class ResultsOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?
    var onReturn: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn { return onReturn() }
        super.keyDown(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

final class ResultsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = ResultsOutlineView()
    let filterBar = FilterBarController()
    private let scroll = NSScrollView()
    private let emptyState = EmptyStateView()
    private let spinner = NSProgressIndicator()
    private let hud = ProgressHUD()
    private var model: ResultsModel { AppState.shared.results }

    private var filters: [ResultColumn: NSRegularExpression] = [:]
    private var rawFilters: [ResultColumn: String] = [:]
    private var visibleRoots: [ResultNode] = []
    private var visibleChildren: [ObjectIdentifier: [ResultNode]] = [:]
    private var pendingCover: DispatchWorkItem?
    private var hudHideWork: DispatchWorkItem?

    override func loadView() {
        view = NSView()

        for column in ResultColumn.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            (tableColumn.width, tableColumn.minWidth, tableColumn.maxWidth) = column.width
            if column == .art {
                tableColumn.resizingMask = []
            } else {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            if column == .position || column == .duration {
                tableColumn.headerCell.alignment = .right
            }
            outline.addTableColumn(tableColumn)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.indentationPerLevel = 14
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.rowHeight = 34
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClick)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.autosaveName = "ResultsTable"
        outline.autosaveTableColumns = true
        outline.onCopy = { [weak self] in self?.copyShareURLs(self?.selectedNodes() ?? []) }
        outline.onReturn = { [weak self] in self?.downloadSelected() }
        outline.setAccessibilityLabel("Results")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.addSubview(scroll)
        scroll.pin(to: view)

        view.addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        hud.alphaValue = 0
        hud.isHidden = true
        view.addSubview(hud)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            spinner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            hud.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            hud.widthAnchor.constraint(equalToConstant: 460),
            hud.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
        ])

        filterBar.outline = outline
        filterBar.onChange = { [weak self] column, text in self?.setFilter(column, text) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resultsReset), name: .resultsReset, object: nil)
        center.addObserver(self, selector: #selector(resultsAppended), name: .resultsAppended, object: nil)
        center.addObserver(self, selector: #selector(loadingChanged), name: .resultsLoadingChanged, object: nil)
        center.addObserver(self, selector: #selector(downloadsChanged), name: .queueItemChanged, object: nil)
        center.addObserver(self, selector: #selector(downloadsChanged), name: .queueChanged, object: nil)
        center.addObserver(self, selector: #selector(downloadsChanged), name: .queueRunningChanged, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: .progressChanged, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: .statusChanged, object: nil)

        updateChrome()
        updateColumnVisibility()
    }

    // MARK: Model → view

    @objc private func resultsReset() {
        visibleRoots = []
        visibleChildren.removeAll()
        outline.reloadData()
        outline.scrollRowToVisible(0)
        updateChrome()
    }

    @objc private func resultsAppended() {
        rebuild()
        updateColumnVisibility()
        updateChrome()
    }

    @objc private func loadingChanged() { updateChrome() }

    private func updateChrome() {
        let empty = model.roots.isEmpty
        let loading = model.isLoading
        loading && empty ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        emptyState.isHidden = !empty || loading
        emptyState.showNoResults = !model.title.isEmpty
        var parts: [String] = []
        if !model.title.isEmpty { parts.append(model.title) }
        if loading { parts.append(empty ? "Loading…" : "\(model.roots.count) items, loading…") }
        else if !model.title.isEmpty { parts.append(model.roots.count == 1 ? "1 item" : "\(model.roots.count) items") }
        view.window?.subtitle = parts.joined(separator: " · ")
    }

    private func rebuild() {
        let selected = selectedNodes()
        visibleChildren.removeAll()
        visibleRoots = arrange(model.roots)
        outline.reloadData()
        restoreSelection(selected)
    }

    private func restoreSelection(_ nodes: [ResultNode]) {
        guard !nodes.isEmpty else { return }
        let rows = IndexSet(nodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: Sorting & filtering (ports of HumanProxyModel)

    private func arrange(_ nodes: [ResultNode]) -> [ResultNode] {
        var result = nodes
        if let descriptor = outline.sortDescriptors.first, let key = descriptor.key, let column = ResultColumn(rawValue: key) {
            result.sort { a, b in
                let order: ComparisonResult
                switch column {
                case .position: order = a.position == b.position ? .orderedSame : (a.position < b.position ? .orderedAscending : .orderedDescending)
                case .duration: order = a.duration == b.duration ? .orderedSame : (a.duration < b.duration ? .orderedAscending : .orderedDescending)
                default: order = column.text(a).localizedStandardCompare(column.text(b))
                }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        guard !filters.isEmpty else { return result }
        return result.filter(include)
    }

    /// A row stays if it matches every column filter, or if any of its loaded children stays.
    private func include(_ node: ResultNode) -> Bool {
        if let children = node.children, children.contains(where: include) { return true }
        for (column, regex) in filters {
            let text = column.filterText(node)
            if text.isEmpty || regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return false }
        }
        return true
    }

    private func children(of node: ResultNode) -> [ResultNode]? {
        guard let children = node.children else { return nil }
        let key = ObjectIdentifier(node)
        if let cached = visibleChildren[key] { return cached }
        let arranged = arrange(children)
        visibleChildren[key] = arranged
        return arranged
    }

    private func setFilter(_ column: ResultColumn, _ text: String) {
        rawFilters[column] = text
        if text.isEmpty {
            filters[column] = nil
        } else {
            filters[column] = (try? NSRegularExpression(pattern: text, options: [.caseInsensitive, .anchorsMatchLines]))
                ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: text), options: .caseInsensitive))
        }
        rebuild()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuild()
    }

    private func updateColumnVisibility() {
        var filled = Set<ResultColumn>()
        func scan(_ nodes: [ResultNode]) {
            for node in nodes {
                for column in ResultColumn.allCases where column.hidesWhenEmpty && !filled.contains(column) {
                    if !column.text(node).isEmpty { filled.insert(column) }
                }
                if let children = node.children { scan(children) }
            }
        }
        scan(model.roots)
        let showAll = model.roots.isEmpty
        for column in ResultColumn.allCases where column.hidesWhenEmpty {
            let hidden = !showAll && !filled.contains(column)
            outline.tableColumn(withIdentifier: .init(column.rawValue))?.isHidden = hidden
        }
        filterBar.layoutFields()
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ResultNode else { return item == nil ? visibleRoots.count : 0 }
        return children(of: node)?.count ?? 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ResultNode else { return visibleRoots[index] }
        guard let children = children(of: node) else { return LoadingNode.shared }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ResultNode)?.expandable ?? false
    }

    /// Port of `on_tr_results_expanded`: children load the first time a row opens.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? ResultNode else { return false }
        if node.children == nil {
            model.loadChildren(of: node) { [weak self] in
                guard let self else { return }
                if self.filters.isEmpty {
                    self.visibleChildren[ObjectIdentifier(node)] = nil
                    self.outline.reloadItem(node, reloadChildren: true)
                } else {
                    self.rebuild()
                }
                self.updateColumnVisibility()
            }
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = ResultColumn(rawValue: id) else { return nil }

        if item is LoadingNode {
            guard column == .title else { return nil }
            let cell = outlineView.makeView(withIdentifier: .init("loading"), owner: nil) as? LoadingCell ?? LoadingCell()
            cell.spinner.startAnimation(nil)
            return cell
        }
        guard let node = item as? ResultNode else { return nil }

        switch column {
        case .art:
            let cell = outlineView.makeView(withIdentifier: .init("art"), owner: nil) as? ArtCell ?? ArtCell()
            cell.configure(node)
            return cell
        case .title:
            let cell = outlineView.makeView(withIdentifier: .init("titleCell"), owner: nil) as? TitleCell ?? TitleCell()
            cell.configure(node)
            return cell
        case .quality:
            let cell = outlineView.makeView(withIdentifier: .init("quality"), owner: nil) as? QualityCell ?? QualityCell()
            cell.configure(node.quality)
            return cell
        default:
            let identifier = NSUserInterfaceItemIdentifier("text-\(column.rawValue)")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TextCell ?? TextCell(column: column)
            cell.identifier = identifier
            cell.textField?.stringValue = column.text(node)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ResultNode }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Port of `on_result_item_clicked`: show the selected item's cover.
        pendingCover?.cancel()
        guard let node = outline.item(atRow: outline.selectedRow) as? ResultNode else { return }
        let work = DispatchWorkItem {
            AppState.shared.showCover(url: node.cover, placeholder: node.thumb, title: node.displayName, subtitle: node.displaySubtitle)
        }
        pendingCover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    @objc private func doubleClick() {
        guard let node = outline.item(atRow: outline.clickedRow) as? ResultNode, node.expandable else { return }
        outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
    }

    // MARK: Actions

    func selectedNodes() -> [ResultNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ResultNode }
    }

    /// Port of `on_download_results`.
    @objc func downloadSelected() {
        AppState.shared.download(handles: selectedNodes().map(\.handle))
    }

    private func copyShareURLs(_ nodes: [ResultNode]) {
        guard !nodes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.share).joined(separator: "\n"), forType: .string)
    }

    private func contextNodes() -> [ResultNode] {
        let row = outline.clickedRow
        guard row >= 0 else { return [] }
        if outline.selectedRowIndexes.contains(row) { return selectedNodes() }
        return (outline.item(atRow: row) as? ResultNode).map { [$0] } ?? []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = contextNodes()
        guard !nodes.isEmpty else { return }
        let download = NSMenuItem(title: nodes.count == 1 ? "Download" : "Download \(nodes.count) Items", action: #selector(menuDownload(_:)), keyEquivalent: "")
        download.image = NSImage.symbol("arrow.down.circle")
        let copy = NSMenuItem(title: nodes.count == 1 ? "Copy Share URL" : "Copy Share URLs", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copy.image = NSImage.symbol("link")
        for item in [download, copy] {
            item.target = self
            item.representedObject = nodes
            menu.addItem(item)
        }
    }

    @objc private func menuDownload(_ sender: NSMenuItem) {
        AppState.shared.download(handles: (sender.representedObject as? [ResultNode] ?? []).map(\.handle))
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        copyShareURLs(sender.representedObject as? [ResultNode] ?? [])
    }

    func focusFilters() { filterBar.focusFirst() }

    // MARK: Download HUD

    @objc private func downloadsChanged() { progressChanged() }

    @objc private func progressChanged() {
        let state = AppState.shared
        let active = state.isDownloading
        hud.update(state)
        if active {
            hudHideWork?.cancel()
            hudHideWork = nil
            setHUD(visible: true)
        } else if !hud.isHidden, hudHideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.hudHideWork = nil
                self?.setHUD(visible: false)
            }
            hudHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func setHUD(visible: Bool) {
        guard visible == hud.isHidden || (visible && hud.alphaValue < 1) else { return }
        if visible { hud.isHidden = false }
        view.additionalSafeAreaInsets.bottom = visible ? hud.fittingSize.height + 24 : 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            hud.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.hud.isHidden = true }
        })
    }
}

// MARK: - Filter bar

final class FilterBarController: NSSplitViewItemAccessoryViewController, NSSearchFieldDelegate {
    weak var outline: NSOutlineView? {
        didSet { observeOutline() }
    }
    var onChange: ((ResultColumn, String) -> Void)?
    private var fields: [ResultColumn: NSSearchField] = [:]
    private var pending: [ResultColumn: DispatchWorkItem] = [:]

    override func loadView() {
        let bar = FilterBarView()
        bar.onLayout = { [weak self] in self?.layoutFields() }
        view = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 34).isActive = true

        for column in ResultColumn.allCases where column.filterable {
            let field = NSSearchField()
            field.controlSize = .small
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.placeholderString = column == .position ? "#" : "Filter \(column.title.lowercased())"
            field.sendsSearchStringImmediately = true
            field.sendsWholeSearchString = false
            field.delegate = self
            field.identifier = .init(column.rawValue)
            field.toolTip = "Filter \(column.title) (regular expressions work; case-insensitive)"
            (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
            bar.addSubview(field)
            fields[column] = field
        }
    }

    private func observeOutline() {
        guard let outline else { return }
        let center = NotificationCenter.default
        for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            center.addObserver(self, selector: #selector(outlineChanged), name: name, object: outline)
        }
        if let clip = outline.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(outlineChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func outlineChanged() { layoutFields() }

    func layoutFields() {
        guard let outline, isViewLoaded else { return }
        let height: CGFloat = 22
        for (column, field) in fields {
            let index = outline.column(withIdentifier: .init(column.rawValue))
            guard index >= 0, !outline.tableColumns[index].isHidden else {
                field.isHidden = true
                continue
            }
            let rect = outline.rect(ofColumn: index)
            let inWindow = outline.convert(rect, to: nil)
            let local = view.convert(inWindow, from: nil)
            let inset: CGFloat = column == outline.outlineTableColumn.flatMap({ ResultColumn(rawValue: $0.identifier.rawValue) }) ? 4 : 2
            field.isHidden = local.width < 30
            field.frame = NSRect(x: local.minX + inset, y: (view.bounds.height - height) / 2, width: max(0, local.width - inset * 2), height: height)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              let column = ResultColumn(rawValue: field.identifier?.rawValue ?? "") else { return }
        pending[column]?.cancel()
        let text = field.stringValue
        let work = DispatchWorkItem { [weak self] in self?.onChange?(column, text) }
        pending[column] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func focusFirst() {
        let first = ResultColumn.allCases.first { fields[$0]?.isHidden == false && $0 != .position }
        if let first, let field = fields[first] { view.window?.makeFirstResponder(field) }
    }
}

private final class FilterBarView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Cells

private final class TextCell: NSTableCellView {
    init(column: ResultColumn) {
        super.init(frame: .zero)
        let label = NSTextField.label(size: 13, color: column == .artist || column == .album ? .labelColor : .secondaryLabelColor)
        if column == .position || column == .duration {
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        if column == .added { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class TitleCell: NSTableCellView {
    private let label = NSTextField.label(size: 13, weight: .medium)
    private let badge = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = .init("titleCell")
        badge.image = NSImage.symbol("e.square.fill", 11)
        badge.contentTintColor = .tertiaryLabelColor
        badge.toolTip = "Explicit"
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, badge])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: ResultNode) {
        label.stringValue = node.title
        badge.isHidden = !node.explicit || node.title.isEmpty
    }
}

private final class ArtCell: NSTableCellView {
    private let art = ArtworkView(size: 26, radius: 4)

    init() {
        super.init(frame: .zero)
        identifier = .init("art")
        addSubview(art)
        NSLayoutConstraint.activate([
            art.centerXAnchor.constraint(equalTo: centerXAnchor),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: ResultNode) {
        art.layer?.cornerRadius = node.kind == "Artist" ? 13 : 4
        art.placeholderSymbol = switch node.kind {
        case "Video": "play.rectangle"
        case "Album": "square.stack"
        case "Artist": "music.microphone"
        case "Playlist": "music.note.list"
        case "Mix": "waveform"
        default: "music.note"
        }
        art.set(node.thumb)
    }
}

private final class QualityCell: NSTableCellView {
    private let badge = NSTextField.label(size: 10, weight: .semibold)
    private let background = NSView()

    init() {
        super.init(frame: .zero)
        identifier = .init("quality")
        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        background.layer?.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            background.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -5),
            background.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 5),
            background.topAnchor.constraint(equalTo: badge.topAnchor, constant: -2),
            background.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ raw: String) {
        let text = Fmt.quality(raw)
        badge.stringValue = text.uppercased()
        badge.toolTip = raw
        let color = Fmt.qualityColor(raw)
        badge.textColor = color
        background.isHidden = text.isEmpty
        background.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let raw = badge.toolTip { configure(raw) }
    }
}

private final class LoadingCell: NSTableCellView {
    let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = .init("loading")
        spinner.style = .spinning
        spinner.controlSize = .small
        let label = NSTextField.label("Loading…", size: 12, color: .secondaryLabelColor)
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Empty state

private final class EmptyStateView: NSStackView {
    private let icon = NSImageView()
    private let title = NSTextField.label(size: 17, weight: .semibold)
    private let subtitle = NSTextField.label(size: 13, color: .secondaryLabelColor)

    var showNoResults = false {
        didSet { update() }
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 8
        icon.contentTintColor = .tertiaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.preferredMaxLayoutWidth = 360
        addArrangedSubview(icon)
        setCustomSpacing(14, after: icon)
        addArrangedSubview(title)
        addArrangedSubview(subtitle)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        icon.image = NSImage.symbol(showNoResults ? "music.note.list" : "magnifyingglass", 40, weight: .light)
        title.stringValue = showNoResults ? "Nothing Here" : "Search TIDAL"
        subtitle.stringValue = showNoResults
            ? "No items were found. Try another search or a different type."
            : "Find artists, albums, tracks, videos and playlists, or paste a TIDAL link. Pick a list on the left to see what’s inside."
    }
}

// MARK: - Progress HUD

private final class ProgressHUD: NSGlassEffectView {
    private let icon = NSImageView()
    private let heading = NSTextField.label(size: 12, weight: .semibold)
    private let status = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private let listRow = BarRow()
    private let itemRow = BarRow()
    private var pulsing = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = 20
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [icon, heading, NSView(), status])
        header.spacing = 6
        let stack = NSStackView(views: [header, listRow, itemRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        [header, listRow, itemRow].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        contentView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ state: AppState) {
        let paused = !state.queueRunning
        heading.stringValue = paused ? "Paused" : "Downloading"
        icon.image = NSImage.symbol(paused ? "pause.circle.fill" : "arrow.down.circle.fill", 14, weight: .semibold)
        icon.contentTintColor = paused ? .systemYellow : .controlAccentColor
        let waiting = state.queue.filter { $0.status == "waiting" }.count
        status.stringValue = [state.statusMessage, waiting > 0 ? "\(waiting) waiting" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        listRow.isHidden = state.listProgress.value <= 0 || state.listProgress.name.isEmpty
        listRow.update(state.listProgress, symbol: "music.note.list")
        itemRow.update(state.itemProgress, symbol: "music.note")
        let shouldPulse = !paused && state.isDownloading
        if shouldPulse != pulsing {
            pulsing = shouldPulse
            shouldPulse ? icon.addSymbolEffect(.pulse) : icon.removeAllSymbolEffects()
        }
    }
}

private final class BarRow: NSStackView {
    private let icon = NSImageView()
    private let name = NSTextField.label(size: 11)
    private let bar = NSProgressIndicator()
    private let percent = NSTextField.label(size: 11, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        spacing = 8
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.widthAnchor.constraint(equalToConstant: 150).isActive = true
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 36).isActive = true
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [icon, name, bar, percent].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ progress: ProgressState, symbol: String) {
        icon.image = NSImage.symbol(symbol, 11)
        name.stringValue = progress.name
        bar.doubleValue = progress.value
        percent.stringValue = "\(Int(progress.value.rounded(.up)))%"
    }
}
