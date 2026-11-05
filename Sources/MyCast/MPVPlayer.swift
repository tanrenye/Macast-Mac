import Darwin
import Foundation

/// mpv 和 IINA 使用同一套 JSON IPC 命令，每次投送单独启动播放器。
final class MPVPlayer: PlayerBackend {
    var onEvent: ((PlayerEvent) -> Void)?
    private let executable: URL
    private let iina: Bool
    private var process: Process?
    private var ipc: Int32 = -1
    private var reader: DispatchSourceRead?
    private var directory: URL?
    private var buffer = Data()
    private var pending: [[Any]] = []
    private var loaded = false
    private var paused = false

    init(executable: URL, iina: Bool) {
        self.executable = executable
        self.iina = iina
    }

    func open(_ media: CastMedia, position: Double, settings: Settings) throws {
        let directory = URL(fileURLWithPath: "/tmp/mycast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let path = directory.appendingPathComponent("ipc").path
        let child = Process()
        child.executableURL = executable
        var options = ["input-ipc-server=\(path)", "start=\(position)", "image-display-duration=inf"]
        if settings.playerSize == .fullScreen { options.append("fullscreen=yes") }
        if [.small, .normal, .large].contains(settings.playerSize) {
            options.append("autofit=\(Int(settings.playerSize.scale * 100))%")
        }
        options.append("geometry=\(settings.playerPosition.mpvGeometry)")
        options.append("hwdec=\(settings.hardwareDecode ? "auto-safe" : "no")")
        if settings.onTop { options.append("ontop=yes") }
        if iina {
            child.arguments = ["--keep-running", "--no-stdin"] + options.map { "--mpv-\($0)" } + [media.url.absoluteString]
        } else {
            options += ["config-dir=\(settings.mpvConfig.path)", "force-window=yes", "idle=yes",
                        "force-media-title=\(media.title)", "volume-max=100"]
            child.arguments = options.map { "--\($0)" } + ["--", media.url.absoluteString]
        }
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === process else { return }
                if process.terminationStatus == 0 && loaded { onEvent?(.ended) }
                else {
                    let status = process.terminationStatus
                    onEvent?(.error(AppMessage("The player exited (status \(status)).", "播放器退出（\(status)）。")))
                }
            }
        }
        try child.run()
        process = child
        connect(path: path, remaining: 50)
    }

    func play(speed: Double) {
        command(["set_property", "speed", speed])
        command(["set_property", "pause", false])
    }

    func pause() { command(["set_property", "pause", true]) }
    func seek(_ seconds: Double) { command(["seek", seconds, "absolute", "exact"]) }

    func volume(_ value: Int, muted: Bool) {
        command(["set_property", "volume", value])
        command(["set_property", "mute", muted])
    }

    func stop() {
        if ipc >= 0 { command(["quit"]) }
        else if let process, process.isRunning { process.terminate() }
        let child = process
        process = nil
        if reader != nil { reader?.cancel() }
        reader = nil
        ipc = -1
        pending.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let child, child.isRunning { child.terminate() }
        }
    }

    private func connect(path: String, remaining: Int) {
        guard process != nil else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) }) }
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            var one: Int32 = 1
            if connected == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
               setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                ipc = fd
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
                source.setEventHandler { [weak self] in self?.receive() }
                source.setCancelHandler { close(fd) }
                reader = source
                source.resume()
                let queued = pending
                pending.removeAll()
                queued.forEach { command($0) }
                for (index, property) in ["pause", "time-pos", "duration", "volume", "mute", "speed", "idle-active"].enumerated() {
                    command(["observe_property", index + 1, property])
                }
                command(["get_property", "path"], request: 100)
                return
            }
            close(fd)
        }
        guard remaining > 0 else {
            onEvent?(.error(AppMessage("Could not connect to the player's IPC socket.", "无法连接播放器的 IPC。")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.connect(path: path, remaining: remaining - 1)
        }
    }

    private func command(_ args: [Any], request: Int? = nil) {
        if ipc < 0 {
            if process != nil && pending.count < 100 { pending.append(args) }
            return
        }
        var object: [String: Any] = ["command": args]
        if let request { object["request_id"] = request }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let packet = data + Data([10])
        let sent = packet.withUnsafeBytes { send(ipc, $0.baseAddress, $0.count, 0) }
        if sent != packet.count {
            // 避免在部分写入后发送下一条命令，导致 JSON 帧错位。
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(.error(AppMessage("The player control connection was interrupted.", "播放器控制连接中断。")))
            }
        }
    }

    private func receive() {
        guard ipc >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = recv(ipc, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { onEvent?(.ended); return }
        buffer.append(contentsOf: bytes.prefix(count))
        while let index = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { consume(message) }
            if ipc < 0 { return }
        }
        if buffer.count > 1024 * 1024 {
            onEvent?(.error(AppMessage("The player's IPC message was too large.", "播放器返回了过大的 IPC 消息。")))
        }
    }

    private func consume(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "file-loaded", "playback-restart":
            loaded = true
            onEvent?(paused ? .paused : .playing)
        case "end-file":
            if message["reason"] as? String == "error" {
                let detail = (message["file_error"] as? String).map { AppMessage($0) } ??
                    AppMessage("The media could not be played.", "媒体无法播放。")
                onEvent?(.error(detail))
            } else { onEvent?(.ended) }
        case "property-change":
            let value = message["data"] as? NSNumber
            switch message["name"] as? String {
            case "pause":
                if let value {
                    paused = value.boolValue
                    if loaded { onEvent?(paused ? .paused : .playing) }
                }
            case "time-pos": if let value { onEvent?(.position(value.doubleValue)) }
            case "duration": if let value { onEvent?(.duration(value.doubleValue)) }
            case "volume": if let value { onEvent?(.volume(value.intValue)) }
            case "mute": if let value { onEvent?(.mute(value.boolValue)) }
            case "speed": if let value { onEvent?(.speed(value.doubleValue)) }
            case "idle-active": if value?.boolValue == true && loaded { onEvent?(.ended) }
            default: break
            }
        default:
            if message["request_id"] as? Int == 100 {
                if message["data"] is String {
                    loaded = true
                    onEvent?(paused ? .paused : .playing)
                } else if !iina {
                    // 启动阶段 path 可能还未设置，只有播放器空闲且无媒体时才报错。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, !loaded, process != nil else { return }
                        onEvent?(.error(AppMessage("The player could not open the media.", "播放器未能打开媒体。")))
                    }
                }
            }
        }
    }
}
