import Foundation

enum BackendError: Error, CustomStringConvertible {
    case notConfigured
    case exited
    case remote(String)

    var description: String {
        switch self {
        case .notConfigured: "The Python backend could not be found. Rebuild the app with macos/build.sh."
        case .exited: "The backend stopped."
        case .remote(let message): message
        }
    }
}

/// Runs `python -m tidal_dl_ng.bridge` and talks newline-delimited JSON with it.
/// Responses and events are delivered on the main thread, in the order the backend sent them.
final class Backend {
    static let shared = Backend()

    typealias Completion = (Result<Any, BackendError>) -> Void

    var onEvent: ((String, Any?) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: Completion] = [:]
    private let readQueue = DispatchQueue(label: "backend.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "backend.write", qos: .userInitiated)
    private var buffer = Data()
    private var stderrTail = Data()
    private(set) var isShuttingDown = false

    private struct Config {
        let python: String
        let root: String
    }

    private static func config() -> Config? {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        guard let root = env["TDL_ROOT"] ?? info["TDLRoot"] as? String else { return nil }
        let python = env["TDL_PYTHON"] ?? info["TDLPython"] as? String ?? root + "/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
        return Config(python: python, root: root)
    }

    func start() throws {
        guard let config = Self.config() else { throw BackendError.notConfigured }
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.python)
        process.arguments = ["-u", "-X", "utf8", "-m", "tidal_dl_ng.bridge"]
        process.currentDirectoryURL = URL(fileURLWithPath: config.root)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.readQueue.async { self.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            FileHandle.standardError.write(data)
            self.readQueue.async {
                self.stderrTail.append(data)
                if self.stderrTail.count > 16_384 { self.stderrTail = self.stderrTail.suffix(16_384) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { self?.handleExit(status) }
        }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    /// Sends a request; `completion` runs on the main thread.
    func call(_ method: String, _ params: [String: Any] = [:], completion: Completion? = nil) {
        lock.lock()
        nextID += 1
        let id = nextID
        if let completion { pending[id] = completion }
        lock.unlock()

        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writeQueue.async { [weak self] in
            do {
                try self?.input?.write(contentsOf: data)
            } catch {
                self?.fail(id)
            }
        }
    }

    /// Asks the backend to stop, then makes sure it does.
    func shutdown(then done: @escaping () -> Void) {
        guard let process, process.isRunning else { return done() }
        isShuttingDown = true
        call("shutdown")
        let deadline = Date().addingTimeInterval(1.5)
        func wait() {
            if !process.isRunning || Date() > deadline {
                if process.isRunning { process.terminate() }
                done()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait)
            }
        }
        wait()
    }

    // MARK: - Reading

    private func consume(_ data: Data) {
        buffer.append(data)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            start = buffer.index(after: newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
                  let message = object as? [String: Any]
            else { continue }
            dispatch(message)
        }
        buffer = start == buffer.endIndex ? Data() : Data(buffer[start...])
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            lock.lock()
            let completion = pending.removeValue(forKey: id)
            lock.unlock()
            guard let completion else { return }
            let result: Result<Any, BackendError>
            if let error = message["error"] as? String {
                result = .failure(.remote(error))
            } else {
                result = .success(message["result"] ?? NSNull())
            }
            DispatchQueue.main.async { completion(result) }
        } else if let event = message["event"] as? String {
            let data = message["data"]
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event, data is NSNull ? nil : data) }
        }
    }

    private func fail(_ id: Int) {
        lock.lock()
        let completion = pending.removeValue(forKey: id)
        lock.unlock()
        if let completion { DispatchQueue.main.async { completion(.failure(.exited)) } }
    }

    private func handleExit(_ status: Int32) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        waiting.values.forEach { $0(.failure(.exited)) }
        guard !isShuttingDown else { return }
        let tail = readQueue.sync { String(decoding: stderrTail, as: UTF8.self) }
        onExit?(status, tail)
    }
}
