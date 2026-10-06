import AppKit
import WebKit

/// Sign-in sheet.
/// - Browser sign-in (PKCE): TIDAL's login page in a web view; the redirect is caught automatically.
///   This is the login TIDAL still serves lossless FLAC to.
/// - Device link: the original Qt flow (`DialogLogin`): open a link, sign in, click Continue.
final class LoginController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    enum Outcome { case loggedIn, cancelled }

    private let required: Bool
    private let completion: (Outcome) -> Void
    private var redirectPrefix = ""
    private var linkURL: URL?
    private var finished = false

    private let tabs = NSTabView()
    private let webView: WKWebView
    private let webSpinner = NSProgressIndicator()
    private let webHint = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private let linkField = NSTextField.label(size: 13, weight: .medium, color: .linkColor)
    private let linkExpiry = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private let linkHint = NSTextField.label(size: 12, color: .secondaryLabelColor)
    private let linkContinue = NSButton(title: "Continue", target: nil, action: nil)
    private let linkSpinner = NSProgressIndicator()

    /// `required`: the app can't run without a login, so Cancel quits (as in the Qt GUI).
    init(required: Bool, completion: @escaping (Outcome) -> Void) {
        self.required = required
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let title = NSTextField.label("Sign in to TIDAL", size: 17, weight: .semibold)
        let subtitle = NSTextField.label(required ? "Sign in once; the app remembers you." : "Sign in again with the browser login to get lossless FLAC downloads.", size: 12, color: .secondaryLabelColor)
        let heading = NSStackView(views: [icon, NSStackView(views: [title, subtitle]).vertical()])
        heading.spacing = 12

        let segmented = NSSegmentedControl(labels: ["Browser (lossless)", "Device Link"], trackingMode: .selectOne, target: self, action: #selector(switchMode(_:)))
        segmented.selectedSegment = 0
        segmented.segmentDistribution = .fillEqually

        // Browser tab
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 10
        webView.layer?.masksToBounds = true
        webSpinner.style = .spinning
        webSpinner.controlSize = .small
        webSpinner.isDisplayedWhenStopped = false
        webHint.stringValue = "Sign in below. You’ll come back here automatically."
        let webFooter = NSStackView(views: [webSpinner, webHint])
        webFooter.spacing = 6
        let webStack = NSStackView(views: [webView, webFooter]).vertical(spacing: 8)
        webView.widthAnchor.constraint(equalTo: webStack.widthAnchor).isActive = true

        // Device-link tab
        linkField.isSelectable = true
        linkField.lineBreakMode = .byTruncatingMiddle
        let open = NSButton(title: "Open Login Page", target: self, action: #selector(openLink))
        open.bezelStyle = .glass
        let copy = NSButton(title: "Copy Link", target: self, action: #selector(copyLink))
        copy.bezelStyle = .glass
        linkContinue.target = self
        linkContinue.action = #selector(completeLink)
        linkContinue.bezelStyle = .glass
        linkContinue.keyEquivalent = "\r"
        linkSpinner.style = .spinning
        linkSpinner.controlSize = .small
        linkSpinner.isDisplayedWhenStopped = false
        linkHint.maximumNumberOfLines = 3
        linkHint.lineBreakMode = .byWordWrapping
        linkHint.preferredMaxLayoutWidth = 480
        let steps = NSTextField.label("1. Open the login page and sign in.\n2. Come back and click Continue.", size: 13)
        steps.maximumNumberOfLines = 2
        let linkStack = NSStackView(views: [
            steps, linkField, linkExpiry,
            NSStackView(views: [open, copy, NSView(), linkSpinner, linkContinue]),
            linkHint, NSView(),
        ]).vertical(spacing: 12)
        linkStack.subviews.last?.setContentHuggingPriority(.init(1), for: .vertical)

        for (index, view) in [webStack, linkStack].enumerated() {
            let item = NSTabViewItem(identifier: index)
            let host = NSView()
            host.addSubview(view)
            view.pin(to: host)
            item.view = host
            tabs.addTabViewItem(item)
        }
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false

        let cancel = NSButton(title: required ? "Quit" : "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .glass
        let footer = NSStackView(views: [NSView(), cancel])

        let stack = NSStackView(views: [heading, segmented, tabs, footer]).vertical(spacing: 14)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
        [segmented, tabs, footer].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        content.addSubview(stack)
        stack.pin(to: content)
    }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        loadBrowserLogin()
    }

    // MARK: Browser (PKCE)

    private func loadBrowserLogin() {
        webSpinner.startAnimation(nil)
        Backend.shared.call("login.pkce_url") { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let d = value as? [String: Any],
                  let urlString = d["url"] as? String, let url = URL(string: urlString) else {
                self.webHint.stringValue = "Could not start the browser login. Try Device Link."
                self.webSpinner.stopAnimation(nil)
                return
            }
            self.redirectPrefix = d["redirect"] as? String ?? ""
            self.webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url?.absoluteString, !redirectPrefix.isEmpty, url.hasPrefix(redirectPrefix) {
            decisionHandler(.cancel)
            completeBrowserLogin(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { webSpinner.stopAnimation(nil) }

    /// Social sign-in buttons open popups; keep them in this view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    private func completeBrowserLogin(_ redirect: String) {
        webSpinner.startAnimation(nil)
        webHint.stringValue = "Signing in…"
        Backend.shared.call("login.pkce_complete", ["url": redirect]) { [weak self] result in
            guard let self else { return }
            self.webSpinner.stopAnimation(nil)
            if case .success(let value) = result, (value as? [String: Any])?["ok"] as? Bool == true {
                AppState.shared.setAccount(loggedIn: true, isPkce: true)
                self.finish(.loggedIn)
            } else {
                let hint = ((try? result.get()) as? [String: Any])?["hint"] as? String
                self.webHint.stringValue = hint ?? "Sign-in failed. Please try again."
                self.loadBrowserLogin()
            }
        }
    }

    // MARK: Device link (port of the Qt login loop)

    @objc private func switchMode(_ sender: NSSegmentedControl) {
        tabs.selectTabViewItem(at: sender.selectedSegment)
        if sender.selectedSegment == 1, linkURL == nil {
            requestLink(hint: "After you have finished the TIDAL login via web browser click Continue.")
        }
    }

    private func requestLink(hint: String) {
        linkHint.stringValue = hint
        linkSpinner.startAnimation(nil)
        linkContinue.isEnabled = false
        Backend.shared.call("login.link") { [weak self] result in
            guard let self else { return }
            self.linkSpinner.stopAnimation(nil)
            guard case .success(let value) = result, let d = value as? [String: Any],
                  let url = (d["url"] as? String).flatMap(URL.init(string:)) else {
                self.linkHint.stringValue = "Could not get a login link. Check your internet connection."
                return
            }
            self.linkURL = url
            self.linkField.stringValue = url.absoluteString
            let expires = Date().addingTimeInterval((d["expiresIn"] as? Double) ?? 300)
            self.linkExpiry.stringValue = "Link expires at " + expires.formatted(date: .omitted, time: .shortened)
            self.linkContinue.isEnabled = true
        }
    }

    @objc private func openLink() {
        if let linkURL { NSWorkspace.shared.open(linkURL) }
    }

    @objc private func copyLink() {
        guard let linkURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(linkURL.absoluteString, forType: .string)
    }

    @objc private func completeLink() {
        linkSpinner.startAnimation(nil)
        linkContinue.isEnabled = false
        Backend.shared.call("login.complete") { [weak self] result in
            guard let self else { return }
            self.linkSpinner.stopAnimation(nil)
            if case .success(let value) = result, (value as? [String: Any])?["ok"] as? Bool == true {
                AppState.shared.setAccount(loggedIn: true, isPkce: false)
                self.finish(.loggedIn)
            } else {
                let hint = ((try? result.get()) as? [String: Any])?["hint"] as? String
                self.requestLink(hint: hint ?? "Something was wrong with your login. Please try again!")
            }
        }
    }

    // MARK: Finish

    @objc private func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        guard !finished, let window else { return }
        finished = true
        webView.stopLoading()
        window.sheetParent?.endSheet(window)
        completion(outcome)
    }
}

extension NSStackView {
    func vertical(spacing: CGFloat = 2) -> NSStackView {
        orientation = .vertical
        alignment = .leading
        self.spacing = spacing
        return self
    }
}
