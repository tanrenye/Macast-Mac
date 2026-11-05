import AppKit
import AVKit
import Foundation

/// 控制端投送的单项媒体及其 DIDL-Lite 元数据。
struct CastMedia {
    let url: URL
    let metadata: String
    let title: String
    let isImage: Bool

    init?(uri: String, metadata: String) {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        self.url = url
        self.metadata = metadata
        let node = XMLTree.parse(Data(metadata.utf8))
        let item = node?.children.first
        title = item?.child("title")?.text.nonEmpty ?? url.lastPathComponent.nonEmpty ?? "MyCast"
        isImage = item?.child("class")?.text.contains("imageItem") == true
            || item?.children.contains(where: { $0.name == "res" && $0.attributes["protocolInfo"]?.contains(":image/") == true }) == true
            || ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"].contains(url.pathExtension.lowercased())
    }
}

enum TransportState: String {
    case empty = "NO_MEDIA_PRESENT"
    case stopped = "STOPPED"
    case loading = "TRANSITIONING"
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
}

enum PlayerKind: String, CaseIterable {
    case automatic, system, mpv, iina

    func title(in language: AppLanguage) -> String {
        switch self {
        case .automatic: return language.text("Automatic (prefer mpv)", "自动（优先 mpv）")
        case .system: return language.text("System Player", "系统播放器")
        case .mpv: return "mpv"
        case .iina: return "IINA"
        }
    }

    var executable: URL? {
        let candidates: [String]
        switch self {
        case .automatic, .mpv:
            candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mpv").path,
                          "/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/opt/local/bin/mpv"]
                + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/mpv" }
        case .iina:
            candidates = ["/Applications/IINA.app/Contents/MacOS/iina-cli",
                          NSHomeDirectory() + "/Applications/IINA.app/Contents/MacOS/iina-cli"]
        case .system: return nil
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

enum PlayerSize: Int, CaseIterable {
    case small, normal, large, automatic, fullScreen

    static func labels(in language: AppLanguage) -> [String] {
        language == .english ? ["Small", "Normal", "Large", "Automatic", "Full Screen"] :
            ["小窗口", "普通", "大窗口", "自动", "全屏"]
    }

    var scale: Double {
        switch self {
        case .small: return 0.30
        case .normal: return 0.55
        case .large: return 0.85
        case .automatic, .fullScreen: return 0.70
        }
    }
}

enum PlayerPosition: Int, CaseIterable {
    case topLeft, bottomLeft, topRight, bottomRight, center

    static func labels(in language: AppLanguage) -> [String] {
        language == .english ? ["Top Left", "Bottom Left", "Top Right", "Bottom Right", "Center"] :
            ["左上", "左下", "右上", "右下", "居中"]
    }

    var mpvGeometry: String {
        switch self {
        case .topLeft: return "0%:0%"
        case .bottomLeft: return "0%:100%"
        case .topRight: return "100%:0%"
        case .bottomRight: return "100%:100%"
        case .center: return "50%:50%"
        }
    }

    func origin(in screen: NSRect, window: NSRect) -> NSPoint {
        let left = screen.minX
        let right = max(left, screen.maxX - window.width)
        let bottom = screen.minY
        let top = max(bottom, screen.maxY - window.height)
        switch self {
        case .topLeft: return NSPoint(x: left, y: top)
        case .bottomLeft: return NSPoint(x: left, y: bottom)
        case .topRight: return NSPoint(x: right, y: top)
        case .bottomRight: return NSPoint(x: right, y: bottom)
        case .center: return NSPoint(x: (left + right) / 2, y: (bottom + top) / 2)
        }
    }
}

enum PlayerEvent {
    case playing, paused, ended, error(AppMessage), position(Double), duration(Double), volume(Int), mute(Bool), speed(Double)
}

protocol PlayerBackend: AnyObject {
    var onEvent: ((PlayerEvent) -> Void)? { get set }
    func open(_ media: CastMedia, position: Double, settings: Settings) throws
    func play(speed: Double)
    func pause()
    func seek(_ seconds: Double)
    func volume(_ value: Int, muted: Bool)
    func stop()
}

/// 菜单栏和 DLNA 共用播放状态。旧播放器的异步事件不能覆盖新媒体状态。
final class Playback {
    private var backend: PlayerBackend?
    private let settings: Settings
    private(set) var media: CastMedia?
    var next: CastMedia?
    private(set) var state = TransportState.empty
    private(set) var status = "OK"
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var speed = 1.0
    private(set) var volume: Int
    private(set) var muted = false
    var onChange: (() -> Void)?
    var onError: ((AppMessage) -> Void)?

    init(settings: Settings) {
        self.settings = settings
        volume = settings.volume
    }

    func setMedia(_ media: CastMedia?) {
        stop()
        self.media = media
        next = nil
        state = media == nil ? .empty : .stopped
        onChange?()
    }

    func play(speed: Double = 1) {
        guard let media else { return }
        self.speed = speed
        if let backend {
            backend.play(speed: speed)
            if state == .paused { state = .playing }
            onChange?()
            return
        }

        let kind = settings.player
        let player: PlayerBackend
        if let executable = kind.executable {
            player = MPVPlayer(executable: executable, iina: kind == .iina)
        } else if kind == .automatic || kind == .system {
            player = SystemPlayer()
        } else {
            fail(AppMessage("Could not find \(kind.title(in: .english)). Install it and try again.",
                            "找不到 \(kind.title(in: .simplifiedChinese))，请安装后重试。"))
            return
        }

        backend = player
        player.onEvent = { [weak self, weak player] event in
            guard let self, let player, backend === player else { return }
            consume(event)
        }
        state = .loading
        status = "OK"
        onChange?()
        do {
            try player.open(media, position: position, settings: settings)
            player.volume(volume, muted: muted)
            player.play(speed: speed)
        } catch {
            fail(AppMessage(error.localizedDescription))
        }
    }

    func pause() {
        guard backend != nil else { return }
        backend?.pause()
        state = .paused
        onChange?()
    }

    func seek(_ time: Double) {
        position = duration > 0 ? min(time, duration) : time
        backend?.seek(position)
        onChange?()
    }

    func setVolume(_ value: Int) {
        volume = min(100, max(0, value))
        settings.volume = volume
        backend?.volume(volume, muted: muted)
        onChange?()
    }

    func setMute(_ value: Bool) {
        muted = value
        backend?.volume(volume, muted: muted)
        onChange?()
    }

    func stop() {
        let previous = backend
        backend = nil
        previous?.stop()
        state = media == nil ? .empty : .stopped
        status = "OK"
        position = 0
        duration = 0
        onChange?()
    }

    func advance() {
        guard let next else { return }
        setMedia(next)
        play()
    }

    private func fail(_ message: AppMessage) {
        stop()
        status = "ERROR_OCCURRED"
        onChange?()
        onError?(message)
    }

    private func consume(_ event: PlayerEvent) {
        switch event {
        case .playing: state = .playing
        case .paused: state = .paused
        case .ended:
            if next != nil { advance() } else { stop() }
            return
        case .error(let message): fail(message); return
        case .position(let time): position = time; return
        case .duration(let time): duration = time
        case .volume(let value):
            volume = min(100, max(0, value))
            settings.volume = volume
        case .mute(let value): muted = value
        case .speed(let value): speed = value
        }
        onChange?()
    }
}

/// 通过 AVKit 播放系统支持的媒体，静态图片使用独立视图显示。
final class SystemPlayer: NSObject, PlayerBackend, NSWindowDelegate {
    var onEvent: ((PlayerEvent) -> Void)?
    private var window: NSWindow?
    private var player: AVPlayer?
    private var imageTask: URLSessionDownloadTask?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var requestedRate: Float = 1
    private var initialPosition = 0.0
    private var ready = false
    private var imageVisible = false

    func open(_ media: CastMedia, position: Double, settings: Settings) throws {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = max(320, min(screen.width, screen.height * 16 / 9) * settings.playerSize.scale)
        let frame = NSRect(x: 0, y: 0, width: width, height: width * 9 / 16)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = media.title
        window.delegate = self
        window.level = settings.onTop ? .floating : .normal
        window.setFrameOrigin(settings.playerPosition.origin(in: screen, window: window.frame))
        self.window = window

        if media.isImage {
            let view = NSImageView(frame: frame)
            view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = view
            let request = URLRequest(url: media.url, timeoutInterval: 20)
            let task = URLSession.shared.downloadTask(with: request) { [weak self, weak view] file, response, _ in
                let data: Data?
                if let file, let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
                   let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 32 * 1024 * 1024 {
                    data = try? Data(contentsOf: file)
                } else { data = nil }
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.window != nil else { return }
                    guard let data, let image = NSImage(data: data), image.isValid else {
                        onEvent?(.error(AppMessage("Could not load the image.", "图片加载失败。")))
                        return
                    }
                    view.image = image
                    imageVisible = true
                    onEvent?(requestedRate == 0 ? .paused : .playing)
                }
            }
            imageTask = task
            task.resume()
        } else {
            let item = AVPlayerItem(url: media.url)
            let player = AVPlayer(playerItem: item)
            let view = AVPlayerView(frame: frame)
            view.player = player
            view.controlsStyle = .floating
            window.contentView = view
            self.player = player
            initialPosition = position
            observe(item, player: player)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if settings.playerSize == .fullScreen { window.toggleFullScreen(nil) }
    }

    private func observe(_ item: AVPlayerItem, player: AVPlayer) {
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.player?.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        ready = true
                        if initialPosition > 0 { seek(initialPosition) }
                        self.player?.rate = requestedRate
                        onEvent?(requestedRate == 0 ? .paused : .playing)
                    case .failed:
                        let message = item.error.map { AppMessage($0.localizedDescription) } ??
                            AppMessage("The media could not be played.", "媒体无法播放。")
                        onEvent?(.error(message))
                    default: break
                    }
                }
            },
            item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                guard seconds.isFinite, seconds >= 0 else { return }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(.duration(seconds)) }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, ready, self.player === player else { return }
                    if player.timeControlStatus == .paused {
                        requestedRate = 0
                        onEvent?(.paused)
                    } else if player.timeControlStatus == .playing {
                        requestedRate = player.rate
                        onEvent?(.playing)
                    }
                }
            },
            player.observe(\.volume, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.player === player else { return }
                    onEvent?(.volume(Int((player.volume * 100).rounded())))
                }
            },
            player.observe(\.isMuted, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.player === player else { return }
                    onEvent?(.mute(player.isMuted))
                }
            },
            player.observe(\.rate, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.player === player, player.rate > 0 else { return }
                    onEvent?(.speed(Double(player.rate)))
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600),
                                                     queue: .main) { [weak self] time in
            if time.seconds.isFinite, time.seconds >= 0 { self?.onEvent?(.position(time.seconds)) }
        }
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] _ in self?.onEvent?(.ended)
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let message = error.map { AppMessage($0.localizedDescription) } ??
                    AppMessage("Playback was interrupted.", "播放中断。")
                self?.onEvent?(.error(message))
            }
        ]
    }

    func play(speed: Double) {
        requestedRate = Float(speed)
        if ready { player?.rate = requestedRate }
        if imageVisible { onEvent?(.playing) }
    }

    func pause() {
        requestedRate = 0
        player?.pause()
    }

    func seek(_ seconds: Double) {
        if ready {
            player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else { initialPosition = seconds }
    }

    func volume(_ value: Int, muted: Bool) {
        player?.volume = Float(value) / 100
        player?.isMuted = muted
    }

    func stop() {
        imageTask?.cancel()
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onEvent?(.ended)
    }
}
