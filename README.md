# FileShare

FileShare is a lightweight Windows desktop app for local-network file sharing between nearby PCs.

## Features

- Minimal custom desktop UI with dark/light theme support (dark by default).
- Drag and drop files/folders into the window to share with connected peers.
- Peer discovery over LAN with manual connect fallback.
- Shared items stay visible in both windows until removed.
- Download remote files with a Save As dialog.
- Per-file transfer progress with speed/ETA readout.
- Optional nudge signal (visual + sound) to get a peer's attention.
- Minimize-to-tray mode with tray restore/exit actions and notifications.
- Persistent settings and window state across restarts.

## Requirements

- Windows 10/11 x64
- Local network connectivity between peers

## Usage Scope

FileShare is intended for small, trusted local networks with a limited number of computers.

## Install

Use the installer from `dist/installer` for packaged builds.

## Run From Source

```powershell
cd F:\Flutter\FileShare
flutter pub get
flutter run -d windows
```

## Build Installer

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_installer.ps1 --app-version 0.0.1
```
