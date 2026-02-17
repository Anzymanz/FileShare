# Changelog

All notable changes are documented by release version.

## [v0.0.3] - Unreleased

### Added
- Persistent diagnostics log at `%APPDATA%\\FileShare\\fileshare.log`.
- Crash report generation at `%APPDATA%\\FileShare\\crashes\\`.
- Windows drag cache materialization for remote files before drag-out (`%APPDATA%\\FileShare\\drag_cache\\`).

### Changed
- Local Windows drag-out now uses native file URI payloads for better target compatibility.
- Remote Windows drag-out now stages files in drag cache and exports clean filenames.

### Fixed
- Reduced drag provider crash paths and improved listener/sink cleanup around drag sessions.
- Fixed VS Code drag-over freeze/crash behavior when dragging shared files across chat/drop-capable windows.
- Fixed dragged filename pollution from internal ID prefixes.
- Restored drag-out behavior after regression caused by drag-provider gating logic.

## [v0.0.2] - 2026-02-17

### Added
- Bundled Microsoft Visual C++ Redistributable (x64) in the installer.
- Silent VC++ runtime install step during setup.

### Changed
- Updated installer architecture/install constants to remove Inno Setup deprecation warnings (`x64compatible`, `autopf`).
- Updated README install guidance and latest-release link.
- Expanded `.gitignore` for build/packaging artifacts.

### Fixed
- Fixed fresh-install startup failures caused by missing VC++ runtime DLLs (including `MSVCP140.dll`).

## [v0.0.1] - 2026-02-16

### Added
- Initial public release.
- LAN peer discovery and shared file sync.
- Drag-and-drop sharing and remote downloads.
- Transfer progress panel with status/rate/ETA.
- Nudge system with visual feedback and optional sound.
- Custom frameless window UI and theme presets.
- Minimize-to-tray mode and tray notifications.
- Persistent app/window settings.

### Changed
- Tuned discovery and refresh intervals for lower latency.
- Improved peer dedupe and connected-peer reliability.
- Simplified settings presentation and expanded theme selection.

### Fixed
- One-way peer/file visibility edge cases.
- Icon extraction/reuse and grid refresh flicker issues.
- Nudge delivery fallback/dedupe issues.
