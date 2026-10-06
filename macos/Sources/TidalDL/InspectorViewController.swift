import AppKit

final class InspectorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let cover = CoverView()
    private let coverTitle = NSTextField.label(size: 13, weight: .semibold)
    private let coverSubtitle = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private let queueTitle = NSTextField.label("Downloads", size: 13, weight: .semibold)
    private let queueCount = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private let toggleButton = glassButton(symbol: "pause.fill", tooltip: "Pause downloads", target: nil, action: #selector(toggleQueue))
    private let removeButton = glassButton(symbol: "minus", tooltip: "Remove selected from queue (⌫)", target: nil, action: #selector(removeSelected))
    private let clearFinishedButton = glassButton(symbol: "checkmark.circle", tooltip: "Clear finished", target: nil, action: #selector(clearFinished))
    private let clearAllButton = glassButton(symbol: "trash", tooltip: "Clear all (keeps the running download)", target: nil, action: #selector(clearAll))
    private let queueTable = QueueTableView()
    private let queueEmpty = NSTextField.label("Nothing queued yet", size: 12, color: .tertiaryLabelColor)
    private let logToggle = NSButton()
    private let logText = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeight: NSLayoutConstraint!
    private var logVisible = UserDefaults.standard.object(forKey: "LogVisible") as? Bool ?? true

    override func loadView() {
        view = NSView()

        // Cover
        coverTitle.alignment = .center
        coverSubtitle.alignment = .center
        coverTitle.maximumNumberOfLines = 2
        coverTitle.lineBreakMode = .byWordWrapping

        // Queue header
        [toggleButton, removeButton, clearFinishedButton, clearAllButton].forEach {
            $0.target = self
            $0.controlSize = .small
        }
        let titles = NSStackView(views: [queueTitle, queueCount])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        let header = NSStackView(views: [titles, NSView(), toggleButton, removeButton, clearFinishedButton, clearAllButton])
        header.spacing = 4

        // Queue table
        let column = NSTableColumn(identifier: .init("queue"))
        queueTable.addTableColumn(column)
        queueTable.headerView = nil
        queueTable.style = .inset
        queueTable.rowHeight = 46
        queueTable.allowsMultipleSelection = true
        queueTable.backgroundColor = .clear
        queueTable.dataSource = self
        queueTable.delegate = self
        queueTable.onDelete = { [weak self] in self?.removeSelected() }
        queueTable.setAccessibilityLabel("Download queue")
        let queueScroll = NSScrollView()
        queueScroll.documentView = queueTable
        queueScroll.drawsBackground = false
        queueScroll.hasVerticalScroller = true
        queueScroll.autohidesScrollers = true
        queueScroll.translatesAutoresizingMaskIntoConstraints = false
        queueEmpty.alignment = .center

        // Log
        logToggle.bezelStyle = .disclosure
        logToggle.setButtonType(.pushOnPushOff)
        logToggle.title = ""
        logToggle.state = logVisible ? .on : .off
        logToggle.target = self
        logToggle.action = #selector(toggleLog)
        let logLabel = NSTextField.label("Log", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let logClear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        logClear.controlSize = .mini
        logClear.bezelStyle = .glass
        let logHeader = NSStackView(views: [logToggle, logLabel, NSView(), logClear])
        logHeader.spacing = 4

        logText.isEditable = false
        logText.isRichText = true
        logText.drawsBackground = false
        logText.textContainerInset = NSSize(width: 4, height: 4)
        logText.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logText.isVerticallyResizable = true
        logText.autoresizingMask = [.width]
        logText.textContainer?.widthTracksTextView = true
        logScroll.documentView = logText
        logScroll.drawsBackground = false
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 8
        logScroll.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor

        for v in [cover, coverTitle, coverSubtitle, header, queueScroll, queueEmpty, logHeader, logScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        let guide = view.safeAreaLayoutGuide
        logHeight = logScroll.heightAnchor.constraint(equalToConstant: logVisible ? 150 : 0)
        let coverWidth = cover.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        coverWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            cover.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            coverWidth,
            cover.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),
            coverTitle.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 10),
            coverTitle.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            coverTitle.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            coverSubtitle.topAnchor.constraint(equalTo: coverTitle.bottomAnchor, constant: 2),
            coverSubtitle.leadingAnchor.constraint(equalTo: coverTitle.leadingAnchor),
            coverSubtitle.trailingAnchor.constraint(equalTo: coverTitle.trailingAnchor),

            header.topAnchor.constraint(equalTo: coverSubtitle.bottomAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),

            queueScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            queueScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            queueScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            queueEmpty.centerXAnchor.constraint(equalTo: queueScroll.centerXAnchor),
            queueEmpty.centerYAnchor.constraint(equalTo: queueScroll.centerYAnchor),

            logHeader.topAnchor.constraint(equalTo: queueScroll.bottomAnchor, constant: 6),
            logHeader.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            logHeader.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            logScroll.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 4),
            logScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            logScroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            logHeight,
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(coverChanged), name: .coverChanged, object: nil)
        center.addObserver(self, selector: #selector(queueChanged), name: .queueChanged, object: nil)
        center.addObserver(self, selector: #selector(queueItemChanged(_:)), name: .queueItemChanged, object: nil)
        center.addObserver(self, selector: #selector(runningChanged), name: .queueRunningChanged, object: nil)
        center.addObserver(self, selector: #selector(logAppended(_:)), name: .logAppended, object: nil)

        coverChanged()
        queueChanged()
        runningChanged()
        AppState.shared.logs.forEach(append)
    }

    // MARK: Cover

    @objc private func coverChanged() {
        let state = AppState.shared.cover
        cover.show(state.url, placeholder: state.placeholder)
        coverTitle.stringValue = state.title
        coverSubtitle.stringValue = state.subtitle
    }

    // MARK: Queue

    private var queue: [QueueEntry] { AppState.shared.queue }

    @objc private func queueChanged() {
        let selected = Set(queueTable.selectedRowIndexes.compactMap { $0 < queueTable.numberOfRows ? (queueTable.view(atColumn: 0, row: $0, makeIfNecessary: false) as? QueueCell)?.qid : nil })
        queueTable.reloadData()
        let rows = IndexSet(queue.enumerated().filter { selected.contains($0.element.qid) }.map(\.offset))
        queueTable.selectRowIndexes(rows, byExtendingSelection: false)
        updateQueueHeader()
    }

    @objc private func queueItemChanged(_ note: Notification) {
        guard let qid = note.userInfo?["qid"] as? Int, let row = queue.firstIndex(where: { $0.qid == qid }) else { return }
        (queueTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueCell)?.configure(queue[row])
        updateQueueHeader()
    }

    private func updateQueueHeader() {
        let total = queue.count
        let done = queue.filter { $0.status == "finished" }.count
        let failed = queue.filter { $0.status == "failed" }.count
        var parts = [total == 1 ? "1 item" : "\(total) items"]
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        queueCount.stringValue = total == 0 ? "Queue is empty" : parts.joined(separator: " · ")
        queueEmpty.isHidden = total > 0
        removeButton.isEnabled = total > 0
        clearFinishedButton.isEnabled = done > 0
        clearAllButton.isEnabled = total > 0
    }

    @objc private func runningChanged() {
        let running = AppState.shared.queueRunning
        toggleButton.image = NSImage.symbol(running ? "pause.fill" : "play.fill", 12, weight: .semibold)
        toggleButton.contentTintColor = running ? nil : .systemYellow
        toggleButton.toolTip = running ? "Pause downloads" : "Resume downloads"
        toggleButton.setAccessibilityLabel(toggleButton.toolTip)
        queueTitle.stringValue = running ? "Downloads" : "Downloads — Paused"
    }

    @objc func toggleQueue() { AppState.shared.setQueueRunning(!AppState.shared.queueRunning) }

    @objc func removeSelected() {
        AppState.shared.removeFromQueue(queueTable.selectedRowIndexes.compactMap { $0 < queue.count ? queue[$0].qid : nil })
    }

    @objc func clearFinished() { AppState.shared.clearFinished() }

    @objc func clearAll() { AppState.shared.clearAll() }

    func numberOfRows(in tableView: NSTableView) -> Int { queue.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("queueCell"), owner: nil) as? QueueCell ?? QueueCell()
        cell.configure(queue[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Port of `on_queue_download_item_clicked`.
        let row = queueTable.selectedRow
        guard row >= 0, row < queue.count else { return }
        let entry = queue[row]
        AppState.shared.showCover(url: entry.cover, placeholder: nil, title: entry.name, subtitle: entry.type)
    }

    // MARK: Log

    @objc private func toggleLog() {
        logVisible = logToggle.state == .on
        UserDefaults.standard.set(logVisible, forKey: "LogVisible")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            logHeight.animator().constant = logVisible ? 150 : 0
            view.layoutSubtreeIfNeeded()
        }
    }

    @objc private func clearLog() { logText.string = "" }

    @objc private func logAppended(_ note: Notification) {
        guard let line = note.userInfo?["line"] as? AppState.LogLine else { return }
        append(line)
    }

    private func append(_ line: AppState.LogLine) {
        guard let storage = logText.textStorage else { return }
        let color: NSColor = switch line.level {
        case "error", "critical": .systemRed
        case "warning": .systemOrange
        case "debug": .secondaryLabelColor
        default: .labelColor
        }
        let atBottom = logScroll.verticalScroller.map { $0.floatValue > 0.98 || $0.isHidden } ?? true
        storage.append(NSAttributedString(string: line.message + "\n", attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
        ]))
        if storage.length > 400_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 300_000)) }
        if atBottom { logText.scrollToEndOfDocument(nil) }
    }
}

private final class QueueTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { return onDelete?() ?? () }
        super.keyDown(with: event)
    }
}

private final class QueueCell: NSTableCellView {
    private(set) var qid = -1
    private let art = ArtworkView(size: 32, radius: 5)
    private let name = NSTextField.label(size: 12, weight: .medium)
    private let detail = NSTextField.label(size: 10.5, color: .secondaryLabelColor)
    private let status = NSImageView()
    private var statusName = ""

    init() {
        super.init(frame: .zero)
        identifier = .init("queueCell")
        name.maximumNumberOfLines = 1
        status.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [art, text, status])
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: QueueEntry) {
        qid = entry.qid
        name.stringValue = entry.name
        toolTip = entry.name
        let video = Fmt.videoOption(entry.qualityVideo)
        let audio = Fmt.audioOption(entry.qualityAudio).title
        detail.stringValue = [entry.type, entry.type == "Video" ? video : audio].joined(separator: " · ")
        art.placeholderSymbol = entry.type == "Video" ? "play.rectangle" : "music.note"
        art.set(entry.cover)

        guard entry.status != statusName else { return }
        statusName = entry.status
        status.removeAllSymbolEffects()
        let (symbol, color, label): (String, NSColor, String) = switch entry.status {
        case "downloading": ("arrow.down.circle.fill", .controlAccentColor, "Downloading")
        case "finished": ("checkmark.circle.fill", .systemGreen, "Finished")
        case "failed": ("exclamationmark.circle.fill", .systemRed, "Failed")
        case "skipped": ("arrow.uturn.forward.circle.fill", .systemOrange, "Skipped (already downloaded)")
        default: ("clock", .tertiaryLabelColor, "Waiting")
        }
        status.image = NSImage.symbol(symbol, 15, weight: .medium)
        status.contentTintColor = color
        status.toolTip = label
        status.setAccessibilityLabel(label)
        if entry.status == "downloading" { status.addSymbolEffect(.pulse) }
    }
}

private final class CoverView: NSView {
    private let imageView = NSImageView()
    private var current: URL?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .tertiaryLabelColor
        addSubview(imageView)
        imageView.pin(to: self)
        showPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showPlaceholder() {
        imageView.imageScaling = .scaleNone
        imageView.image = NSImage.symbol("music.note", 54, weight: .ultraLight)
    }

    /// Shows the small cached thumbnail instantly, then swaps in the full-size cover.
    func show(_ url: URL?, placeholder: URL?) {
        guard url != current else { return }
        current = url
        let size: CGFloat = 340
        if let full = ImageLoader.shared.cached(url, pointSize: size) {
            set(full, animated: false)
            return
        }
        if let thumb = ImageLoader.shared.cached(placeholder, pointSize: 26) ?? ImageLoader.shared.cached(placeholder, pointSize: 24) {
            set(thumb, animated: false)
        }
        ImageLoader.shared.load(url, pointSize: size) { [weak self] image in
            guard let self, self.current == url, let image else { return }
            self.set(image, animated: true)
        }
    }

    private func set(_ image: NSImage, animated: Bool) {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if animated {
            let transition = CATransition()
            transition.duration = 0.18
            transition.type = .fade
            imageView.layer?.add(transition, forKey: "fade")
        }
        imageView.image = image
    }
}
