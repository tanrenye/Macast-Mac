import AppKit

/// 独立设置窗口。显示设置时主事件循环仍能处理投屏搜索和请求。
final class PreferencesWindow: NSWindowController {
    private let settings: Settings
    private let apply: (_ restartReceiver: Bool, _ volume: Int) -> Void
    private let name = NSTextField()
    private let port = NSTextField()
    private let blocked = NSTextField()
    private let volume = NSTextField()
    private let size = NSPopUpButton()
    private let position = NSPopUpButton()
    private let hardware = NSButton(checkboxWithTitle: "硬件解码（mpv 和 IINA）", target: nil, action: nil)
    private let onTop = NSButton(checkboxWithTitle: "播放窗口置顶", target: nil, action: nil)
    private let icon = NSButton(checkboxWithTitle: "使用彩色菜单栏图标", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")

    init(settings: Settings, volume currentVolume: Int, apply: @escaping (Bool, Int) -> Void) {
        self.settings = settings
        self.apply = apply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "MyCast 设置"
        window.isReleasedWhenClosed = false

        name.stringValue = settings.name
        port.stringValue = String(settings.port)
        blocked.stringValue = settings.blocked.sorted().joined(separator: ", ")
        blocked.placeholderString = "例如 en5, en6"
        volume.stringValue = String(currentVolume)
        size.addItems(withTitles: PlayerSize.labels)
        size.selectItem(at: settings.playerSize.rawValue)
        position.addItems(withTitles: PlayerPosition.labels)
        position.selectItem(at: settings.playerPosition.rawValue)
        hardware.state = settings.hardwareDecode ? .on : .off
        onTop.state = settings.onTop ? .on : .off
        icon.state = settings.colorIcon ? .on : .off

        let fields: [(String, NSView)] = [
            ("投屏设备名", name), ("HTTP 端口（0 为自动）", port),
            ("排除网卡", blocked), ("音量（0–100）", volume),
            ("窗口大小", size), ("窗口位置", position)
        ]
        let rows = fields.map { title, control in [NSTextField(labelWithString: title) as NSView, control] }
        let grid = NSGridView(views: rows + [hardware, onTop, icon].map { [NSGridCell.emptyContentView, $0] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 250
        grid.column(at: 1).xPlacement = .leading
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        for field in [name, port, blocked, volume] {
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8
        message.stringValue = "更改设备名、端口或网卡会重新启动正在运行的接收服务。"
        message.textColor = .secondaryLabelColor

        guard let content = window.contentView else { return }
        for view in [grid, message, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: message.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.initialFirstResponder = name
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func cancelEditing() { close() }

    @objc private func saveSettings() {
        let friendlyName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !friendlyName.isEmpty, friendlyName.count <= 100 else {
            validationError("设备名须为 1 到 100 个字符。", field: name)
            return
        }
        guard let newPort = UInt16(port.stringValue.trimmingCharacters(in: .whitespaces)) else {
            validationError("端口须为 0 到 65535 的整数。", field: port)
            return
        }
        guard let newVolume = Int(volume.stringValue.trimmingCharacters(in: .whitespaces)),
              (0...100).contains(newVolume) else {
            validationError("音量须为 0 到 100 的整数。", field: volume)
            return
        }
        let interfaces = Set(blocked.stringValue.split(separator: ",").compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        })
        let restart = settings.port != newPort || settings.name != friendlyName || settings.blocked != interfaces
        settings.name = friendlyName
        settings.port = newPort
        settings.blocked = interfaces
        settings.playerSize = PlayerSize(rawValue: size.indexOfSelectedItem) ?? .normal
        settings.playerPosition = PlayerPosition(rawValue: position.indexOfSelectedItem) ?? .topRight
        settings.hardwareDecode = hardware.state == .on
        settings.onTop = onTop.state == .on
        settings.colorIcon = icon.state == .on
        close()
        apply(restart, newVolume)
    }

    private func validationError(_ text: String, field: NSTextField) {
        message.stringValue = text
        message.textColor = .systemRed
        window?.makeFirstResponder(field)
    }
}
