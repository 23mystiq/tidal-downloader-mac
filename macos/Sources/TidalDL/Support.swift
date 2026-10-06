import AppKit
import ImageIO

enum Fmt {
    static func duration(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "" }
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Short badge text for a TIDAL quality value.
    static func quality(_ raw: String) -> String {
        switch raw {
        case "HI_RES_LOSSLESS": "Hi-Res"
        case "LOSSLESS": "Lossless"
        case "HIGH": "320k"
        case "LOW": "96k"
        case "": ""
        default:
            raw.replacingOccurrences(of: "MP4_", with: "").replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    static func qualityColor(_ raw: String) -> NSColor {
        switch raw {
        case "HI_RES_LOSSLESS": .systemOrange
        case "LOSSLESS": .systemTeal
        default: .secondaryLabelColor
        }
    }

    static func audioOption(_ value: String) -> (title: String, detail: String) {
        switch value {
        case "LOW": ("Low", "AAC 96 kbps")
        case "HIGH": ("High", "AAC 320 kbps")
        case "LOSSLESS": ("Lossless", "FLAC 16-bit, 44.1 kHz")
        case "HI_RES_LOSSLESS": ("Max", "FLAC up to 24-bit, 192 kHz")
        default: (value, "")
        }
    }

    static func videoOption(_ value: String) -> String { value + "p" }

    static func coverOption(_ value: String) -> String { "\(value) × \(value) px" }
}

extension NSImage {
    static func symbol(_ name: String, _ size: CGFloat = 13, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight, scale: scale))
    }
}

extension NSTextField {
    static func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

extension NSView {
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

func glassButton(symbol: String, tooltip: String, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage.symbol(symbol, 13, weight: .medium) ?? NSImage(), target: target, action: action)
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.controlSize = .regular
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
}

/// Artwork cache: memory (decoded, downsampled) + disk (URLCache), coalesced requests.
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private let decodeQueue = DispatchQueue(label: "image.decode", qos: .userInitiated, attributes: .concurrent)

    private init() {
        memory.countLimit = 1500
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TidalDL/Artwork", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20, directory: caches)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    private func key(_ url: URL, _ pixels: Int) -> String { "\(pixels)|\(url.absoluteString)" }

    func cached(_ url: URL?, pointSize: CGFloat) -> NSImage? {
        guard let url else { return nil }
        return memory.object(forKey: key(url, pixels(pointSize)) as NSString)
    }

    private func pixels(_ pointSize: CGFloat) -> Int {
        Int(pointSize * (NSScreen.main?.backingScaleFactor ?? 2))
    }

    /// Calls `completion` on the main thread (immediately if cached).
    func load(_ url: URL?, pointSize: CGFloat, completion: @escaping (NSImage?) -> Void) {
        guard let url else { return completion(nil) }
        let px = pixels(pointSize)
        let k = key(url, px)
        if let image = memory.object(forKey: k as NSString) { return completion(image) }
        if waiting[k] != nil {
            waiting[k]?.append(completion)
            return
        }
        waiting[k] = [completion]
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            self.decodeQueue.async {
                let image = data.flatMap { Self.decode($0, maxPixels: px) }
                DispatchQueue.main.async {
                    if let image { self.memory.setObject(image, forKey: k as NSString) }
                    let callbacks = self.waiting.removeValue(forKey: k) ?? []
                    callbacks.forEach { $0(image) }
                }
            }
        }.resume()
    }

    private static func decode(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}

/// Image view that shows artwork for a URL, ignoring late results for a previous URL (cell reuse).
final class ArtworkView: NSImageView {
    private var current: URL?
    var placeholderSymbol = "music.note"
    let pointSize: CGFloat

    init(size: CGFloat, radius: CGFloat) {
        pointSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        contentTintColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ url: URL?) {
        guard url != current || image == nil else { return }
        current = url
        if let cached = ImageLoader.shared.cached(url, pointSize: pointSize) {
            imageScaling = .scaleProportionallyUpOrDown
            image = cached
            return
        }
        showPlaceholder()
        ImageLoader.shared.load(url, pointSize: pointSize) { [weak self] image in
            guard let self, self.current == url, let image else { return }
            self.imageScaling = .scaleProportionallyUpOrDown
            self.image = image
        }
    }

    private func showPlaceholder() {
        imageScaling = .scaleNone
        image = NSImage.symbol(placeholderSymbol, pointSize * 0.4)
    }
}
