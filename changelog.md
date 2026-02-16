# Changelog

All notable changes to this project are tracked here.

## 2026-02-16

### Added
- Custom frameless desktop window behavior with custom title-bar controls and focus/nudge visual feedback.
- LAN discovery and peer sync improvements:
  - UDP presence over broadcast, directed broadcast, and multicast.
  - Manual peer probe/connect flow from settings.
  - TCP fallback for nudge delivery.
- Remote transfer features:
  - Drag-out virtual file transfer.
  - In-app transfer panel with `More details`, progress, rate, ETA, and status history.
  - `Download...` action for remote files with Save As dialog and direct file write to chosen destination.
- Persistent window state across restarts (position, size, maximized state).
- Windows icon extraction for shared files and transfer of icon metadata to peers.
- Theme presets selectable from the settings menu (Slate, Forest, Amber, Rose), applied to both light and dark modes.
- Hover readout for connected clients count (number-only) next to the settings cog.
- Subtle horizontal shake animation on nudge events for stronger visual feedback.
- Optional sound feedback on nudge, configurable via `Sound on nudge` toggle in Network Settings.
- Dedicated `Themes` window opened from settings, with expanded preset collection and live selection.
- Persistent app settings file (`settings.json`) for dark/light mode, selected theme preset, and nudge sound preference.
- Windows system tray integration with a `Minimize to tray` setting, tray menu (`Show FileShare` / `Exit`), and click-to-restore behavior.
- Tray notifications when hidden to tray and a remote file is added or a nudge is received.

### Changed
- Reduced discovery/refresh polling intervals to lower sync latency.
- Rebalanced discovery/refresh polling for responsiveness without UI stutter (`announce 700ms`, `refresh 350ms`, `min fetch 280ms`).
- Improved peer handling and deduplication to prevent duplicate file/peer entries.
- Connected peer count now tracks recent successful contact, reducing false zero-count states during asymmetric UDP scenarios.
- Simplified network settings UI to show core fields (device name, IP, port, peer list).
- Updated settings cog to proper inactive/hover/pressed behavior and smaller size.
- Reduced minimum window size so the window can be resized smaller.
- Empty-state drop hint now appears only while dragging over the window and only when no items are present.
- Probe action feedback improved with explicit `Sending...`, success, and invalid-IP states.
- UDP presence handling now avoids unnecessary full-UI refreshes when heartbeat packets contain no meaningful peer changes.
- Nudge sound now plays `assets/nudge.mp3` instead of the generated system beep.
- Transfer panel always shows full details (removed `More details` toggle).
- Finished transfer readouts now auto-dismiss after approximately 5 seconds.
- Decorative file-grid background now fades in only on pointer hover and only when files are present.
- App settings persistence now includes `minimizeToTray`.
- Bundled tray icon asset (`assets/FSICON.ico`) in Flutter assets for tray usage in built binaries.
- Cleaned `TODO.md` by removing completed items and resetting it to no open tasks.
- Tray icon visibility now matches tray state: it is created only while hidden to tray and removed again on restore.
- Custom titlebar minimize/close buttons now route through tray-aware handlers so `Minimize to tray` is applied consistently.
- Moved `Minimize to tray` control out of Network Settings and into the main settings cog popup as a checked menu toggle.
- Fixed minimize regression by using `bitsdojo` native minimize (`appWindow.minimize()`) for non-tray minimize in the custom titlebar flow.

### Fixed
- Fixed one-way visibility and stale peer pruning behavior.
- Fixed icon reuse bug where multiple dropped files could show the same icon.
- Fixed icon/grid refresh flicker by stabilizing tile identity and update behavior.
- Fixed one-way nudge behavior with protocol fallback and dedupe logic.
- Fixed settings popup menu collapsing into a tiny square by removing menu constraints from the settings cog button.
