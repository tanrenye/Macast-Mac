import AppKit
import Darwin
import Foundation
import OSLog
import ServiceManagement

/// 本地设置和临时启动参数。命令行覆盖不会修改已保存的配置。
final class Settings {
    private let defaults = UserDefaults.standard
    var nameOverride: String?
    var portOverride: UInt16?
    var playerOverride: PlayerKind?

    var uuid: String {
        if let value = defaults.string(forKey: "uuid"), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: "uuid")
        return value
    }
    var name: String {
        get { nameOverride ?? defaults.string(forKey: "name") ?? "MyCast (\(Host.current().localizedName ?? "Mac"))" }
        set { nameOverride = nil; defaults.set(newValue, forKey: "name") }
    }
    var port: UInt16 {
        get { portOverride ?? UInt16(clamping: defaults.integer(forKey: "port")) }
        set { portOverride = nil; defaults.set(Int(newValue), forKey: "port") }
    }
    var player: PlayerKind {
        get { playerOverride ?? PlayerKind(rawValue: defaults.string(forKey: "player") ?? "") ?? .automatic }
        set { playerOverride = nil; defaults.set(newValue.rawValue, forKey: "player") }
    }
    var blocked: Set<String> {
        get { Set(defaults.stringArray(forKey: "blocked") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "blocked") }
    }
    var volume: Int {
        get { min(100, max(0, defaults.object(forKey: "volume") as? Int ?? 100)) }
        set { defaults.set(newValue, forKey: "volume") }
    }
    var playerSize: PlayerSize {
        get { PlayerSize(rawValue: defaults.object(forKey: "playerSize") as? Int ?? -1) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "playerSize") }
    }
    var playerPosition: PlayerPosition {
        get { PlayerPosition(rawValue: defaults.object(forKey: "playerPosition") as? Int ?? -1) ?? .topRight }
        set { defaults.set(newValue.rawValue, forKey: "playerPosition") }
    }
    var hardwareDecode: Bool {
        get { defaults.object(forKey: "hardwareDecode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hardwareDecode") }
    }
    var onTop: Bool {
        get { defaults.bool(forKey: "onTop") }
        set { defaults.set(newValue, forKey: "onTop") }
    }
    var colorIcon: Bool {
        get { defaults.bool(forKey: "colorIcon") }
        set { defaults.set(newValue, forKey: "colorIcon") }
    }
    var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyCast", isDirectory: true)
    }
    var mpvConfig: URL { directory.appendingPathComponent("mpv", isDirectory: true) }
}

/// 管理监听器、菜单栏和播放器生命周期。所有状态在主队列更新。
final class CastApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings: Settings
    private let playback: Playback
    private let dlna: DLNA
    private let headless: Bool
    private var http: HTTPServer?
    private var ssdp: SSDP?
    private var currentPort: UInt16?
    private var playbackError: String?
    private var statusItem: NSStatusItem?
    private var preferencesWindow: PreferencesWindow?
    private var stoppingSignals: [DispatchSourceSignal] = []
    private let playbackLogger = Logger(subsystem: "local.mycast.receiver", category: "Playback")

    init(settings: Settings, headless: Bool) {
        self.settings = settings
        self.headless = headless
        playback = Playback(settings: settings)
        dlna = DLNA(playback: playback, settings: settings)
        super.init()
        playback.onChange = { [weak self] in
            guard let self else { return }
            if playback.status == "OK" { playbackError = nil }
            dlna.publishChanges()
        }
        playback.onError = { [weak self] message in
            self?.log(message)
            self?.playbackError = message
            self?.playbackLogger.error("Playback failed: \(message, privacy: .private)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !headless {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = "MyCast"
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
            refreshIcon()
        }
        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            stoppingSignals.append(source)
        }
        startReceiver()
    }

    func applicationWillTerminate(_ notification: Notification) { stopReceiver() }

    private func startReceiver() {
        guard http == nil else { return }
        do {
            let server = try HTTPServer(port: settings.port)
            server.handle = { [weak self] request in self?.dlna.handle(request) ?? HTTPResponse(status: 404) }
            server.ready = { [weak self, weak server] port in
                guard let self, http === server else { return }
                do {
                    let discovery = SSDP(uuid: settings.uuid, port: port, blocked: settings.blocked)
                    try discovery.start()
                    ssdp = discovery
                    currentPort = port
                    refreshIcon()
                    log("MyCast listening on port \(port)")
                } catch {
                    receiverFailed("SSDP 启动失败。\(error.localizedDescription)")
                }
            }
            server.failed = { [weak self, weak server] error in
                guard let self, http === server else { return }
                receiverFailed("HTTP 监听失败。\(error.localizedDescription)")
            }
            http = server
            server.start()
            refreshIcon()
        } catch {
            receiverFailed("HTTP 监听失败。\(error.localizedDescription)")
        }
    }

    private func stopReceiver() {
        ssdp?.stop()
        ssdp = nil
        http?.stop()
        http = nil
        currentPort = nil
        dlna.reset()
        playback.setMedia(nil)
        refreshIcon()
    }

    private func receiverFailed(_ message: String) {
        stopReceiver()
        log(message)
        if headless { exit(1) }
        showError(message)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func refreshIcon() {
        let symbol = currentPort == nil ? "tv.slash" : "tv.and.mediabox"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "MyCast")
        icon?.isTemplate = !settings.colorIcon
        statusItem?.button?.image = icon
        statusItem?.button?.contentTintColor = settings.colorIcon ? .systemBlue : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(settings.name))
        if let currentPort {
            menu.addItem(item("DLNA 端口 \(currentPort)"))
            let endpoints = NSMenu()
            let addresses = ssdp?.interfaces ?? []
            for address in addresses {
                endpoints.addItem(item("\(address.address):\(currentPort)（\(address.name)）", #selector(copyAddress(_:)),
                                       data: "http://\(address.address):\(currentPort)"))
            }
            if addresses.isEmpty { endpoints.addItem(item("没有可用的局域网网卡")) }
            let entry = item("局域网地址")
            entry.isEnabled = true
            entry.submenu = endpoints
            menu.addItem(entry)
            if let ssdp {
                let diagnostics = NSMenu()
                if let search = ssdp.lastSearch, let time = ssdp.lastSearchTime {
                    diagnostics.addItem(item("\(time.formatted(date: .omitted, time: .standard)) · \(search)"))
                } else {
                    diagnostics.addItem(item("本次启动后尚未收到其他设备的 SSDP 搜索"))
                }
                if let error = ssdp.lastError { diagnostics.addItem(item("最近一次错误 · \(error)")) }
                diagnostics.addItem(item(dlna.lastAction ?? "本次启动后尚未收到播放控制指令"))
                if let address = addresses.first {
                    diagnostics.addItem(item("复制手机检测地址", #selector(copyAddress(_:)),
                                             data: "http://\(address.address):\(currentPort)/description.xml"))
                }
                let diagnosticItem = item("发现诊断")
                diagnosticItem.isEnabled = true
                diagnosticItem.submenu = diagnostics
                menu.addItem(diagnosticItem)
            }
        } else {
            menu.addItem(item(http == nil ? "投屏接收已关闭" : "正在启动投屏服务…"))
        }
        menu.addItem(.separator())
        menu.addItem(item(http == nil ? "开始接收投屏" : "停止接收投屏", #selector(toggleReceiver)))
        if let media = playback.media {
            let mediaTitle = media.title.count > 48 ? String(media.title.prefix(48)) + "…" : media.title
            menu.addItem(item(mediaTitle))
            if playbackError != nil { menu.addItem(item("查看播放错误…", #selector(showPlaybackError))) }
            menu.addItem(item("复制媒体链接", #selector(copyMedia), key: "c"))
            menu.addItem(item(playback.state == .playing || playback.state == .loading ? "暂停" : "播放", #selector(togglePlayback)))
            menu.addItem(item("停止播放", #selector(stopPlayback)))
        }
        menu.addItem(.separator())
        let players = NSMenu()
        for kind in PlayerKind.allCases {
            let option = item(kind.title, #selector(selectPlayer(_:)), data: kind.rawValue)
            option.state = settings.player == kind ? .on : .off
            players.addItem(option)
        }
        let player = item("播放器")
        player.isEnabled = true
        player.submenu = players
        menu.addItem(player)
        menu.addItem(item("设置…", #selector(preferences), key: ","))
        menu.addItem(item("打开配置目录", #selector(openConfiguration)))
        let login = item("登录时启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("帮助与原版项目", #selector(openHelp)))
        menu.addItem(item("退出 MyCast", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector? = nil, key: String = "", data: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        item.representedObject = data
        return item
    }

    @objc private func toggleReceiver() {
        if http == nil { startReceiver() } else { stopReceiver() }
    }

    @objc private func togglePlayback() {
        if playback.state == .playing || playback.state == .loading { playback.pause() }
        else { playback.play(speed: playback.speed) }
    }

    @objc private func stopPlayback() { playback.stop() }

    @objc private func showPlaybackError() {
        if let playbackError { showError(playbackError) }
    }

    @objc private func copyMedia() {
        if let media = playback.media { copy(media.url.absoluteString) }
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String { copy(value) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func selectPlayer(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let kind = PlayerKind(rawValue: value) else { return }
        settings.player = kind
    }

    @objc private func preferences() {
        if let preferencesWindow, preferencesWindow.window?.isVisible == true {
            preferencesWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = PreferencesWindow(settings: settings, volume: playback.volume) { [weak self] restart, volume in
            guard let self else { return }
            if restart && http != nil {
                stopReceiver()
                startReceiver()
            }
            playback.setVolume(volume)
            refreshIcon()
        }
        preferencesWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func openConfiguration() {
        do {
            try FileManager.default.createDirectory(at: settings.mpvConfig, withIntermediateDirectories: true)
            NSWorkspace.shared.open(settings.directory)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/xfangfang/Macast/wiki")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MyCast"
        alert.informativeText = message
        alert.runModal()
    }
}

let settings = Settings()
var args = Array(CommandLine.arguments.dropFirst())
var headless = false
let usage = "用法：MyCast [--headless] [--name 名称] [--port 0…65535] [--player automatic|system|mpv|iina]"
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--help", "-h": print(usage); exit(0)
    case "--headless": headless = true
    case "--name":
        guard !args.isEmpty, !args[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args[0].count <= 100 else { print(usage); exit(2) }
        settings.nameOverride = args.removeFirst()
    case "--port":
        guard !args.isEmpty, let port = UInt16(args.removeFirst()) else { print(usage); exit(2) }
        settings.portOverride = port
    case "--player":
        guard !args.isEmpty, let player = PlayerKind(rawValue: args.removeFirst()) else { print(usage); exit(2) }
        settings.playerOverride = player
    default:
        guard flag.hasPrefix("-psn_") else { print(usage); exit(2) }
    }
}
let application = NSApplication.shared
application.setActivationPolicy(headless ? .prohibited : .accessory)
let delegate = CastApp(settings: settings, headless: headless)
application.delegate = delegate
application.run()
