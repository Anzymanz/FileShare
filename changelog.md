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

### Changed
- Reduced discovery/refresh polling intervals to lower sync latency.
- Improved peer handling and deduplication to prevent duplicate file/peer entries.
- Simplified network settings UI to show core fields (device name, IP, port, peer list).
- Updated settings cog to proper inactive/hover/pressed behavior and smaller size.
- Reduced minimum window size so the window can be resized smaller.

### Fixed
- Fixed one-way visibility and stale peer pruning behavior.
- Fixed icon reuse bug where multiple dropped files could show the same icon.
- Fixed icon/grid refresh flicker by stabilizing tile identity and update behavior.
- Fixed one-way nudge behavior with protocol fallback and dedupe logic.
- Fixed settings popup menu collapsing into a tiny square by removing menu constraints from the settings cog button.
