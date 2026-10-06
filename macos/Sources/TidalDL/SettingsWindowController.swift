import AppKit

/// Port of `DialogPreferences` with the same fields; changes apply as you make them.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        let pages: [(String, String, [String])] = [
            ("General", "gearshape", ["quality_audio", "quality_video", "downloads_concurrent_max", "skip_existing", "download_delay", "video_download", "video_convert_mp4", "extract_flac"]),
            ("Files", "folder", ["download_base_path", "format_album", "format_playlist", "format_mix", "format_track", "format_video", "album_track_num_pad_min", "symlink_to_track", "playlist_create", "path_binary_ffmpeg"]),
            ("Metadata", "tag", ["metadata_cover_embed", "metadata_cover_dimension", "cover_album_file", "lyrics_embed", "lyrics_file"]),
            ("Account", "person.crop.circle", []),
        ]
        for (title, symbol, keys) in pages {
            let page = keys.isEmpty ? AccountPage() as NSViewController : SettingsPage(keys: keys)
            page.title = title
            let item = NSTabViewItem(viewController: page)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum Field {
    static let labels: [String: String] = [
        "skip_existing": "Skip files that already exist",
        "lyrics_embed": "Embed lyrics",
        "lyrics_file": "Save lyrics as .lrc file",
        "video_download": "Download videos",
        "download_delay": "Randomized delay between downloads",
        "video_convert_mp4": "Convert videos to MP4",
        "extract_flac": "Extract FLAC from MP4 containers",
        "metadata_cover_embed": "Embed cover art",
        "cover_album_file": "Save cover.jpg with albums",
        "symlink_to_track": "Symlink list tracks into the Tracks folder",
        "playlist_create": "Create a playlist file for lists",
        "download_base_path": "Download folder:",
        "format_album": "Albums:",
        "format_playlist": "Playlists:",
        "format_mix": "Mixes:",
        "format_track": "Tracks:",
        "format_video": "Videos:",
        "path_binary_ffmpeg": "FFmpeg:",
        "album_track_num_pad_min": "Track number digits:",
        "downloads_concurrent_max": "Simultaneous downloads:",
        "quality_audio": "Audio quality:",
        "quality_video": "Video quality:",
        "metadata_cover_dimension": "Embedded cover size:",
    ]
    static let checkboxes: Set<String> = ["skip_existing", "lyrics_embed", "lyrics_file", "video_download", "download_delay", "video_convert_mp4", "extract_flac", "metadata_cover_embed", "cover_album_file", "symlink_to_track", "playlist_create"]
    static let combos: Set<String> = ["quality_audio", "quality_video", "metadata_cover_dimension"]
    static let steppers: Set<String> = ["album_track_num_pad_min", "downloads_concurrent_max"]
    static let paths: Set<String> = ["download_base_path", "path_binary_ffmpeg"]
}

private final class SettingsPage: NSViewController, NSTextFieldDelegate {
    private let keys: [String]
    private var controls: [String: NSControl] = [:]
    private var stepperFields: [String: NSTextField] = [:]

    init(keys: [String]) {
        self.keys = keys
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let help = AppState.shared.settings?.help ?? [:]
        for key in keys {
            let label = Field.checkboxes.contains(key) ? NSGridCell.emptyContentView : NSTextField.label(Field.labels[key] ?? key, size: 13)
            let control = makeControl(key)
            let row = grid.addRow(with: [label, control])
            row.yPlacement = .center
            row.topPadding = 6
            if let text = help[key], !text.isEmpty {
                let caption = NSTextField(wrappingLabelWithString: text)
                caption.font = .systemFont(ofSize: 11)
                caption.textColor = .secondaryLabelColor
                caption.preferredMaxLayoutWidth = 400
                caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                grid.addRow(with: [NSGridCell.emptyContentView, caption])
                (control as NSView).toolTip = text
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 400

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        view = container

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
        refresh()
    }

    private func makeControl(_ key: String) -> NSView {
        if Field.checkboxes.contains(key) {
            let box = NSButton(checkboxWithTitle: Field.labels[key] ?? key, target: self, action: #selector(checkboxChanged(_:)))
            box.identifier = .init(key)
            controls[key] = box
            return box
        }
        if Field.combos.contains(key) {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = .init(key)
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            controls[key] = popup
            return popup
        }
        if Field.steppers.contains(key) {
            let field = NSTextField()
            field.alignment = .right
            field.formatter = { let f = NumberFormatter(); f.minimum = 1; f.maximum = 99; f.allowsFloats = false; return f }()
            field.identifier = .init(key)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let stepper = NSStepper()
            stepper.minValue = 1
            stepper.maxValue = 99
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.identifier = .init(key)
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
            controls[key] = stepper
            stepperFields[key] = field
            return NSStackView(views: [field, stepper])
        }
        let field = NSTextField()
        field.identifier = .init(key)
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.font = key.hasPrefix("format_") ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 13)
        field.placeholderString = key == "path_binary_ffmpeg" ? "Uses ffmpeg from your PATH when empty" : nil
        controls[key] = field
        guard Field.paths.contains(key) else { return field }
        let choose = NSButton(title: "Choose…", target: self, action: #selector(choosePath(_:)))
        choose.identifier = .init(key)
        let stack = NSStackView(views: [field, choose])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    @objc private func refresh() {
        guard let settings = AppState.shared.settings else { return }
        for key in keys {
            switch controls[key] {
            case let box as NSButton:
                box.state = settings.bool(key) ? .on : .off
            case let popup as NSPopUpButton:
                popup.removeAllItems()
                for option in settings.options[key] ?? [] {
                    let title: String = switch key {
                    case "quality_audio": { let o = Fmt.audioOption(option.value); return "\(o.title) — \(o.detail)" }()
                    case "quality_video": Fmt.videoOption(option.value)
                    default: Fmt.coverOption(option.value)
                    }
                    popup.addItem(withTitle: title)
                    popup.lastItem?.representedObject = option.value
                    if option.value == settings.string(key) { popup.select(popup.lastItem) }
                }
            case let stepper as NSStepper:
                stepper.integerValue = settings.int(key)
                stepperFields[key]?.integerValue = settings.int(key)
            case let field as NSTextField:
                if field.currentEditor() == nil { field.stringValue = settings.string(key) }
            default:
                break
            }
        }
    }

    private func save(_ key: String, _ value: Any) {
        AppState.shared.updateSettings([key: value])
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        save(key, sender.state == .on)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue, let value = sender.selectedItem?.representedObject else { return }
        save(key, value)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard let key = sender.identifier?.rawValue else { return }
        stepperFields[key]?.integerValue = sender.integerValue
        save(key, sender.integerValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue else { return }
        if Field.steppers.contains(key) {
            let value = max(1, min(99, field.integerValue))
            (controls[key] as? NSStepper)?.integerValue = value
            if value != AppState.shared.settings?.int(key) { save(key, value) }
        } else if field.stringValue != AppState.shared.settings?.string(key) {
            save(key, field.stringValue)
        }
    }

    @objc private func choosePath(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let window = view.window else { return }
        let panel = NSOpenPanel()
        let isFolder = key == "download_base_path"
        panel.canChooseDirectories = isFolder
        panel.canChooseFiles = !isFolder
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = !isFolder
        panel.treatsFilePackagesAsDirectories = true
        let current = (AppState.shared.settings?.string(key) ?? "") as NSString
        let fallback = isFolder ? NSHomeDirectory() : "/opt/homebrew/bin"
        let start = current.length > 0 ? current.expandingTildeInPath : fallback
        panel.directoryURL = URL(fileURLWithPath: isFolder ? start : (start as NSString).deletingLastPathComponent)
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            (self?.controls[key] as? NSTextField)?.stringValue = url.path
            self?.save(key, url.path)
        }
    }
}

private final class AccountPage: NSViewController {
    private let status = NSTextField.label(size: 13, weight: .medium)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let signIn = NSButton(title: "Sign In with Browser…", target: nil, action: #selector(AppDelegate.signInForLossless(_:)))
    private let logout = NSButton(title: "Log Out…", target: nil, action: #selector(AppDelegate.logout(_:)))

    override func loadView() {
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 420
        let buttons = NSStackView(views: [signIn, logout])
        let stack = NSStackView(views: [status, detail, buttons]).vertical(spacing: 8)
        stack.setCustomSpacing(16, after: detail)
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            container.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = container
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .accountChanged, object: nil)
        refresh()
    }

    @objc private func refresh() {
        let state = AppState.shared
        if !state.loggedIn {
            status.stringValue = "Not signed in"
            detail.stringValue = ""
        } else if state.isPkce {
            status.stringValue = "Signed in with browser login — lossless enabled"
            detail.stringValue = "TIDAL serves FLAC (up to 24-bit, 192 kHz) to this login."
        } else {
            status.stringValue = "Signed in with device link — lossless limited"
            detail.stringValue = "TIDAL now caps device-link logins at AAC 320 kbps for most tracks. Sign in with the browser login to download FLAC."
        }
        signIn.title = state.isPkce ? "Sign In Again…" : "Sign In with Browser…"
        logout.isEnabled = state.loggedIn
    }
}
