# Macast-Mac

English | [简体中文](README.zh-CN.md)

MyCast is a macOS menu bar DLNA receiver written in Swift with AppKit. It requires macOS 13 or later. Its device discovery and playback controls are based on [Macast](https://github.com/xfangfang/Macast).

## Install

Download the universal DMG from [GitHub Releases](https://github.com/tanrenye/Macast-Mac/releases). Open the disk image and drag MyCast into Applications. The DMG supports both Apple silicon and Intel Macs. The app is ad hoc signed and has no Apple notarization.

To build from source, install the Xcode Command Line Tools or Xcode, then run these commands from the repository root.

```sh
./scripts/build-app.sh
open dist/MyCast.app
```

The build script produces an ad hoc signed app for the current architecture. For distribution with Apple notarization, sign the app with a Developer ID certificate and submit it for notarization.

## Cast to your Mac

Connect your phone and Mac to the same local network. Open MyCast, then select **MyCast (computer name)** from the DLNA casting list in your phone's media player. If macOS asks for local network access, allow it and search again.

Use the menu bar icon to start or stop receiving casts, see the listening port, copy the current media link, or change the device name in Settings.

### Playback and settings

To change the interface language, open **Settings… → Language** (or **设置… → 语言**), select **English** or **简体中文**, and click **Save**. MyCast remembers your choice and applies it without restarting the receiver. Until you choose a language, MyCast uses the best match from your macOS language preferences, with English as the fallback.

In automatic mode, MyCast prefers mpv when available and falls back to the built-in macOS player. Use the **Player** menu to select IINA or choose a specific player. MyCast looks for mpv in its app bundle, in standard Homebrew and MacPorts locations, and on `PATH`. It looks for IINA in `/Applications` and `~/Applications`. The built-in player supports the formats AVFoundation can play. Install mpv for additional formats such as MKV.

To customize mpv, select **Open Configuration Folder** and put `mpv.conf` or `input.conf` in the `mpv` subfolder.

MyCast saves settings such as the device name, port, network interface exclusions, volume, window size and position, and whether the player window stays on top. Set the port to `0` to let macOS assign one. Open the MyCast menu to see the active port. To launch MyCast automatically at login, move it to Applications and enable **Launch at Login** from the menu.

### Troubleshoot discovery

If your phone cannot find MyCast, choose **Discovery Diagnostics → Copy Phone Test Address** and open the address in your phone's browser. If the device description XML loads, the phone can reach the receiver's HTTP port. Search again in the phone app and check the diagnostics menu to see whether MyCast received and answered the SSDP search.

You can check MyCast's local network permission in **System Settings → Privacy & Security → Local Network**. After rebuilding an ad hoc signed app, macOS may need to refresh its cached permission. If access is enabled but the SSDP diagnostics report “No route to host,” quit MyCast from the menu bar and reopen it.

## Command line

```sh
swift run MyCast --headless --name "Living Room Mac" --port 1068 --player system
```

`--headless` hides the menu bar icon. Incoming casts still open in the selected player. The same options work with `dist/MyCast.app/Contents/MacOS/MyCast`.

## Features

- IPv4 SSDP discovery and device announcements across multiple network interfaces, with automatic refresh when the network changes.
- DLNA AVTransport, RenderingControl, ConnectionManager, and GENA for casting video, audio, and images. Controls cover play, pause, stop, seeking, volume, mute, and advancing to the next item.
- Native settings, menu bar status, media link copying, launch at login, and playback controls for mpv and IINA.

The Swift port integrates IINA directly. The original project's Python plugin loader and plugin store, proprietary Bilibili casting protocol (NVA) and on-screen comments, update checker, and Windows and Linux versions are outside the current scope.
