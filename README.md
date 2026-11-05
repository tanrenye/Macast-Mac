# Macast-Mac

MyCast 是用 Swift 和 AppKit 编写的 macOS 菜单栏 DLNA 接收器，参考了 [Macast](https://github.com/xfangfang/Macast) 的设备发现、控制接口和播放流程。需要 macOS 13 或更高版本。

## 构建和使用

在 [GitHub Releases](https://github.com/tanrenye/Macast-Mac/releases) 下载通用 DMG。打开磁盘映像，把 MyCast 拖到 Applications。该安装包包含 Apple 芯片和 Intel 两种架构，使用本地签名，未经过 Apple 公证。

安装 Xcode Command Line Tools 或 Xcode 后，在仓库根目录执行：

```sh
./scripts/build-app.sh
open dist/MyCast.app
```

把手机和 Mac 连到同一个局域网。打开 MyCast，在手机播放器的 **DLNA 投屏** 列表中选择 **MyCast（电脑名称）**。如果 macOS 弹出本地网络权限提示，允许后重新搜索。菜单栏可以暂停接收、查看监听端口、复制媒体链接和修改设备名。

默认优先使用已安装的 mpv，没有 mpv 时使用 macOS 系统播放器。可以从菜单中切换到 **IINA** 或固定选用某个播放器。MyCast 会在 Homebrew、MacPorts 和 PATH 中查找 mpv，在系统及用户的 Applications 文件夹中查找 IINA。系统播放器的格式范围取决于 AVFoundation。需要 MKV 等更多格式时可以安装 mpv。使用 mpv 时，在菜单中打开配置目录，然后在其中的 `mpv` 目录放置 `mpv.conf` 或 `input.conf`。

设备名、端口、网卡排除规则、音量、窗口大小、位置和置顶等设置会保存。端口设为 `0` 时由系统分配，实际端口显示在菜单栏。需要登录后自动运行时，将应用移动到 Applications 文件夹，再从菜单中启用 **登录时启动**。

手机搜不到时，打开 **发现诊断 → 复制手机检测地址**，在手机浏览器打开该地址。能看到设备 XML 表示手机可以访问接收器的 HTTP 端口。回到手机 App 再搜一次，然后查看 **发现诊断** 是否记录了这次 SSDP 搜索和应答。也可以在 Mac 的 **系统设置 → 隐私与安全性 → 本地网络** 查看 MyCast 的权限。本地签名的应用重建后，macOS 可能需要刷新授权缓存。如果权限已开启，但诊断显示 SSDP 发包时「无到主机的路由」，请从菜单栏退出 MyCast，再重新打开应用。

## 命令行

```sh
swift run MyCast --headless --name "客厅 Mac" --port 1068 --player system
```

`--headless` 隐藏菜单栏图标，收到投屏时仍会调用所选播放器。选项也适用于 `dist/MyCast.app/Contents/MacOS/MyCast`。

## 功能范围

- IPv4 多网卡 SSDP 搜索及设备广播，网络变化时自动刷新。
- DLNA AVTransport、RenderingControl、ConnectionManager 和 GENA，支持视频、音频和图片投放，以及播放、暂停、停止、进度、音量、静音和下一条媒体。
- 原生设置、菜单栏状态、复制投屏链接、登录启动，以及 mpv 和 IINA 的播放控制。
- 原版的 Python 插件加载和插件商店、哔哩必连（NVA）私有协议及弹幕、原版更新检查，以及 Windows 和 Linux 版本目前未移植。IINA 已在 Swift 版中直接集成。
- 构建脚本输出当前架构的本地签名应用。用于分发时需另行完成 Developer ID 签名及公证。
