import AppKit

/// Port of `DialogVersion`: app version, and (after an update check) the latest release.
final class AboutWindowController: NSWindowController {
    struct UpdateInfo {
        let available: Bool
        let version: String
        let url: URL?
        let releaseInfo: String
        let error: Bool

        init(_ d: [String: Any]) {
            available = d["available"] as? Bool ?? false
            version = d["version"] as? String ?? ""
            url = (d["url"] as? String).flatMap(URL.init(string:))
            releaseInfo = d["releaseInfo"] as? String ?? ""
            error = d["error"] as? Bool ?? false
        }
    }

    private let stack = NSStackView()
    private var update: UpdateInfo?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        super.init(window: window)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 24, right: 28)
        let content = NSView()
        content.addSubview(stack)
        stack.pin(to: content)
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(update: UpdateInfo?) {
        self.update = update
        rebuild()
        window?.layoutIfNeeded()
        window?.setContentSize(stack.fittingSize)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(12, after: icon)
        stack.addArrangedSubview(NSTextField.label("TIDAL Downloader Next Generation", size: 16, weight: .semibold))
        stack.addArrangedSubview(NSTextField.label("Version \(AppState.shared.version)", size: 12, color: .secondaryLabelColor))

        guard let update else { return }
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        if update.error {
            let error = NSTextField.label("Cannot retrieve update information. Maybe something is wrong with your internet connection.", size: 12, color: .secondaryLabelColor)
            error.alignment = .center
            error.maximumNumberOfLines = 3
            error.preferredMaxLayoutWidth = 340
            stack.addArrangedSubview(error)
            return
        }
        let heading = update.available ? "New version available: \(update.version)" : "Latest available version: \(update.version)"
        stack.addArrangedSubview(NSTextField.label(heading, size: 13, weight: .medium))
        guard update.available else { return }

        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.string = update.releaseInfo
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 364).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(scroll)

        let download = NSButton(title: "Download…", target: self, action: #selector(openDownload))
        download.bezelStyle = .glass
        download.keyEquivalent = "\r"
        stack.setCustomSpacing(12, after: scroll)
        stack.addArrangedSubview(download)
    }

    @objc private func openDownload() {
        if let url = update?.url { NSWorkspace.shared.open(url) }
    }
}
