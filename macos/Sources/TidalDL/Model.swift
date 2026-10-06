import AppKit

extension Notification.Name {
    static let listsChanged = Notification.Name("tdl.listsChanged")
    static let listsLoadingChanged = Notification.Name("tdl.listsLoadingChanged")
    static let resultsReset = Notification.Name("tdl.resultsReset")
    static let resultsAppended = Notification.Name("tdl.resultsAppended")
    static let resultsLoadingChanged = Notification.Name("tdl.resultsLoadingChanged")
    static let queueChanged = Notification.Name("tdl.queueChanged")
    static let queueItemChanged = Notification.Name("tdl.queueItemChanged")
    static let queueRunningChanged = Notification.Name("tdl.queueRunningChanged")
    static let progressChanged = Notification.Name("tdl.progressChanged")
    static let statusChanged = Notification.Name("tdl.statusChanged")
    static let settingsChanged = Notification.Name("tdl.settingsChanged")
    static let logAppended = Notification.Name("tdl.logAppended")
    static let coverChanged = Notification.Name("tdl.coverChanged")
    static let accountChanged = Notification.Name("tdl.accountChanged")
}

private func post(_ name: Notification.Name, _ info: [String: Any]? = nil) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: info)
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? -1 }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func url(_ key: String) -> URL? { (self[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
}

// MARK: - Results

final class ResultNode {
    let handle: String
    let position: Int
    let kind: String
    let artist: String
    let title: String
    let album: String
    let duration: Int
    let quality: String
    let explicit: Bool
    let added: String
    let expandable: Bool
    let thumb: URL?
    let cover: URL?
    let share: String
    var children: [ResultNode]?
    var isLoadingChildren = false
    weak var parent: ResultNode?

    init(_ d: [String: Any], parent: ResultNode? = nil) {
        handle = d.string("h")
        position = d.int("position")
        kind = d.string("kind")
        artist = d.string("artist")
        title = d.string("title")
        album = d.string("album")
        duration = d.int("duration")
        quality = d.string("quality")
        explicit = d.bool("explicit")
        added = d.string("added")
        expandable = d.bool("expandable")
        thumb = d.url("thumb")
        cover = d.url("cover")
        share = d.string("share")
        self.parent = parent
    }

    /// The name people would say for this row.
    var displayName: String {
        switch kind {
        case "Album": album
        case "Artist": artist
        default: title.isEmpty ? (album.isEmpty ? artist : album) : title
        }
    }

    var displaySubtitle: String {
        switch kind {
        case "Artist": "Artist"
        case "Album": artist
        case "Mix", "Playlist": artist.isEmpty ? kind : artist
        default: [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }
}

/// Marker row shown while a node's children load.
final class LoadingNode {
    static let shared = LoadingNode()
}

final class ResultsModel {
    private(set) var roots: [ResultNode] = []
    private(set) var title = ""
    private(set) var isLoading = false
    private var token = 0

    private func reset(title: String) {
        token += 1
        roots = []
        self.title = title
        setLoading(true)
        post(.resultsReset)
    }

    private func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        post(.resultsLoadingChanged)
    }

    func search(_ query: String, type: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        reset(title: query.contains("http") ? "Link" : "“\(query)”")
        let sid = token
        Backend.shared.call("search", ["sid": sid, "query": query, "type": type]) { [weak self] result in
            guard let self, self.token == sid else { return }
            self.setLoading(false)
            if case .failure(let error) = result { AppState.shared.log("error", "Search failed: \(error)") }
        }
    }

    func appendPage(sid: Int, items: [[String: Any]]) {
        guard sid == token else { return }
        let nodes = items.map { ResultNode($0) }
        roots.append(contentsOf: nodes)
        post(.resultsAppended, ["nodes": nodes])
    }

    func show(list entry: ListEntry) {
        Backend.shared.call("search.cancel")
        reset(title: entry.name)
        let current = token
        Backend.shared.call("list.items", ["h": entry.handle]) { [weak self] result in
            guard let self, self.token == current else { return }
            if case .success(let value) = result, let items = (value as? [String: Any])?["items"] as? [[String: Any]] {
                let nodes = items.map { ResultNode($0) }
                self.roots = nodes
                post(.resultsAppended, ["nodes": nodes])
            } else if case .failure(let error) = result {
                AppState.shared.log("error", "Could not load “\(entry.name)”: \(error)")
            }
            self.setLoading(false)
        }
    }

    func loadChildren(of node: ResultNode, completion: @escaping () -> Void) {
        guard node.children == nil, !node.isLoadingChildren else { return }
        node.isLoadingChildren = true
        Backend.shared.call("list.items", ["h": node.handle]) { result in
            node.isLoadingChildren = false
            if case .success(let value) = result, let items = (value as? [String: Any])?["items"] as? [[String: Any]] {
                node.children = items.map { ResultNode($0, parent: node) }
            } else {
                node.children = []
                if case .failure(let error) = result { AppState.shared.log("error", "\(error)") }
            }
            completion()
        }
    }
}

// MARK: - Lists, queue, settings

final class ListEntry {
    enum Kind { case playlist, mix, favorite }

    let handle: String
    let name: String
    let info: String
    let thumb: URL?
    let cover: URL?
    let share: String
    let kind: Kind

    init(_ d: [String: Any], kind: Kind) {
        handle = d.string("h")
        name = d.string("name")
        info = d.string("info")
        thumb = d.url("thumb")
        cover = d.url("cover")
        share = d.string("share")
        self.kind = kind
    }

    var symbol: String {
        switch handle {
        case "fav_videos": "play.rectangle"
        case "fav_tracks": "music.note"
        case "fav_mixes": "dot.radiowaves.left.and.right"
        case "fav_artists": "music.microphone"
        case "fav_albums": "square.stack"
        default: kind == .mix ? "waveform" : "music.note.list"
        }
    }
}

final class QueueEntry {
    let qid: Int
    var status: String
    let name: String
    let type: String
    let qualityAudio: String
    let qualityVideo: String
    let cover: URL?

    init(_ d: [String: Any]) {
        qid = d.int("qid")
        status = d.string("status")
        name = d.string("name")
        type = d.string("type")
        qualityAudio = d.string("qualityAudio")
        qualityVideo = d.string("qualityVideo")
        cover = d.url("cover")
    }
}

struct SettingsOption {
    let value: String
    let name: String
}

struct SettingsModel {
    var values: [String: Any]
    let options: [String: [SettingsOption]]
    let help: [String: String]

    init(_ d: [String: Any]) {
        values = d["values"] as? [String: Any] ?? [:]
        help = d["help"] as? [String: String] ?? [:]
        var options: [String: [SettingsOption]] = [:]
        for (key, list) in d["options"] as? [String: [[String: Any]]] ?? [:] {
            options[key] = list.map { SettingsOption(value: $0.string("value"), name: $0.string("name")) }
        }
        self.options = options
    }

    func string(_ key: String) -> String {
        if let s = values[key] as? String { return s }
        if let n = values[key] as? NSNumber { return n.stringValue }
        return ""
    }

    func bool(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    func int(_ key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
}

struct ProgressState {
    var name = ""
    var value: Double = 0
}

struct CoverState {
    var url: URL?
    var placeholder: URL?
    var title = ""
    var subtitle = ""
}

// MARK: - App state

final class AppState {
    static let shared = AppState()

    let results = ResultsModel()
    private(set) var playlists: [ListEntry] = []
    private(set) var mixes: [ListEntry] = []
    private(set) var favorites: [ListEntry] = []
    private(set) var listsLoading = false
    private(set) var queue: [QueueEntry] = []
    private(set) var queueRunning = true
    private(set) var listProgress = ProgressState()
    private(set) var itemProgress = ProgressState()
    private(set) var statusMessage = ""
    private(set) var settings: SettingsModel?
    private(set) var cover = CoverState()
    var version = ""
    var loggedIn = false
    var isPkce = false
    private var statusTimer: Timer?

    var isDownloading: Bool { queue.contains { $0.status == "downloading" } }

    func handle(event: String, data: Any?) {
        let d = data as? [String: Any] ?? [:]
        switch event {
        case "log":
            log(d.string("level"), d.string("message"))
        case "progress":
            let bar = d.string("bar")
            var state = bar == "list" ? listProgress : itemProgress
            if let name = d["name"] as? String { state.name = name }
            if let value = d["value"] as? NSNumber { state.value = value.doubleValue }
            if bar == "list" { listProgress = state } else { itemProgress = state }
            post(.progressChanged)
        case "progressReset":
            listProgress.value = 0
            itemProgress.value = 0
            post(.progressChanged)
        case "status":
            setStatus(d.string("message"), timeout: d.int("timeout"))
        case "userListsLoading":
            listsLoading = (data as? NSNumber)?.boolValue ?? false
            post(.listsLoadingChanged)
        case "userLists":
            playlists = (d["playlists"] as? [[String: Any]] ?? []).map { ListEntry($0, kind: .playlist) }
            mixes = (d["mixes"] as? [[String: Any]] ?? []).map { ListEntry($0, kind: .mix) }
            favorites = (d["favorites"] as? [[String: Any]] ?? []).map { ListEntry($0, kind: .favorite) }
            post(.listsChanged)
        case "searchPage":
            results.appendPage(sid: d.int("sid"), items: d["items"] as? [[String: Any]] ?? [])
        case "queueAdded":
            queue.append(QueueEntry(d))
            post(.queueChanged)
        case "queueStatus":
            if let entry = queue.first(where: { $0.qid == d.int("qid") }) {
                entry.status = d.string("status")
                post(.queueItemChanged, ["qid": entry.qid])
            }
        default:
            break
        }
    }

    // MARK: Logs

    struct LogLine {
        let level: String
        let message: String
    }

    private(set) var logs: [LogLine] = []

    func log(_ level: String, _ message: String) {
        let line = LogLine(level: level, message: message)
        logs.append(line)
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
        post(.logAppended, ["line": line])
    }

    private func setStatus(_ message: String, timeout: Int) {
        statusTimer?.invalidate()
        statusMessage = message
        post(.statusChanged)
        if timeout > 0 {
            statusTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000, repeats: false) { [weak self] _ in
                self?.statusMessage = ""
                post(.statusChanged)
            }
        }
    }

    // MARK: Actions

    func showCover(url: URL?, placeholder: URL?, title: String, subtitle: String) {
        guard url != nil || placeholder != nil else { return }
        cover = CoverState(url: url, placeholder: placeholder, title: title, subtitle: subtitle)
        post(.coverChanged)
    }

    func reloadLists() {
        guard !listsLoading else { return }
        listsLoading = true
        post(.listsLoadingChanged)
        Backend.shared.call("user_lists.reload")
    }

    func download(handles: [String]) {
        guard !handles.isEmpty else {
            log("error", "Please select a row first.")
            return
        }
        Backend.shared.call("queue.add", ["handles": handles])
    }

    func removeFromQueue(_ qids: [Int]) {
        guard !qids.isEmpty else {
            log("error", "Please select an item from the queue first.")
            return
        }
        Backend.shared.call("queue.remove", ["qids": qids]) { [weak self] in self?.dropQueue($0) }
    }

    func clearFinished() {
        Backend.shared.call("queue.clear_finished") { [weak self] in self?.dropQueue($0) }
    }

    func clearAll() {
        Backend.shared.call("queue.clear_all") { [weak self] in self?.dropQueue($0) }
    }

    private func dropQueue(_ result: Result<Any, BackendError>) {
        guard case .success(let value) = result, let removed = (value as? [String: Any])?["removed"] as? [Int] else { return }
        let set = Set(removed)
        queue.removeAll { set.contains($0.qid) }
        post(.queueChanged)
    }

    func setQueueRunning(_ running: Bool) {
        queueRunning = running
        post(.queueRunningChanged)
        Backend.shared.call("queue.set_running", ["running": running])
    }

    func applySettings(_ dict: [String: Any]) {
        settings = SettingsModel(dict)
        post(.settingsChanged)
    }

    func updateSettings(_ values: [String: Any]) {
        if var current = settings {
            for (key, value) in values { current.values[key] = value }
            settings = current
            post(.settingsChanged)
        }
        Backend.shared.call("settings.update", ["values": values]) { [weak self] result in
            if case .success(let value) = result, let dict = value as? [String: Any] { self?.applySettings(dict) }
        }
    }

    func setAccount(loggedIn: Bool, isPkce: Bool) {
        self.loggedIn = loggedIn
        self.isPkce = isPkce
        post(.accountChanged)
    }
}
