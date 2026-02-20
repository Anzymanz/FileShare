import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:fileshare/network_validation.dart' as nv;
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart' as clip;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:win32/win32.dart' as win32;
import 'package:window_manager/window_manager.dart';

const int _discoveryPort = 40405;
const int _transferPort = 40406;
const String _discoveryMulticastGroup = '239.255.77.77';
const String _tag = 'fileshare_lan_v2';
const String _latestReleaseApiUrl =
    'https://api.github.com/repos/Anzymanz/FileShare/releases/latest';
const String _allReleasesApiUrl =
    'https://api.github.com/repos/Anzymanz/FileShare/releases';
const String _latestReleasePageUrl =
    'https://github.com/Anzymanz/FileShare/releases/latest';
const String _windowsRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String _windowsRunValueName = 'FileShare';
const String _simLatencyEnv = 'FILESHARE_SIM_LATENCY_MS';
const String _simDropEnv = 'FILESHARE_SIM_DROP_PERCENT';
const int _protocolMajor = 1;
const int _protocolMinor = 0;
const int _maxHeaderBytes = 5 * 1024 * 1024;
const int _maxUdpDatagramBytes = 16 * 1024;
const int _maxManifestItems = 5000;
const int _maxItemNameChars = 260;
const int _maxRelativePathChars = 1024;
const int _maxPeerNameChars = 80;
const int _maxPeerIdChars = 128;
const int _maxIconBytes = 256 * 1024;
const int _maxIconBase64Chars = 360 * 1024;
const int _maxItemNoteChars = 300;
const int _maxConcurrentInboundClients = 64;
const int _maxConcurrentTransfersPerPeer = 3;
const int _perPeerUploadRateLimitBytesPerSecond = 50 * 1024 * 1024;
const int _perPeerDownloadRateLimitBytesPerSecond = 50 * 1024 * 1024;
const int _dragCacheMaxBytes = 2 * 1024 * 1024 * 1024; // 2 GiB
const Duration _dragCacheMaxAge = Duration(days: 7);
const Duration _housekeepingInterval = Duration(minutes: 15);
const Size _minWindowSize = Size(420, 280);
const Size _defaultWindowSize = Size(900, 600);
const Duration _announceInterval = Duration(milliseconds: 700);
const Duration _refreshInterval = Duration(milliseconds: 350);
const Duration _announceIntervalHighReliability = Duration(milliseconds: 450);
const Duration _refreshIntervalHighReliability = Duration(milliseconds: 220);
const Duration _announceIntervalLowTraffic = Duration(milliseconds: 1400);
const Duration _refreshIntervalLowTraffic = Duration(milliseconds: 800);
const Duration _minFetchInterval = Duration(milliseconds: 280);
const Duration _pruneInterval = Duration(seconds: 3);
const Duration _peerPruneAfter = Duration(seconds: 45);
final bool _isTest =
    bool.fromEnvironment('FLUTTER_TEST') ||
    Platform.environment.containsKey('FLUTTER_TEST');
final _Diagnostics _diagnostics = _Diagnostics();

final ffi.DynamicLibrary _user32 = ffi.DynamicLibrary.open('user32.dll');

typedef _FlashWindowExNative =
    ffi.Int32 Function(ffi.Pointer<_FLASHWINFO> info);
typedef _FlashWindowExDart = int Function(ffi.Pointer<_FLASHWINFO> info);

final _FlashWindowExDart _flashWindowEx = _user32
    .lookupFunction<_FlashWindowExNative, _FlashWindowExDart>('FlashWindowEx');

final class _FLASHWINFO extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;

  @ffi.IntPtr()
  external int hwnd;

  @ffi.Uint32()
  external int dwFlags;

  @ffi.Uint32()
  external int uCount;

  @ffi.Uint32()
  external int dwTimeout;
}

const int _flashTray = 0x00000002;
const int _flashTimerNoFg = 0x0000000C;

class _ThemePreset {
  const _ThemePreset({required this.name, required this.seed});

  final String name;
  final Color seed;
}

const List<_ThemePreset> _themePresets = [
  _ThemePreset(name: 'Slate', seed: Color(0xFF4A5D73)),
  _ThemePreset(name: 'Ocean', seed: Color(0xFF1F6F8B)),
  _ThemePreset(name: 'Arctic', seed: Color(0xFF2A7DA7)),
  _ThemePreset(name: 'Forest', seed: Color(0xFF2F6B4F)),
  _ThemePreset(name: 'Moss', seed: Color(0xFF5C7A3D)),
  _ThemePreset(name: 'Sage', seed: Color(0xFF6A7B68)),
  _ThemePreset(name: 'Amber', seed: Color(0xFF8A5A15)),
  _ThemePreset(name: 'Copper', seed: Color(0xFF8C4F2D)),
  _ThemePreset(name: 'Cherry', seed: Color(0xFF8C2F39)),
  _ThemePreset(name: 'Rose', seed: Color(0xFF7A3D4F)),
  _ThemePreset(name: 'Lilac', seed: Color(0xFF6D5A8A)),
  _ThemePreset(name: 'Graphite', seed: Color(0xFF424750)),
  _ThemePreset(name: 'Midnight', seed: Color(0xFF263046)),
];

enum ItemSourceFilter { all, local, remote }

enum ItemTypeFilter { all, image, document, media, archive, other }

enum ItemSortMode {
  ownerThenName,
  nameAsc,
  sizeDesc,
  sizeAsc,
  dateAddedDesc,
  dateAddedAsc,
}

enum ItemLayoutMode { grid, list }

enum UpdateChannel { stable, beta, nightly }

enum DiscoveryProfile { highReliability, balanced, lowTraffic }

String itemSourceFilterLabel(ItemSourceFilter filter) {
  switch (filter) {
    case ItemSourceFilter.all:
      return 'All sources';
    case ItemSourceFilter.local:
      return 'Local only';
    case ItemSourceFilter.remote:
      return 'Remote only';
  }
}

String itemTypeFilterLabel(ItemTypeFilter filter) {
  switch (filter) {
    case ItemTypeFilter.all:
      return 'All types';
    case ItemTypeFilter.image:
      return 'Images';
    case ItemTypeFilter.document:
      return 'Documents';
    case ItemTypeFilter.media:
      return 'Media';
    case ItemTypeFilter.archive:
      return 'Archives';
    case ItemTypeFilter.other:
      return 'Other';
  }
}

String itemSortModeLabel(ItemSortMode mode) {
  switch (mode) {
    case ItemSortMode.ownerThenName:
      return 'Owner / Name';
    case ItemSortMode.nameAsc:
      return 'Name A-Z';
    case ItemSortMode.sizeDesc:
      return 'Size Largest';
    case ItemSortMode.sizeAsc:
      return 'Size Smallest';
    case ItemSortMode.dateAddedDesc:
      return 'Date Added (Newest)';
    case ItemSortMode.dateAddedAsc:
      return 'Date Added (Oldest)';
  }
}

String updateChannelLabel(UpdateChannel channel) {
  switch (channel) {
    case UpdateChannel.stable:
      return 'Stable';
    case UpdateChannel.beta:
      return 'Beta';
    case UpdateChannel.nightly:
      return 'Nightly';
  }
}

String discoveryProfileLabel(DiscoveryProfile profile) {
  switch (profile) {
    case DiscoveryProfile.highReliability:
      return 'High reliability';
    case DiscoveryProfile.balanced:
      return 'Balanced';
    case DiscoveryProfile.lowTraffic:
      return 'Low traffic';
  }
}

DiscoveryProfile selectDiscoveryProfile({
  required int connectedPeers,
  required int repeatedFetchFailures,
  required int rateLimitEvents,
}) {
  if (connectedPeers == 0 || repeatedFetchFailures > 0) {
    return DiscoveryProfile.highReliability;
  }
  if (connectedPeers >= 4 || rateLimitEvents >= 40) {
    return DiscoveryProfile.lowTraffic;
  }
  return DiscoveryProfile.balanced;
}

UpdateChannel updateChannelFromString(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'beta':
      return UpdateChannel.beta;
    case 'nightly':
      return UpdateChannel.nightly;
    default:
      return UpdateChannel.stable;
  }
}

String updateChannelToString(UpdateChannel channel) {
  switch (channel) {
    case UpdateChannel.stable:
      return 'stable';
    case UpdateChannel.beta:
      return 'beta';
    case UpdateChannel.nightly:
      return 'nightly';
  }
}

List<String> buildNetworkDiagnosticsHints({
  required int connectedPeers,
  required List<String> localIps,
  required Map<String, int> diagnostics,
  required bool hasIncompatiblePeers,
  required bool roomKeyEnabled,
}) {
  final hints = <String>[];
  if (localIps.isEmpty) {
    hints.add('No active IPv4 address detected. Check adapter/Wi-Fi state.');
  }
  if (connectedPeers == 0) {
    hints.add('No peers connected. Use Send Probe and manual Connect TCP.');
  }
  if (hasIncompatiblePeers) {
    hints.add('Version mismatch detected. Install the same major app version.');
  }
  if ((diagnostics['udp_auth_drop'] ?? 0) > 0 ||
      (diagnostics['tcp_auth_drop'] ?? 0) > 0) {
    if (roomKeyEnabled) {
      hints.add(
        'Auth drops detected. Confirm both peers use the same room key.',
      );
    } else {
      hints.add(
        'Auth drops detected. If unexpected, clear and re-enter room keys.',
      );
    }
  }
  if ((diagnostics['udp_protocol_mismatch'] ?? 0) > 0 ||
      (diagnostics['tcp_protocol_mismatch'] ?? 0) > 0) {
    hints.add(
      'Protocol mismatch traffic detected. Upgrade/downgrade peer app.',
    );
  }
  if ((diagnostics['udp_rate_limited'] ?? 0) > 0 ||
      (diagnostics['tcp_req_rate_limited'] ?? 0) > 0) {
    hints.add('Rate limiting is active. Reduce rapid probes/reconnect loops.');
  }
  hints.add(
    'Ensure Windows Firewall allows UDP 40405 and TCP 40406 for both peers.',
  );
  hints.add('Keep both app windows open during discovery and first sync.');
  return hints;
}

bool _matchesItemTypeFilter(ShareItem item, ItemTypeFilter filter) {
  if (filter == ItemTypeFilter.all) return true;
  final ext = p.extension(item.name).toLowerCase();
  const imageExts = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.svg',
    '.ico',
    '.heic',
    '.tif',
    '.tiff',
  };
  const docExts = {
    '.txt',
    '.md',
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.csv',
    '.rtf',
    '.log',
  };
  const mediaExts = {
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.ogg',
    '.aac',
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
    '.wmv',
    '.webm',
  };
  const archiveExts = {'.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz'};
  final isImage = imageExts.contains(ext);
  final isDocument = docExts.contains(ext);
  final isMedia = mediaExts.contains(ext);
  final isArchive = archiveExts.contains(ext);
  switch (filter) {
    case ItemTypeFilter.all:
      return true;
    case ItemTypeFilter.image:
      return isImage;
    case ItemTypeFilter.document:
      return isDocument;
    case ItemTypeFilter.media:
      return isMedia;
    case ItemTypeFilter.archive:
      return isArchive;
    case ItemTypeFilter.other:
      return !isImage && !isDocument && !isMedia && !isArchive;
  }
}

List<ShareItem> computeVisibleItems({
  required List<ShareItem> items,
  required String query,
  required ItemSourceFilter sourceFilter,
  required ItemTypeFilter typeFilter,
  required ItemSortMode sortMode,
  required Map<String, DateTime> firstSeenByKey,
}) {
  final needle = query.trim().toLowerCase();
  final filtered = items
      .where((item) {
        if (sourceFilter == ItemSourceFilter.local && !item.local) return false;
        if (sourceFilter == ItemSourceFilter.remote && item.local) return false;
        if (!_matchesItemTypeFilter(item, typeFilter)) return false;
        if (needle.isEmpty) return true;
        final name = item.name.toLowerCase();
        final rel = item.rel.toLowerCase();
        final owner = item.owner.toLowerCase();
        final ext = p.extension(item.name).toLowerCase();
        return name.contains(needle) ||
            rel.contains(needle) ||
            owner.contains(needle) ||
            ext.contains(needle);
      })
      .toList(growable: false);

  int compareName(ShareItem a, ShareItem b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    return a.key.compareTo(b.key);
  }

  int compareAdded(ShareItem a, ShareItem b) {
    final atA = firstSeenByKey[a.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
    final atB = firstSeenByKey[b.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = atA.compareTo(atB);
    if (byTime != 0) return byTime;
    return compareName(a, b);
  }

  filtered.sort((a, b) {
    switch (sortMode) {
      case ItemSortMode.ownerThenName:
        final byOwner = a.owner.toLowerCase().compareTo(b.owner.toLowerCase());
        if (byOwner != 0) return byOwner;
        return compareName(a, b);
      case ItemSortMode.nameAsc:
        return compareName(a, b);
      case ItemSortMode.sizeDesc:
        final bySize = b.size.compareTo(a.size);
        if (bySize != 0) return bySize;
        return compareName(a, b);
      case ItemSortMode.sizeAsc:
        final bySize = a.size.compareTo(b.size);
        if (bySize != 0) return bySize;
        return compareName(a, b);
      case ItemSortMode.dateAddedDesc:
        return compareAdded(b, a);
      case ItemSortMode.dateAddedAsc:
        return compareAdded(a, b);
    }
  });

  return filtered;
}

String buildClipboardShareName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final datePart =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 'Clipboard_$datePart.txt';
}

List<String> buildSubnetSweepTargets(
  List<String> localIps, {
  int hostStart = 1,
  int hostEnd = 254,
}) {
  final start = hostStart.clamp(1, 254);
  final end = hostEnd.clamp(1, 254);
  if (start > end) return const <String>[];

  final localSet = localIps.map((e) => e.trim()).toSet();
  final prefixes = <String>{};
  for (final ip in localSet) {
    final parts = ip.split('.');
    if (parts.length != 4) continue;
    final octets = <int>[];
    var valid = true;
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) {
        valid = false;
        break;
      }
      octets.add(parsed);
    }
    if (!valid) continue;
    prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
  }

  final sortedPrefixes = prefixes.toList()..sort();
  final out = <String>[];
  for (final prefix in sortedPrefixes) {
    for (var host = start; host <= end; host++) {
      final candidate = '$prefix.$host';
      if (localSet.contains(candidate)) continue;
      out.add(candidate);
    }
  }
  return out;
}

String _normalizeTrustKey(String raw) => raw.trim().toLowerCase();

Set<String> parseTrustListInput(String raw) {
  final out = <String>{};
  final pieces = raw.split(RegExp(r'[\s,;]+'));
  for (final piece in pieces) {
    final token = _normalizeTrustKey(piece);
    if (token.isEmpty) continue;
    if (token.length > 128) continue;
    out.add(token);
  }
  return out;
}

String trustListToText(Set<String> values) {
  final sorted = values.toList()..sort();
  return sorted.join('\n');
}

Set<String> buildTrustCandidateKeys({
  String? peerId,
  String? address,
  int? port,
}) {
  final out = <String>{};
  final normalizedPeerId = peerId == null ? '' : _normalizeTrustKey(peerId);
  if (normalizedPeerId.isNotEmpty) {
    out.add(normalizedPeerId);
  }
  final normalizedAddress = address == null ? '' : _normalizeTrustKey(address);
  if (normalizedAddress.isNotEmpty) {
    out.add(normalizedAddress);
    if (port != null && port > 0 && port <= 65535) {
      out.add('$normalizedAddress:$port');
    }
  }
  return out;
}

bool _stringSetEquals(Set<String> a, Set<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final value in a) {
    if (!b.contains(value)) return false;
  }
  return true;
}

String normalizeItemNote(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length <= _maxItemNoteChars) return trimmed;
  return trimmed.substring(0, _maxItemNoteChars).trimRight();
}

bool _isValidStartupExecutable(String executablePath) {
  final fileName = p.basename(executablePath).toLowerCase();
  return fileName == 'fileshare.exe';
}

String buildWindowsStartupCommand({
  required String executablePath,
  required bool startInTray,
}) {
  final quoted = '"$executablePath"';
  if (!startInTray) return quoted;
  return '$quoted --start-in-tray';
}

Future<void> main(List<String> args) async {
  final startInTrayRequested = args.any(
    (arg) => arg.trim().toLowerCase() == '--start-in-tray',
  );
  WidgetsFlutterBinding.ensureInitialized();
  await _diagnostics.initialize();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _diagnostics.captureFlutterError(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    _diagnostics.captureUnhandledError('platform', error, stack);
    return true;
  };

  await runZonedGuarded(
    () async {
      await windowManager.ensureInitialized();
      final savedWindowState = await _loadWindowState();
      final savedAppSettings = await _loadAppSettings();

      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          minimumSize: _minWindowSize,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
        ),
      );

      runApp(
        MyApp(
          initialSettings: savedAppSettings,
          startInTrayRequested: startInTrayRequested,
        ),
      );
      _diagnostics.info('Application started');
      unawaited(_restoreWindow(savedWindowState));
    },
    (error, stack) {
      _diagnostics.captureUnhandledError('zone', error, stack);
    },
  );
}

Future<void> _restoreWindow(_WindowState? saved) async {
  await windowManager.setMinimumSize(_minWindowSize);

  if (saved == null) {
    await windowManager.setSize(_defaultWindowSize);
    await windowManager.center();
    await windowManager.show();
    return;
  }

  final width = max(saved.width, _minWindowSize.width);
  final height = max(saved.height, _minWindowSize.height);
  await windowManager.setBounds(
    Rect.fromLTWH(saved.left, saved.top, width, height),
  );
  await windowManager.show();

  if (saved.maximized) {
    await windowManager.maximize();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    required this.initialSettings,
    required this.startInTrayRequested,
  });

  final AppSettings initialSettings;
  final bool startInTrayRequested;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late bool dark;
  late int themeIndex;
  late bool soundOnNudge;
  late bool minimizeToTray;
  late bool startWithWindows;
  late bool startInTrayOnLaunch;
  late String sharedRoomKey;
  late String peerAllowlist;
  late String peerBlocklist;
  late bool autoUpdateChecks;
  late UpdateChannel updateChannel;

  @override
  void initState() {
    super.initState();
    dark = widget.initialSettings.darkMode;
    themeIndex = widget.initialSettings.themeIndex.clamp(
      0,
      _themePresets.length - 1,
    );
    soundOnNudge = widget.initialSettings.soundOnNudge;
    minimizeToTray = widget.initialSettings.minimizeToTray;
    startWithWindows = widget.initialSettings.startWithWindows;
    startInTrayOnLaunch = widget.initialSettings.startInTrayOnLaunch;
    sharedRoomKey = widget.initialSettings.sharedRoomKey;
    peerAllowlist = widget.initialSettings.peerAllowlist;
    peerBlocklist = widget.initialSettings.peerBlocklist;
    autoUpdateChecks = widget.initialSettings.autoUpdateChecks;
    updateChannel = widget.initialSettings.updateChannel;
  }

  Future<void> _persistSettings() async {
    await _saveAppSettings(
      AppSettings(
        darkMode: dark,
        themeIndex: themeIndex,
        soundOnNudge: soundOnNudge,
        minimizeToTray: minimizeToTray,
        startWithWindows: startWithWindows,
        startInTrayOnLaunch: startInTrayOnLaunch,
        sharedRoomKey: sharedRoomKey,
        peerAllowlist: peerAllowlist,
        peerBlocklist: peerBlocklist,
        autoUpdateChecks: autoUpdateChecks,
        updateChannel: updateChannel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preset = _themePresets[themeIndex];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: preset.seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: preset.seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Home(
        dark: dark,
        themeIndex: themeIndex,
        initialSoundOnNudge: soundOnNudge,
        initialMinimizeToTray: minimizeToTray,
        initialStartWithWindows: startWithWindows,
        initialStartInTrayOnLaunch: startInTrayOnLaunch,
        startInTrayRequested: widget.startInTrayRequested,
        initialSharedRoomKey: sharedRoomKey,
        initialPeerAllowlist: peerAllowlist,
        initialPeerBlocklist: peerBlocklist,
        initialAutoUpdateChecks: autoUpdateChecks,
        initialUpdateChannel: updateChannel,
        onToggleTheme: () {
          setState(() => dark = !dark);
          unawaited(_persistSettings());
        },
        onSelectTheme: (index) {
          setState(() => themeIndex = index);
          unawaited(_persistSettings());
        },
        onSoundOnNudgeChanged: (value) {
          setState(() => soundOnNudge = value);
          unawaited(_persistSettings());
        },
        onMinimizeToTrayChanged: (value) {
          setState(() => minimizeToTray = value);
          unawaited(_persistSettings());
        },
        onStartWithWindowsChanged: (value) {
          setState(() => startWithWindows = value);
          unawaited(_persistSettings());
        },
        onStartInTrayOnLaunchChanged: (value) {
          setState(() => startInTrayOnLaunch = value);
          unawaited(_persistSettings());
        },
        onSharedRoomKeyChanged: (value) {
          setState(() => sharedRoomKey = value);
          unawaited(_persistSettings());
        },
        onPeerAllowlistChanged: (value) {
          setState(() => peerAllowlist = value);
          unawaited(_persistSettings());
        },
        onPeerBlocklistChanged: (value) {
          setState(() => peerBlocklist = value);
          unawaited(_persistSettings());
        },
        onAutoUpdateChecksChanged: (value) {
          setState(() => autoUpdateChecks = value);
          unawaited(_persistSettings());
        },
        onUpdateChannelChanged: (value) {
          setState(() => updateChannel = value);
          unawaited(_persistSettings());
        },
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.dark,
    required this.themeIndex,
    required this.initialSoundOnNudge,
    required this.initialMinimizeToTray,
    required this.initialStartWithWindows,
    required this.initialStartInTrayOnLaunch,
    required this.startInTrayRequested,
    required this.initialSharedRoomKey,
    required this.initialPeerAllowlist,
    required this.initialPeerBlocklist,
    required this.initialAutoUpdateChecks,
    required this.initialUpdateChannel,
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onSoundOnNudgeChanged,
    required this.onMinimizeToTrayChanged,
    required this.onStartWithWindowsChanged,
    required this.onStartInTrayOnLaunchChanged,
    required this.onSharedRoomKeyChanged,
    required this.onPeerAllowlistChanged,
    required this.onPeerBlocklistChanged,
    required this.onAutoUpdateChecksChanged,
    required this.onUpdateChannelChanged,
  });

  final bool dark;
  final int themeIndex;
  final bool initialSoundOnNudge;
  final bool initialMinimizeToTray;
  final bool initialStartWithWindows;
  final bool initialStartInTrayOnLaunch;
  final bool startInTrayRequested;
  final String initialSharedRoomKey;
  final String initialPeerAllowlist;
  final String initialPeerBlocklist;
  final bool initialAutoUpdateChecks;
  final UpdateChannel initialUpdateChannel;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final ValueChanged<bool> onSoundOnNudgeChanged;
  final ValueChanged<bool> onMinimizeToTrayChanged;
  final ValueChanged<bool> onStartWithWindowsChanged;
  final ValueChanged<bool> onStartInTrayOnLaunchChanged;
  final ValueChanged<String> onSharedRoomKeyChanged;
  final ValueChanged<String> onPeerAllowlistChanged;
  final ValueChanged<String> onPeerBlocklistChanged;
  final ValueChanged<bool> onAutoUpdateChecksChanged;
  final ValueChanged<UpdateChannel> onUpdateChannelChanged;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home>
    with WindowListener, tray.TrayListener, SingleTickerProviderStateMixin {
  final c = Controller();
  late final AudioPlayer _nudgeAudioPlayer;
  bool over = false;
  bool _pointerHovering = false;
  bool _isFocused = true;
  int _lastNudge = 0;
  int _lastRemoteCount = 0;
  Set<String> _lastRemoteKeys = <String>{};
  DateTime _lastRemoteToastAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _flash = false;
  bool _soundOnNudge = false;
  bool _minimizeToTray = false;
  bool _startWithWindows = false;
  bool _startInTrayOnLaunch = false;
  String _sharedRoomKey = '';
  String _peerAllowlist = '';
  String _peerBlocklist = '';
  bool _autoUpdateChecks = false;
  UpdateChannel _updateChannel = UpdateChannel.stable;
  ItemSourceFilter _sourceFilter = ItemSourceFilter.all;
  ItemTypeFilter _typeFilter = ItemTypeFilter.all;
  ItemSortMode _sortMode = ItemSortMode.ownerThenName;
  ItemLayoutMode _layoutMode = ItemLayoutMode.grid;
  double _iconSize = 64;
  Set<String> _favoriteKeys = <String>{};
  Set<String> _selectedItemKeys = <String>{};
  Map<String, String> _itemNotes = <String, String>{};
  final Map<String, DateTime> _itemFirstSeenAt = <String, DateTime>{};
  bool _trayInitialized = false;
  bool _isHiddenToTray = false;
  bool _isQuitting = false;
  String? _lastDownloadDirectory;
  late final TextEditingController _searchController;
  Timer? _flashTimer;
  Timer? _windowSaveDebounce;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeProgress;

  @override
  void initState() {
    super.initState();
    _minimizeToTray = widget.initialMinimizeToTray;
    _startWithWindows = widget.initialStartWithWindows;
    _startInTrayOnLaunch = widget.initialStartInTrayOnLaunch;
    _soundOnNudge = widget.initialSoundOnNudge;
    _sharedRoomKey = widget.initialSharedRoomKey;
    _peerAllowlist = widget.initialPeerAllowlist;
    _peerBlocklist = widget.initialPeerBlocklist;
    _autoUpdateChecks = widget.initialAutoUpdateChecks;
    _updateChannel = widget.initialUpdateChannel;
    _searchController = TextEditingController();
    c.setSharedRoomKey(_sharedRoomKey);
    c.setTrustLists(
      allowlist: parseTrustListInput(_peerAllowlist),
      blocklist: parseTrustListInput(_peerBlocklist),
    );
    c.setAutoUpdateChecks(_autoUpdateChecks);
    c.setUpdateChannel(_updateChannel);
    _nudgeAudioPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _shakeProgress = CurvedAnimation(
      parent: _shakeController,
      curve: Curves.easeOutCubic,
    );
    c.addListener(_changed);
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    unawaited(_initDesktopIntegrations());
    unawaited(_initFocus());
    unawaited(c.start());
    unawaited(() async {
      final loaded = await _loadFavoriteKeys();
      if (!mounted) return;
      setState(() => _favoriteKeys = loaded);
    }());
    unawaited(() async {
      final loaded = await _loadItemNotes();
      if (!mounted) return;
      setState(() => _itemNotes = loaded);
    }());
    if (widget.startInTrayRequested && Platform.isWindows && !_isTest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_hideToTray(force: true));
      });
    }
  }

  bool _isFavorite(ShareItem item) => _favoriteKeys.contains(item.key);

  Future<void> _toggleFavorite(ShareItem item) async {
    final next = <String>{..._favoriteKeys};
    if (!next.add(item.key)) {
      next.remove(item.key);
    }
    setState(() => _favoriteKeys = next);
    await _saveFavoriteKeys(next);
  }

  String? _noteForItem(ShareItem item) => _itemNotes[item.key];

  Future<void> _setItemNote(ShareItem item, String rawNote) async {
    final note = normalizeItemNote(rawNote);
    final next = <String, String>{..._itemNotes};
    if (note.isEmpty) {
      next.remove(item.key);
    } else {
      next[item.key] = note;
    }
    setState(() => _itemNotes = next);
    await _saveItemNotes(next);
  }

  Future<void> _editItemNote(ShareItem item) async {
    final controller = TextEditingController(text: _noteForItem(item) ?? '');
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Note: ${p.basename(item.name)}'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            minLines: 4,
            maxLines: 8,
            maxLength: _maxItemNoteChars,
            decoration: const InputDecoration(
              hintText: 'Add a short note/comment for this item',
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'clear'),
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final decision = action ?? 'cancel';
    if (decision == 'cancel') return;
    if (decision == 'clear') {
      await _setItemNote(item, '');
      return;
    }
    await _setItemNote(item, controller.text);
  }

  void _toggleItemSelection(ShareItem item) {
    final next = <String>{..._selectedItemKeys};
    if (!next.add(item.key)) {
      next.remove(item.key);
    }
    setState(() => _selectedItemKeys = next);
  }

  void _clearSelection() {
    if (_selectedItemKeys.isEmpty) return;
    setState(() => _selectedItemKeys = <String>{});
  }

  Future<void> _initDesktopIntegrations() async {
    if (!Platform.isWindows) return;
    try {
      await localNotifier.setup(
        appName: 'FileShare',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (_) {}
  }

  Future<void> _initFocus() async {
    _isFocused = await windowManager.isFocused();
  }

  void _changed() {
    final allItems = c.items;
    final seenNow = DateTime.now();
    final keys = <String>{};
    for (final item in allItems) {
      keys.add(item.key);
      _itemFirstSeenAt.putIfAbsent(item.key, () => seenNow);
    }
    _itemFirstSeenAt.removeWhere((key, _) => !keys.contains(key));
    if (_selectedItemKeys.isNotEmpty) {
      final trimmed = _selectedItemKeys.where(keys.contains).toSet();
      if (!_stringSetEquals(trimmed, _selectedItemKeys)) {
        _selectedItemKeys = trimmed;
      }
    }

    final remoteItems = allItems.where((e) => !e.local).toList(growable: false);
    final remoteCount = remoteItems.length;
    if (_isHiddenToTray && remoteCount > _lastRemoteCount) {
      unawaited(
        _showTrayNotification('FileShare', 'New file shared by a peer.'),
      );
    }
    final remoteKeys = remoteItems.map((e) => e.key).toSet();
    final added = remoteKeys.difference(_lastRemoteKeys).length;
    final removed = _lastRemoteKeys.difference(remoteKeys).length;
    final now = DateTime.now();
    final canToast =
        _isFocused &&
        !_isHiddenToTray &&
        now.difference(_lastRemoteToastAt) > const Duration(milliseconds: 1200);
    if (canToast && mounted) {
      if (added > 0) {
        _lastRemoteToastAt = now;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 1400),
            content: Text(
              added == 1
                  ? '1 file added by peer'
                  : '$added files added by peers',
            ),
          ),
        );
      } else if (removed > 0) {
        _lastRemoteToastAt = now;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 1400),
            content: Text(
              removed == 1
                  ? '1 file removed by peer'
                  : '$removed files removed by peers',
            ),
          ),
        );
      }
    }
    _lastRemoteKeys = remoteKeys;
    _lastRemoteCount = remoteCount;

    if (c.nudgeTick != _lastNudge) {
      _lastNudge = c.nudgeTick;
      _handleNudge();
      if (_isHiddenToTray) {
        unawaited(_showTrayNotification('FileShare', 'You received a nudge.'));
      }
    }
    if (mounted) setState(() {});
  }

  void _handleNudge() {
    _shakeController.forward(from: 0);
    if (_soundOnNudge) {
      _playNudgeSound();
    }
    _flashTimer?.cancel();
    setState(() => _flash = true);
    _flashTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() => _flash = false);
      }
    });
    if (!_isFocused) {
      unawaited(_flashTaskbar());
    }
  }

  Future<void> _downloadRemoteItem(ShareItem item) async {
    if (item.local) return;
    final suggestedName = p.basename(item.rel);
    final extension = p.extension(suggestedName);
    final acceptedGroups = extension.isEmpty
        ? const <fs.XTypeGroup>[]
        : <fs.XTypeGroup>[
            fs.XTypeGroup(
              label: '${extension.toUpperCase()} Files',
              extensions: <String>[extension.substring(1)],
            ),
          ];
    final location = await fs.getSaveLocation(
      initialDirectory: _lastDownloadDirectory,
      suggestedName: suggestedName,
      acceptedTypeGroups: acceptedGroups,
      confirmButtonText: 'Download',
    );
    if (location == null) return;
    _lastDownloadDirectory = p.dirname(location.path);
    try {
      await c.downloadRemoteToPath(item, location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloaded $suggestedName')));
    } catch (e) {
      if (!mounted) return;
      if (e is _TransferCanceledException) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Download canceled')));
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Future<void> _shareClipboardTextAsItem() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard text is empty')),
        );
        return;
      }
      final name = buildClipboardShareName(DateTime.now());
      await c.addClipboardText(text, fileName: name);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Shared clipboard text as $name')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Clipboard share failed: $e')));
    }
  }

  String _allocateBatchDownloadPath(
    String baseDirectory,
    ShareItem item,
    Set<String> reserved,
  ) {
    final rawRel = item.rel.replaceAll('\\', '/');
    var rel = p.normalize(rawRel);
    if (rel.isEmpty ||
        rel == '.' ||
        rel.startsWith('..') ||
        p.isAbsolute(rel)) {
      rel = _safeFileName(p.basename(item.rel));
    } else {
      final parts = rel
          .split('/')
          .where((part) => part.isNotEmpty && part != '.')
          .map(_safeFileName)
          .toList(growable: false);
      if (parts.isEmpty) {
        rel = _safeFileName(p.basename(item.rel));
      } else {
        rel = p.joinAll(parts);
      }
    }

    String candidate = p.join(baseDirectory, rel);
    if (!p.isWithin(baseDirectory, candidate) &&
        p.normalize(candidate) != p.normalize(baseDirectory)) {
      candidate = p.join(baseDirectory, _safeFileName(p.basename(item.rel)));
    }
    String unique = candidate;
    final ext = p.extension(unique);
    final stem = ext.isEmpty
        ? unique
        : unique.substring(0, unique.length - ext.length);
    var counter = 2;
    while (reserved.contains(unique.toLowerCase()) ||
        File(unique).existsSync()) {
      unique = '$stem ($counter)$ext';
      counter++;
    }
    reserved.add(unique.toLowerCase());
    return unique;
  }

  Future<void> _downloadAllFromOwner(
    String ownerId,
    String ownerName,
    List<ShareItem> sectionItems,
  ) async {
    final remoteItems = sectionItems
        .where((item) => !item.local && item.peerId == ownerId)
        .toList(growable: false);
    if (remoteItems.isEmpty) return;
    final targetDirectory = await fs.getDirectoryPath(
      initialDirectory: _lastDownloadDirectory,
      confirmButtonText: 'Download All',
    );
    if (targetDirectory == null || targetDirectory.trim().isEmpty) return;
    _lastDownloadDirectory = targetDirectory;

    var completed = 0;
    var failed = 0;
    var canceled = 0;
    final reservedTargets = <String>{};
    for (final item in remoteItems) {
      final outputPath = _allocateBatchDownloadPath(
        targetDirectory,
        item,
        reservedTargets,
      );
      try {
        await c.downloadRemoteToPath(item, outputPath);
        completed++;
      } on _TransferCanceledException {
        canceled++;
        break;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    final parts = <String>[
      '$completed downloaded',
      if (failed > 0) '$failed failed',
      if (canceled > 0) '$canceled canceled',
    ];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Download all from $ownerName: ${parts.join(', ')}'),
      ),
    );
  }

  Future<void> _downloadSelectedRemote(List<ShareItem> remoteItems) async {
    if (remoteItems.isEmpty) return;
    final targetDirectory = await fs.getDirectoryPath(
      initialDirectory: _lastDownloadDirectory,
      confirmButtonText: 'Download Selected',
    );
    if (targetDirectory == null || targetDirectory.trim().isEmpty) return;
    _lastDownloadDirectory = targetDirectory;

    final sorted = remoteItems.toList(growable: false)
      ..sort((a, b) {
        final ownerOrder = a.owner.compareTo(b.owner);
        if (ownerOrder != 0) return ownerOrder;
        return a.rel.compareTo(b.rel);
      });
    var completed = 0;
    var failed = 0;
    var canceled = 0;
    final reservedTargets = <String>{};
    for (final item in sorted) {
      final outputPath = _allocateBatchDownloadPath(
        targetDirectory,
        item,
        reservedTargets,
      );
      try {
        await c.downloadRemoteToPath(item, outputPath);
        completed++;
      } on _TransferCanceledException {
        canceled++;
        break;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    final parts = <String>[
      '$completed downloaded',
      if (failed > 0) '$failed failed',
      if (canceled > 0) '$canceled canceled',
    ];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Download selected: ${parts.join(', ')}')),
    );
  }

  void _removeSelectedLocal(List<ShareItem> localItems) {
    if (localItems.isEmpty) return;
    final nextSelection = <String>{..._selectedItemKeys};
    for (final item in localItems) {
      c.removeLocal(item.itemId);
      nextSelection.remove(item.key);
    }
    if (!mounted) return;
    setState(() => _selectedItemKeys = nextSelection);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          localItems.length == 1
              ? 'Removed 1 local item'
              : 'Removed ${localItems.length} local items',
        ),
      ),
    );
  }

  void _nudgeSelectedOwners(Set<String> ownerIds) {
    if (ownerIds.isEmpty) return;
    c.sendNudgeToPeerIds(ownerIds);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ownerIds.length == 1
              ? 'Nudged 1 owner'
              : 'Nudged ${ownerIds.length} owners',
        ),
      ),
    );
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relativePath = p.relative(entity.path, from: source.path);
      final destinationPath = p.join(target.path, relativePath);
      if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
      } else if (entity is File) {
        await File(destinationPath).parent.create(recursive: true);
        await entity.copy(destinationPath);
      }
    }
  }

  Future<String> _exportDiagnosticsBundle() async {
    final targetRoot = await fs.getDirectoryPath(
      initialDirectory: _lastDownloadDirectory,
      confirmButtonText: 'Export',
    );
    if (targetRoot == null || targetRoot.trim().isEmpty) {
      return 'Export canceled';
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final bundle = Directory(
      p.join(targetRoot, 'FileShare-Diagnostics-$stamp'),
    );
    await bundle.create(recursive: true);
    final appDataDir = await _appDataDir();

    for (var i = 0; i <= 5; i++) {
      final suffix = i == 0 ? '' : '.$i';
      final src = File(p.join(appDataDir.path, 'fileshare.log$suffix'));
      if (await src.exists()) {
        await src.copy(p.join(bundle.path, src.uri.pathSegments.last));
      }
    }

    final settingsFile = await _appSettingsFile();
    if (await settingsFile.exists()) {
      await settingsFile.copy(p.join(bundle.path, 'settings.json'));
    }
    final windowStateFile = await _windowStateFile();
    if (await windowStateFile.exists()) {
      await windowStateFile.copy(p.join(bundle.path, 'window_state.json'));
    }

    final crashDir = Directory(p.join(appDataDir.path, 'crashes'));
    if (await crashDir.exists()) {
      await _copyDirectory(crashDir, Directory(p.join(bundle.path, 'crashes')));
    }

    final summary = <String, dynamic>{
      'generatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'deviceName': c.deviceName,
      'deviceId': c.deviceId,
      'listenPort': c.listenPort,
      'protocol': '$_protocolMajor.$_protocolMinor',
      'connectedPeers': c.connectedPeerCount,
      'localIps': c.localIps,
      'roomKeyEnabled': _sharedRoomKey.isNotEmpty,
      'latencyProfilingEnabled': c.latencyProfilingEnabled,
      'networkDiagnostics': c.networkDiagnostics,
    };
    await File(p.join(bundle.path, 'summary.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
      flush: true,
    );
    return 'Diagnostics exported: ${bundle.path}';
  }

  @override
  void onWindowFocus() {
    _isFocused = true;
  }

  @override
  void onWindowBlur() {
    _isFocused = false;
  }

  @override
  void onWindowMoved() {
    _scheduleWindowSave();
  }

  @override
  void onWindowResized() {
    _scheduleWindowSave();
  }

  @override
  void onWindowMinimize() {
    _scheduleWindowSave();
    if (shouldHideToTrayOnMinimize(
      minimizeToTray: _minimizeToTray,
      isWindows: Platform.isWindows,
      isQuitting: _isQuitting,
    )) {
      unawaited(_hideToTray());
    }
  }

  @override
  void onWindowRestore() {
    _isHiddenToTray = false;
    _scheduleWindowSave();
  }

  @override
  void onWindowMaximize() {
    _scheduleWindowSave(immediate: true);
  }

  @override
  void onWindowUnmaximize() {
    _scheduleWindowSave(immediate: true);
  }

  @override
  void onWindowClose() {
    unawaited(_saveWindowNow());
    if (_isQuitting) return;
    unawaited(_handleNativeCloseSignal());
  }

  Future<void> _handleNativeCloseSignal() async {
    // Defensive guard: ignore close events emitted while minimizing.
    try {
      if (await windowManager.isMinimized()) {
        return;
      }
    } catch (_) {}
    await _quitApplication();
  }

  void _scheduleWindowSave({bool immediate = false}) {
    _windowSaveDebounce?.cancel();
    final delay = immediate ? Duration.zero : const Duration(milliseconds: 250);
    _windowSaveDebounce = Timer(delay, () {
      unawaited(_saveWindowNow());
    });
  }

  Future<void> _saveWindowNow() async {
    try {
      final bounds = await windowManager.getBounds();
      final maximized = await windowManager.isMaximized();
      await _saveWindowState(
        _WindowState(
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
          maximized: maximized,
        ),
      );
    } catch (_) {}
  }

  void _playNudgeSound() {
    unawaited(() async {
      try {
        await _nudgeAudioPlayer.stop();
        await _nudgeAudioPlayer.play(AssetSource('nudge.mp3'));
      } catch (_) {}
    }());
  }

  Future<void> _ensureTrayInitialized() async {
    if (!Platform.isWindows || _trayInitialized) return;
    tray.trayManager.addListener(this);
    await tray.trayManager.setIcon('assets/FSICON.ico');
    await tray.trayManager.setToolTip('FileShare');
    await tray.trayManager.setContextMenu(
      tray.Menu(
        items: [
          tray.MenuItem(key: 'show_window', label: 'Restore FileShare'),
          tray.MenuItem.separator(),
          tray.MenuItem(key: 'exit_app', label: 'Exit FileShare'),
        ],
      ),
    );
    _trayInitialized = true;
  }

  Future<void> _disposeTray() async {
    if (!_trayInitialized) return;
    tray.trayManager.removeListener(this);
    try {
      await tray.trayManager.destroy();
    } catch (_) {}
    _trayInitialized = false;
  }

  Future<void> _hideToTray({
    bool force = false,
    String? notificationTitle,
    String? notificationBody,
  }) async {
    if ((!_minimizeToTray && !force) || !Platform.isWindows) return;
    if (_isHiddenToTray) return;
    try {
      await _ensureTrayInitialized();
      // A minimized window can retain a taskbar button until restored/rehidden.
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      // Re-apply after hide to ensure the taskbar state sticks.
      await windowManager.setSkipTaskbar(true);
      _isHiddenToTray = true;
      if (notificationTitle != null && notificationBody != null) {
        await _showTrayNotification(notificationTitle, notificationBody);
      }
    } catch (_) {
      // Never let tray minimize failure terminate the app.
      await windowManager.minimize();
    }
  }

  Future<void> _restoreFromTray() async {
    if (!_isHiddenToTray) return;
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
      _isHiddenToTray = false;
      await _disposeTray();
    } catch (_) {}
  }

  Future<void> _showTrayNotification(String title, String body) async {
    if (!Platform.isWindows || !_isHiddenToTray) return;
    try {
      final notification = LocalNotification(title: title, body: body);
      notification.onClick = () {
        unawaited(_restoreFromTray());
        unawaited(notification.destroy());
      };
      notification.onClose = (_) {
        unawaited(notification.destroy());
      };
      await notification.show();
    } catch (_) {}
  }

  Future<void> _setMinimizeToTray(bool value) async {
    if (_minimizeToTray == value) return;
    if (mounted) {
      setState(() => _minimizeToTray = value);
    } else {
      _minimizeToTray = value;
    }
    widget.onMinimizeToTrayChanged(value);
    if (value) return;
    if (_isHiddenToTray) {
      await _restoreFromTray();
    }
    await _disposeTray();
  }

  Future<String> _applyWindowsStartup({
    required bool enabled,
    required bool startInTray,
  }) async {
    if (!Platform.isWindows) {
      return 'Startup integration is Windows-only';
    }
    final exePath = Platform.resolvedExecutable;
    if (!_isValidStartupExecutable(exePath)) {
      return 'Startup registration requires running FileShare installer build';
    }
    if (!enabled) {
      final result = await Process.run('reg', [
        'delete',
        _windowsRunKey,
        '/v',
        _windowsRunValueName,
        '/f',
      ]);
      final stderr = (result.stderr ?? '').toString().toLowerCase();
      if (result.exitCode != 0 &&
          !stderr.contains('unable to find') &&
          !stderr.contains('cannot find')) {
        return 'Failed to disable startup: ${result.stderr}';
      }
      return 'Start with Windows disabled';
    }

    final command = buildWindowsStartupCommand(
      executablePath: exePath,
      startInTray: startInTray,
    );
    final result = await Process.run('reg', [
      'add',
      _windowsRunKey,
      '/v',
      _windowsRunValueName,
      '/t',
      'REG_SZ',
      '/d',
      command,
      '/f',
    ]);
    if (result.exitCode != 0) {
      return 'Failed to enable startup: ${result.stderr}';
    }
    return startInTray
        ? 'Start with Windows enabled (tray launch)'
        : 'Start with Windows enabled';
  }

  Future<void> _quitApplication() async {
    _isQuitting = true;
    _diagnostics.info('Application shutdown requested');
    await windowManager.setPreventClose(false);
    await windowManager.setSkipTaskbar(false);
    await _disposeTray();
    await windowManager.close();
  }

  Future<void> _onMinimizePressed() async {
    final action = resolveMinimizeAction(
      minimizeToTray: _minimizeToTray,
      isWindows: Platform.isWindows,
    );
    if (action == MinimizeAction.hideToTray) {
      await _hideToTray();
      return;
    }
    await windowManager.minimize();
  }

  Future<void> _onMaximizePressed() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _onClosePressed() async {
    await _quitApplication();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_restoreFromTray());
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        unawaited(_restoreFromTray());
        break;
      case 'exit_app':
        unawaited(_quitApplication());
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.dispose();
    _searchController.dispose();
    unawaited(_nudgeAudioPlayer.dispose());
    windowManager.removeListener(this);
    _flashTimer?.cancel();
    _windowSaveDebounce?.cancel();
    _shakeController.dispose();
    unawaited(_saveWindowNow());
    unawaited(_disposeTray());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allItems = c.items;
    final visibleItems = computeVisibleItems(
      items: allItems,
      query: _searchController.text,
      sourceFilter: _sourceFilter,
      typeFilter: _typeFilter,
      sortMode: _sortMode,
      firstSeenByKey: _itemFirstSeenAt,
    );
    final selection = summarizeSelectedItems(
      allItems: allItems,
      selectedKeys: _selectedItemKeys,
    );
    return Scaffold(
      body: SafeArea(
        child: DropRegion(
          formats: const [Formats.fileUri, Formats.plainText],
          hitTestBehavior: HitTestBehavior.opaque,
          onDropEnter: (_) => setState(() => over = true),
          onDropLeave: (_) => setState(() => over = false),
          onDropOver: (event) {
            if (event.session.allowedOperations.contains(DropOperation.copy)) {
              return DropOperation.copy;
            }
            return DropOperation.none;
          },
          onPerformDrop: (event) async {
            setState(() => over = false);
            final paths = await _readDroppedPaths(event);
            if (paths.isNotEmpty) {
              await c.addDropped(paths);
            }
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _pointerHovering = true),
            onExit: (_) => setState(() => _pointerHovering = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => c.sendNudge(),
              child: AnimatedBuilder(
                animation: _shakeProgress,
                builder: (context, child) {
                  final t = _shakeProgress.value;
                  final amp = (1 - t) * 10;
                  final dx = sin(t * pi * 10) * amp;
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.98),
                              Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.9),
                            ],
                          ),
                        ),
                        foregroundDecoration: over
                            ? BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.12),
                              )
                            : null,
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 40,
                      child: _TitleBarContent(
                        dark: widget.dark,
                        themeIndex: widget.themeIndex,
                        connectedCount: c.connectedPeerCount,
                        minimizeToTray: _minimizeToTray,
                        onToggleTheme: widget.onToggleTheme,
                        onSelectTheme: widget.onSelectTheme,
                        onShowSettings: _showSettings,
                        onToggleMinimizeToTray: () {
                          unawaited(_setMinimizeToTray(!_minimizeToTray));
                        },
                        onMinimizePressed: _onMinimizePressed,
                        onMaximizePressed: _onMaximizePressed,
                        onClosePressed: _onClosePressed,
                        showMoveArea: !_isTest,
                        showWindowButtons: !_isTest,
                      ),
                    ),
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 56, 16, 16),
                        child: allItems.isEmpty
                            ? (over
                                  ? Center(
                                      child: Text(
                                        'Drop to share',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    )
                                  : const SizedBox.shrink())
                            : Column(
                                children: [
                                  _ExplorerToolbar(
                                    searchController: _searchController,
                                    onSearchChanged: (_) => setState(() {}),
                                    sourceFilter: _sourceFilter,
                                    onSourceFilterChanged: (value) {
                                      setState(() => _sourceFilter = value);
                                    },
                                    typeFilter: _typeFilter,
                                    onTypeFilterChanged: (value) {
                                      setState(() => _typeFilter = value);
                                    },
                                    sortMode: _sortMode,
                                    onSortModeChanged: (value) {
                                      setState(() => _sortMode = value);
                                    },
                                    layoutMode: _layoutMode,
                                    onToggleLayoutMode: () {
                                      setState(() {
                                        _layoutMode =
                                            _layoutMode == ItemLayoutMode.grid
                                            ? ItemLayoutMode.list
                                            : ItemLayoutMode.grid;
                                      });
                                    },
                                    iconSize: _iconSize,
                                    onIconSizeChanged: (value) {
                                      setState(() => _iconSize = value);
                                    },
                                    onShareClipboardText:
                                        _shareClipboardTextAsItem,
                                  ),
                                  if (selection.all.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    _BulkActionBar(
                                      selectedCount: selection.all.length,
                                      localCount: selection.local.length,
                                      remoteCount: selection.remote.length,
                                      ownerCount:
                                          selection.remoteOwnerIds.length,
                                      onClear: _clearSelection,
                                      onDownloadSelected:
                                          selection.remote.isEmpty
                                          ? null
                                          : () => unawaited(
                                              _downloadSelectedRemote(
                                                selection.remote,
                                              ),
                                            ),
                                      onRemoveSelected: selection.local.isEmpty
                                          ? null
                                          : () => _removeSelectedLocal(
                                              selection.local,
                                            ),
                                      onNudgeOwners:
                                          selection.remoteOwnerIds.isEmpty
                                          ? null
                                          : () => _nudgeSelectedOwners(
                                              selection.remoteOwnerIds,
                                            ),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: visibleItems.isEmpty
                                        ? Center(
                                            child: Text(
                                              'No items match current filters.',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                          )
                                        : _ExplorerGrid(
                                            items: visibleItems,
                                            buildDragItem: c.buildDragItem,
                                            favoriteKeys: _favoriteKeys,
                                            isFavorite: _isFavorite,
                                            onToggleFavorite: _toggleFavorite,
                                            noteForItem: _noteForItem,
                                            onEditNote: _editItemNote,
                                            onRemove: (item) =>
                                                c.removeLocal(item.itemId),
                                            onDownload: _downloadRemoteItem,
                                            onDownloadAllFromOwner:
                                                _downloadAllFromOwner,
                                            selectedKeys: _selectedItemKeys,
                                            onToggleSelection:
                                                _toggleItemSelection,
                                            showGrid: _pointerHovering,
                                            layoutMode: _layoutMode,
                                            iconSize: _iconSize,
                                          ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    if (_flash)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _flash ? 1 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: Container(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.18),
                            ),
                          ),
                        ),
                      ),
                    if (c.transfers.isNotEmpty)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: _TransferPanel(
                          transfers: c.transfers,
                          onClearFinished: c.clearFinishedTransfers,
                          onCancelTransfer: c.cancelTransfer,
                          onOpenTransferLocation: c.openTransferLocation,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettings() async {
    final peers = c.peers.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final incompatible = c.incompatiblePeers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final diagnostics =
        c.networkDiagnostics.entries
            .where((e) => e.value > 0)
            .toList(growable: false)
          ..sort((a, b) => a.key.compareTo(b.key));
    final localIpSummary = c.localIps.isEmpty
        ? 'Unavailable'
        : c.localIps.join(', ');
    final probeController = TextEditingController();
    final keyController = TextEditingController(text: _sharedRoomKey);
    final allowlistController = TextEditingController(text: _peerAllowlist);
    final blocklistController = TextEditingController(text: _peerBlocklist);
    String? probeStatus;
    String? trustStatus;
    bool sendingProbe = false;
    String? connectStatus;
    String? sweepStatus;
    bool sweepingSubnet = false;
    String? updateStatus;
    String? startupStatus;
    bool applyingStartup = false;
    bool checkingUpdates = false;
    String? exportStatus;
    bool exportingDiagnostics = false;
    bool profilingEnabled = c.latencyProfilingEnabled;
    final latencySamples = c.peerFirstSyncLatency.entries.toList(
      growable: false,
    )..sort((a, b) => a.key.compareTo(b.key));
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Network Settings'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('This Device'),
                  Text('Name: ${c.deviceName}'),
                  Text('IP: $localIpSummary'),
                  Text('Port: ${c.listenPort}'),
                  Text('Protocol: $_protocolMajor.$_protocolMinor'),
                  Text(
                    'Discovery Profile: ${discoveryProfileLabel(c.discoveryProfile)}',
                  ),
                  const SizedBox(height: 8),
                  const Text('Room Key (optional)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: keyController,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'Shared key for trusted peers',
                      isDense: true,
                    ),
                    onChanged: (value) {
                      final normalized = value.trim();
                      _sharedRoomKey = normalized;
                      c.setSharedRoomKey(normalized);
                      widget.onSharedRoomKeyChanged(normalized);
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text('Peer Trust (optional)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: allowlistController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Allowlist entries (IP, IP:port, or peer ID)',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: blocklistController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Blocklist entries (IP, IP:port, or peer ID)',
                      isDense: true,
                    ),
                  ),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          final allow = parseTrustListInput(
                            allowlistController.text,
                          );
                          final block = parseTrustListInput(
                            blocklistController.text,
                          );
                          allow.removeWhere(block.contains);
                          final allowText = trustListToText(allow);
                          final blockText = trustListToText(block);
                          c.setTrustLists(allowlist: allow, blocklist: block);
                          _peerAllowlist = allowText;
                          _peerBlocklist = blockText;
                          widget.onPeerAllowlistChanged(allowText);
                          widget.onPeerBlocklistChanged(blockText);
                          setDialogState(
                            () => trustStatus =
                                'Trust policy saved (allow: ${allow.length}, block: ${block.length})',
                          );
                        },
                        child: const Text('Apply Trust Policy'),
                      ),
                    ],
                  ),
                  if (trustStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(trustStatus!),
                  ],
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sound on nudge'),
                    value: _soundOnNudge,
                    onChanged: (value) {
                      setDialogState(() => _soundOnNudge = value);
                      widget.onSoundOnNudgeChanged(value);
                    },
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto update checks'),
                    value: _autoUpdateChecks,
                    onChanged: (value) {
                      setDialogState(() => _autoUpdateChecks = value);
                      c.setAutoUpdateChecks(value);
                      widget.onAutoUpdateChecksChanged(value);
                    },
                  ),
                  Row(
                    children: [
                      const Text('Update channel:'),
                      const SizedBox(width: 8),
                      DropdownButton<UpdateChannel>(
                        value: _updateChannel,
                        items: UpdateChannel.values
                            .map(
                              (channel) => DropdownMenuItem<UpdateChannel>(
                                value: channel,
                                child: Text(updateChannelLabel(channel)),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() => _updateChannel = value);
                          c.setUpdateChannel(value);
                          widget.onUpdateChannelChanged(value);
                        },
                      ),
                    ],
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start with Windows'),
                    subtitle: const Text('Register FileShare in user startup'),
                    value: _startWithWindows,
                    onChanged: applyingStartup
                        ? null
                        : (value) async {
                            setDialogState(() => applyingStartup = true);
                            final result = await _applyWindowsStartup(
                              enabled: value,
                              startInTray: value && _startInTrayOnLaunch,
                            );
                            if (!context.mounted) return;
                            setDialogState(() {
                              applyingStartup = false;
                              startupStatus = result;
                              _startWithWindows = value;
                            });
                            widget.onStartWithWindowsChanged(value);
                          },
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Launch in tray'),
                    subtitle: const Text(
                      'When started from Windows startup, begin hidden in tray',
                    ),
                    value: _startInTrayOnLaunch,
                    onChanged: (!_startWithWindows || applyingStartup)
                        ? null
                        : (value) async {
                            setDialogState(() => applyingStartup = true);
                            final result = await _applyWindowsStartup(
                              enabled: true,
                              startInTray: value,
                            );
                            if (!context.mounted) return;
                            setDialogState(() {
                              applyingStartup = false;
                              startupStatus = result;
                              _startInTrayOnLaunch = value;
                            });
                            widget.onStartInTrayOnLaunchChanged(value);
                          },
                  ),
                  if (startupStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(startupStatus!),
                  ],
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Latency profiling'),
                    subtitle: const Text(
                      'Capture first-seen to first-sync timing per peer',
                    ),
                    value: profilingEnabled,
                    onChanged: (value) {
                      setDialogState(() => profilingEnabled = value);
                      c.setLatencyProfilingEnabled(value);
                    },
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: checkingUpdates
                            ? null
                            : () async {
                                setDialogState(() {
                                  checkingUpdates = true;
                                  updateStatus = 'Checking for updates...';
                                });
                                final result = await c.checkForUpdates();
                                if (!context.mounted) return;
                                setDialogState(() {
                                  checkingUpdates = false;
                                  updateStatus = result;
                                });
                              },
                        child: Text(
                          checkingUpdates ? 'Checking...' : 'Check Updates',
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (c.latestReleaseUrl != null)
                        TextButton(
                          onPressed: () => unawaited(c.openLatestReleasePage()),
                          child: const Text('Open Release'),
                        ),
                    ],
                  ),
                  if (updateStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(updateStatus!),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: exportingDiagnostics
                            ? null
                            : () async {
                                setDialogState(() {
                                  exportingDiagnostics = true;
                                  exportStatus = 'Exporting diagnostics...';
                                });
                                final result = await _exportDiagnosticsBundle();
                                if (!context.mounted) return;
                                setDialogState(() {
                                  exportingDiagnostics = false;
                                  exportStatus = result;
                                });
                              },
                        child: Text(
                          exportingDiagnostics
                              ? 'Exporting...'
                              : 'Export Diagnostics',
                        ),
                      ),
                    ],
                  ),
                  if (exportStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(exportStatus!),
                  ],
                  const SizedBox(height: 8),
                  const Text('Manual Peer Connect'),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: probeController,
                          decoration: const InputDecoration(
                            hintText: 'Peer IP or IP:port',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: sendingProbe
                            ? null
                            : () async {
                                final raw = probeController.text.trim();
                                if (raw.isEmpty) {
                                  setDialogState(
                                    () => probeStatus = 'Enter an IP',
                                  );
                                  return;
                                }
                                setDialogState(() {
                                  sendingProbe = true;
                                  probeStatus = 'Sending probe...';
                                });
                                final ok = c.sendProbe(raw);
                                await Future<void>.delayed(
                                  const Duration(milliseconds: 120),
                                );
                                if (!context.mounted) return;
                                setDialogState(() {
                                  sendingProbe = false;
                                  probeStatus = ok
                                      ? 'Probe sent to $raw'
                                      : 'Invalid IP address';
                                });
                              },
                        child: Text(sendingProbe ? 'Sending...' : 'Send Probe'),
                      ),
                    ],
                  ),
                  if (probeStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(probeStatus!),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          final raw = probeController.text.trim();
                          if (raw.isEmpty) {
                            setDialogState(() => connectStatus = 'Enter an IP');
                            return;
                          }
                          setDialogState(() => connectStatus = 'Connecting...');
                          final result = await c.addPeerByAddress(raw);
                          setDialogState(() => connectStatus = result);
                        },
                        child: const Text('Connect TCP'),
                      ),
                      TextButton(
                        onPressed: sweepingSubnet
                            ? null
                            : () async {
                                setDialogState(() {
                                  sweepingSubnet = true;
                                  sweepStatus = 'Sweeping local /24 subnet...';
                                });
                                final result = await c.sweepLocalSubnets();
                                if (!context.mounted) return;
                                setDialogState(() {
                                  sweepingSubnet = false;
                                  sweepStatus = result;
                                });
                              },
                        child: Text(
                          sweepingSubnet ? 'Sweeping...' : 'Sweep /24',
                        ),
                      ),
                    ],
                  ),
                  if (connectStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(connectStatus!),
                  ],
                  if (sweepStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(sweepStatus!),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Connectivity'),
                      const Spacer(),
                      TextButton(
                        onPressed: () => unawaited(_showDiagnosticsWizard()),
                        child: const Text('Troubleshoot'),
                      ),
                    ],
                  ),
                  Text('Peers Online: ${c.connectedPeerCount}'),
                  if (peers.isEmpty) const Text('No peers connected'),
                  for (final p in peers)
                    Builder(
                      builder: (context) {
                        final health = c.peerHealthSummary(p);
                        return Text(
                          '- ${p.name} | ${p.addr.address}:${p.port}'
                          ' | ${_peerAvailabilityLabel(c.peerAvailability(p))}'
                          ' | ${_peerStateLabel(c.peerState(p))}'
                          ' | Health ${health.score}% (${health.tier})'
                          '${c.peerStatus[p.id] == null ? '' : ' | ${c.peerStatus[p.id]}'}\n'
                          '  Hint: ${health.hint}',
                        );
                      },
                    ),
                  if (incompatible.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Incompatible Peers'),
                    for (final entry in incompatible) Text('- ${entry.value}'),
                  ],
                  if (diagnostics.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Network Diagnostics'),
                    for (final entry in diagnostics)
                      Text('- ${entry.key}: ${entry.value}'),
                  ],
                  if (latencySamples.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Latency Samples'),
                    for (final entry in latencySamples)
                      Text('- ${entry.key}: ${entry.value.inMilliseconds} ms'),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    keyController.dispose();
    allowlistController.dispose();
    blocklistController.dispose();
    probeController.dispose();
  }

  Future<void> _showDiagnosticsWizard() async {
    final hints = buildNetworkDiagnosticsHints(
      connectedPeers: c.connectedPeerCount,
      localIps: c.localIps,
      diagnostics: c.networkDiagnostics,
      hasIncompatiblePeers: c.incompatiblePeers.isNotEmpty,
      roomKeyEnabled: _sharedRoomKey.isNotEmpty,
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Network Troubleshooter'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < hints.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${i + 1}. ${hints[i]}'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await c.refreshAll();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Peer refresh requested')),
              );
            },
            child: const Text('Refresh Peers'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

enum MinimizeAction { minimizeWindow, hideToTray }

MinimizeAction resolveMinimizeAction({
  required bool minimizeToTray,
  required bool isWindows,
}) {
  if (minimizeToTray && isWindows) {
    return MinimizeAction.hideToTray;
  }
  return MinimizeAction.minimizeWindow;
}

bool shouldHideToTrayOnMinimize({
  required bool minimizeToTray,
  required bool isWindows,
  required bool isQuitting,
}) {
  if (isQuitting) return false;
  return resolveMinimizeAction(
        minimizeToTray: minimizeToTray,
        isWindows: isWindows,
      ) ==
      MinimizeAction.hideToTray;
}

class SettingsButton extends StatefulWidget {
  const SettingsButton({
    super.key,
    required this.dark,
    required this.themeIndex,
    required this.connectedCount,
    required this.minimizeToTray,
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onShowSettings,
    required this.onToggleMinimizeToTray,
  });

  final bool dark;
  final int themeIndex;
  final int connectedCount;
  final bool minimizeToTray;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final VoidCallback onShowSettings;
  final VoidCallback onToggleMinimizeToTray;

  @override
  State<SettingsButton> createState() => _SettingsButtonState();
}

class _SettingsButtonState extends State<SettingsButton> {
  bool _hovering = false;

  Future<void> _showThemesWindow(BuildContext context) async {
    var selected = widget.themeIndex;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Themes'),
          content: SizedBox(
            width: 380,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _themePresets.length,
                itemBuilder: (context, index) {
                  final preset = _themePresets[index];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 10,
                      backgroundColor: preset.seed,
                    ),
                    title: Text(preset.name),
                    trailing: selected == index
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () {
                      setDialogState(() => selected = index);
                      widget.onSelectTheme(index);
                    },
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.85);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedOpacity(
            opacity: _hovering ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '${widget.connectedCount}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
          PopupMenuButton<int>(
            tooltip: 'Settings',
            icon: Icon(Icons.settings_rounded, size: 14, color: iconColor),
            iconSize: 15,
            padding: EdgeInsets.zero,
            splashRadius: 14,
            onSelected: (v) {
              if (v == 1) widget.onToggleTheme();
              if (v == 2) widget.onShowSettings();
              if (v == 3) unawaited(_showThemesWindow(context));
              if (v == 4) widget.onToggleMinimizeToTray();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 1,
                child: Text(
                  widget.dark ? 'Switch to light mode' : 'Switch to dark mode',
                ),
              ),
              const PopupMenuItem(value: 2, child: Text('Network settings')),
              const PopupMenuItem(value: 3, child: Text('Themes...')),
              CheckedPopupMenuItem(
                value: 4,
                checked: widget.minimizeToTray,
                child: const Text('Minimize to tray'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TitleBarContent extends StatelessWidget {
  const _TitleBarContent({
    required this.dark,
    required this.themeIndex,
    required this.connectedCount,
    required this.minimizeToTray,
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onShowSettings,
    required this.onToggleMinimizeToTray,
    required this.onMinimizePressed,
    required this.onMaximizePressed,
    required this.onClosePressed,
    required this.showMoveArea,
    required this.showWindowButtons,
  });

  final bool dark;
  final int themeIndex;
  final int connectedCount;
  final bool minimizeToTray;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final VoidCallback onShowSettings;
  final VoidCallback onToggleMinimizeToTray;
  final Future<void> Function() onMinimizePressed;
  final Future<void> Function() onMaximizePressed;
  final Future<void> Function() onClosePressed;
  final bool showMoveArea;
  final bool showWindowButtons;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 8),
        Expanded(
          child: showMoveArea
              ? const DragToMoveArea(child: SizedBox.expand())
              : const SizedBox(),
        ),
        SettingsButton(
          dark: dark,
          themeIndex: themeIndex,
          connectedCount: connectedCount,
          minimizeToTray: minimizeToTray,
          onToggleTheme: onToggleTheme,
          onSelectTheme: onSelectTheme,
          onShowSettings: onShowSettings,
          onToggleMinimizeToTray: onToggleMinimizeToTray,
        ),
        const SizedBox(width: 8),
        if (showWindowButtons)
          WindowButtons(
            theme: Theme.of(context),
            onMinimizePressed: onMinimizePressed,
            onMaximizePressed: onMaximizePressed,
            onClosePressed: onClosePressed,
          ),
      ],
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({
    super.key,
    required this.theme,
    required this.onMinimizePressed,
    required this.onMaximizePressed,
    required this.onClosePressed,
  });

  final ThemeData theme;
  final Future<void> Function() onMinimizePressed;
  final Future<void> Function() onMaximizePressed;
  final Future<void> Function() onClosePressed;

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.8);
    final hover = theme.colorScheme.onSurface.withValues(alpha: 0.1);
    final down = theme.colorScheme.onSurface.withValues(alpha: 0.16);
    final closeHover = Colors.red.shade700;
    final closeDown = Colors.red.shade800;

    return Row(
      children: [
        _CaptionControlButton(
          icon: Icons.remove_rounded,
          iconColor: base,
          hoverColor: hover,
          pressedColor: down,
          onPressed: () => unawaited(onMinimizePressed()),
        ),
        _CaptionControlButton(
          icon: Icons.crop_square_rounded,
          iconColor: base,
          hoverColor: hover,
          pressedColor: down,
          onPressed: () => unawaited(onMaximizePressed()),
        ),
        _CaptionControlButton(
          icon: Icons.close_rounded,
          iconColor: base,
          hoverColor: closeHover,
          pressedColor: closeDown,
          activeIconColor: Colors.white,
          onPressed: () => unawaited(onClosePressed()),
        ),
      ],
    );
  }
}

class _CaptionControlButton extends StatefulWidget {
  const _CaptionControlButton({
    required this.icon,
    required this.iconColor,
    required this.hoverColor,
    required this.pressedColor,
    required this.onPressed,
    this.activeIconColor,
  });

  final IconData icon;
  final Color iconColor;
  final Color hoverColor;
  final Color pressedColor;
  final Color? activeIconColor;
  final VoidCallback onPressed;

  @override
  State<_CaptionControlButton> createState() => _CaptionControlButtonState();
}

class _CaptionControlButtonState extends State<_CaptionControlButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = _pressed
        ? widget.pressedColor
        : _hovered
        ? widget.hoverColor
        : Colors.transparent;
    final fgColor = (_hovered || _pressed)
        ? (widget.activeIconColor ?? widget.iconColor)
        : widget.iconColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          width: 46,
          height: 32,
          color: bgColor,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 14, color: fgColor),
        ),
      ),
    );
  }
}

Future<void> _flashTaskbar() async {
  if (!Platform.isWindows) {
    return;
  }
  final hwnd = win32.FindWindow(
    win32.TEXT('FLUTTER_RUNNER_WIN32_WINDOW'),
    ffi.nullptr,
  );
  if (hwnd == 0) {
    return;
  }
  final info = calloc<_FLASHWINFO>();
  info.ref.cbSize = ffi.sizeOf<_FLASHWINFO>();
  info.ref.hwnd = hwnd;
  info.ref.dwFlags = _flashTray | _flashTimerNoFg;
  info.ref.uCount = 3;
  info.ref.dwTimeout = 0;
  _flashWindowEx(info);
  calloc.free(info);
}

class _ExplorerToolbar extends StatelessWidget {
  const _ExplorerToolbar({
    required this.searchController,
    required this.onSearchChanged,
    required this.sourceFilter,
    required this.onSourceFilterChanged,
    required this.typeFilter,
    required this.onTypeFilterChanged,
    required this.sortMode,
    required this.onSortModeChanged,
    required this.layoutMode,
    required this.onToggleLayoutMode,
    required this.iconSize,
    required this.onIconSizeChanged,
    required this.onShareClipboardText,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ItemSourceFilter sourceFilter;
  final ValueChanged<ItemSourceFilter> onSourceFilterChanged;
  final ItemTypeFilter typeFilter;
  final ValueChanged<ItemTypeFilter> onTypeFilterChanged;
  final ItemSortMode sortMode;
  final ValueChanged<ItemSortMode> onSortModeChanged;
  final ItemLayoutMode layoutMode;
  final VoidCallback onToggleLayoutMode;
  final double iconSize;
  final ValueChanged<double> onIconSizeChanged;
  final Future<void> Function() onShareClipboardText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search by name, owner, path, extension...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ToolbarDropdown<ItemSourceFilter>(
                value: sourceFilter,
                label: 'Source',
                items: ItemSourceFilter.values,
                labelFor: itemSourceFilterLabel,
                onChanged: onSourceFilterChanged,
              ),
              _ToolbarDropdown<ItemTypeFilter>(
                value: typeFilter,
                label: 'Type',
                items: ItemTypeFilter.values,
                labelFor: itemTypeFilterLabel,
                onChanged: onTypeFilterChanged,
              ),
              _ToolbarDropdown<ItemSortMode>(
                value: sortMode,
                label: 'Sort',
                items: ItemSortMode.values,
                labelFor: itemSortModeLabel,
                onChanged: onSortModeChanged,
              ),
              Tooltip(
                message: layoutMode == ItemLayoutMode.grid
                    ? 'Switch to list view'
                    : 'Switch to grid view',
                child: OutlinedButton.icon(
                  onPressed: onToggleLayoutMode,
                  icon: Icon(
                    layoutMode == ItemLayoutMode.grid
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                    size: 16,
                  ),
                  label: Text(
                    layoutMode == ItemLayoutMode.grid ? 'List' : 'Grid',
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(onShareClipboardText()),
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: const Text('Share Clipboard'),
              ),
              SizedBox(
                width: 220,
                child: Row(
                  children: [
                    const Icon(Icons.photo_size_select_large, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Slider(
                        value: iconSize,
                        min: 44,
                        max: 96,
                        divisions: 13,
                        label: '${iconSize.round()} px',
                        onChanged: onIconSizeChanged,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolbarDropdown<T> extends StatelessWidget {
  const _ToolbarDropdown({
    required this.value,
    required this.label,
    required this.items,
    required this.labelFor,
    required this.onChanged,
  });

  final T value;
  final String label;
  final List<T> items;
  final String Function(T) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          items: items
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text('$label: ${labelFor(item)}'),
                ),
              )
              .toList(growable: false),
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

class _BulkActionBar extends StatelessWidget {
  const _BulkActionBar({
    required this.selectedCount,
    required this.localCount,
    required this.remoteCount,
    required this.ownerCount,
    required this.onClear,
    required this.onDownloadSelected,
    required this.onRemoveSelected,
    required this.onNudgeOwners,
  });

  final int selectedCount;
  final int localCount;
  final int remoteCount;
  final int ownerCount;
  final VoidCallback onClear;
  final VoidCallback? onDownloadSelected;
  final VoidCallback? onRemoveSelected;
  final VoidCallback? onNudgeOwners;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '$selectedCount selected ($localCount local, $remoteCount remote)',
            style: theme.textTheme.bodySmall,
          ),
          OutlinedButton.icon(
            onPressed: onDownloadSelected,
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Download selected'),
          ),
          OutlinedButton.icon(
            onPressed: onRemoveSelected,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Remove local'),
          ),
          OutlinedButton.icon(
            onPressed: onNudgeOwners,
            icon: const Icon(Icons.notifications_active_outlined, size: 16),
            label: Text(ownerCount == 1 ? 'Nudge owner' : 'Nudge owners'),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}

class _OwnerSection {
  _OwnerSection({required this.ownerId, required this.ownerName});

  final String ownerId;
  final String ownerName;
  final List<ShareItem> items = <ShareItem>[];
}

({List<ShareItem> pinned, List<ShareItem> others}) partitionPinnedItems({
  required List<ShareItem> items,
  required Set<String> favoriteKeys,
}) {
  if (favoriteKeys.isEmpty) {
    return (pinned: const <ShareItem>[], others: List<ShareItem>.from(items));
  }
  final pinned = <ShareItem>[];
  final others = <ShareItem>[];
  for (final item in items) {
    if (favoriteKeys.contains(item.key)) {
      pinned.add(item);
    } else {
      others.add(item);
    }
  }
  return (pinned: pinned, others: others);
}

class SelectedItemSummary {
  const SelectedItemSummary({
    required this.all,
    required this.local,
    required this.remote,
    required this.remoteOwnerIds,
  });

  final List<ShareItem> all;
  final List<ShareItem> local;
  final List<ShareItem> remote;
  final Set<String> remoteOwnerIds;
}

SelectedItemSummary summarizeSelectedItems({
  required List<ShareItem> allItems,
  required Set<String> selectedKeys,
}) {
  if (selectedKeys.isEmpty) {
    return const SelectedItemSummary(
      all: <ShareItem>[],
      local: <ShareItem>[],
      remote: <ShareItem>[],
      remoteOwnerIds: <String>{},
    );
  }
  final all = <ShareItem>[];
  final local = <ShareItem>[];
  final remote = <ShareItem>[];
  final remoteOwnerIds = <String>{};
  for (final item in allItems) {
    if (!selectedKeys.contains(item.key)) continue;
    all.add(item);
    if (item.local) {
      local.add(item);
    } else {
      remote.add(item);
      remoteOwnerIds.add(item.ownerId);
    }
  }
  return SelectedItemSummary(
    all: all,
    local: local,
    remote: remote,
    remoteOwnerIds: remoteOwnerIds,
  );
}

class _ExplorerGrid extends StatelessWidget {
  const _ExplorerGrid({
    required this.items,
    required this.buildDragItem,
    required this.favoriteKeys,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.noteForItem,
    required this.onEditNote,
    required this.onRemove,
    required this.onDownload,
    required this.onDownloadAllFromOwner,
    required this.selectedKeys,
    required this.onToggleSelection,
    required this.showGrid,
    required this.layoutMode,
    required this.iconSize,
  });

  final List<ShareItem> items;
  final Future<DragItem?> Function(ShareItem) buildDragItem;
  final Set<String> favoriteKeys;
  final bool Function(ShareItem) isFavorite;
  final Future<void> Function(ShareItem) onToggleFavorite;
  final String? Function(ShareItem) noteForItem;
  final Future<void> Function(ShareItem) onEditNote;
  final ValueChanged<ShareItem> onRemove;
  final Future<void> Function(ShareItem) onDownload;
  final Future<void> Function(String ownerId, String ownerName, List<ShareItem>)
  onDownloadAllFromOwner;
  final Set<String> selectedKeys;
  final ValueChanged<ShareItem> onToggleSelection;
  final bool showGrid;
  final ItemLayoutMode layoutMode;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final normalizedIconSize = iconSize.clamp(44.0, 96.0);
        final tileWidth = max(116.0, normalizedIconSize + 56.0);
        final columns = max(1, (constraints.maxWidth / tileWidth).floor());
        final split = partitionPinnedItems(
          items: items,
          favoriteKeys: favoriteKeys,
        );

        final groups = <String, _OwnerSection>{};
        for (final item in split.others) {
          final section = groups.putIfAbsent(
            item.ownerId,
            () => _OwnerSection(ownerId: item.ownerId, ownerName: item.owner),
          );
          section.items.add(item);
        }
        final orderedGroups = groups.values.toList(growable: false)
          ..sort((a, b) => a.ownerName.compareTo(b.ownerName));
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: showGrid ? 0.06 : 0),
          duration: const Duration(milliseconds: 180),
          builder: (context, gridAlpha, _) {
            return CustomPaint(
              painter: _ExplorerGridPainter(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: gridAlpha),
              ),
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  if (split.pinned.isNotEmpty)
                    _buildSection(
                      context: context,
                      groupIndex: 0,
                      totalGroups: orderedGroups.length + 1,
                      ownerLabel: 'Pinned',
                      ownerId: 'pinned',
                      sectionItems: split.pinned,
                      hasDownloadAllAction: false,
                      columns: columns,
                      normalizedIconSize: normalizedIconSize,
                    ),
                  for (var i = 0; i < orderedGroups.length; i++)
                    _buildSection(
                      context: context,
                      groupIndex: split.pinned.isEmpty ? i : i + 1,
                      totalGroups:
                          orderedGroups.length + (split.pinned.isEmpty ? 0 : 1),
                      ownerLabel: orderedGroups[i].ownerName,
                      ownerId: orderedGroups[i].ownerId,
                      sectionItems: orderedGroups[i].items,
                      hasDownloadAllAction: true,
                      columns: columns,
                      normalizedIconSize: normalizedIconSize,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSection({
    required BuildContext context,
    required int groupIndex,
    required int totalGroups,
    required String ownerLabel,
    required String ownerId,
    required List<ShareItem> sectionItems,
    required bool hasDownloadAllAction,
    required int columns,
    required double normalizedIconSize,
  }) {
    final hasRemoteItems = sectionItems.any((item) => !item.local);
    return Padding(
      padding: EdgeInsets.only(bottom: groupIndex == totalGroups - 1 ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    ownerLabel,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                if (hasDownloadAllAction && hasRemoteItems)
                  TextButton.icon(
                    onPressed: () {
                      unawaited(
                        onDownloadAllFromOwner(
                          ownerId,
                          ownerLabel,
                          sectionItems,
                        ),
                      );
                    },
                    icon: const Icon(Icons.download, size: 14),
                    label: const Text('Download all...'),
                  ),
              ],
            ),
          ),
          if (layoutMode == ItemLayoutMode.grid)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.9,
              ),
              itemCount: sectionItems.length,
              itemBuilder: (context, index) {
                final item = sectionItems[index];
                return IconTile(
                  key: ValueKey(item.key),
                  item: item,
                  createItem: buildDragItem,
                  selected: selectedKeys.contains(item.key),
                  onTap: () => onToggleSelection(item),
                  isFavorite: isFavorite(item),
                  onToggleFavorite: () => onToggleFavorite(item),
                  note: noteForItem(item),
                  onEditNote: () => onEditNote(item),
                  onRemove: item.local ? () => onRemove(item) : null,
                  onDownload: item.local ? null : () => onDownload(item),
                  iconSize: normalizedIconSize,
                );
              },
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sectionItems.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final item = sectionItems[index];
                return IconTile(
                  key: ValueKey(item.key),
                  item: item,
                  createItem: buildDragItem,
                  selected: selectedKeys.contains(item.key),
                  onTap: () => onToggleSelection(item),
                  isFavorite: isFavorite(item),
                  onToggleFavorite: () => onToggleFavorite(item),
                  note: noteForItem(item),
                  onEditNote: () => onEditNote(item),
                  onRemove: item.local ? () => onRemove(item) : null,
                  onDownload: item.local ? null : () => onDownload(item),
                  compact: true,
                  iconSize: normalizedIconSize,
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ExplorerGridPainter extends CustomPainter {
  _ExplorerGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 48.0;
    for (double x = spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ExplorerGridPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class IconTile extends StatefulWidget {
  const IconTile({
    super.key,
    required this.item,
    required this.createItem,
    this.selected = false,
    this.onTap,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.note,
    this.onEditNote,
    required this.onRemove,
    required this.onDownload,
    this.compact = false,
    this.iconSize = 64,
  });

  final ShareItem item;
  final Future<DragItem?> Function(ShareItem) createItem;
  final bool selected;
  final VoidCallback? onTap;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final String? note;
  final Future<void> Function()? onEditNote;
  final VoidCallback? onRemove;
  final Future<void> Function()? onDownload;
  final bool compact;
  final double iconSize;

  @override
  State<IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<IconTile> {
  bool dragging = false;
  static const int _menuDownloadAs = 1;
  static const int _menuRemove = 2;
  static const int _menuToggleFavorite = 3;
  static const int _menuEditNote = 4;

  Future<DragItem?> _provider(DragItemRequest r) async {
    void upd() {
      final isDragging = r.session.dragging.value;
      if (mounted && dragging != isDragging) {
        setState(() => dragging = isDragging);
      }
      if (!isDragging) {
        // Remove this listener once the drag session ends.
        r.session.dragging.removeListener(upd);
      }
    }

    try {
      r.session.dragging.addListener(upd);
      upd();
      final item = await widget.createItem(widget.item);
      if (item == null) return null;
      return item;
    } catch (e, st) {
      _diagnostics.warn(
        'Drag provider failed for ${widget.item.name}',
        error: e,
        stack: st,
      );
      return null;
    }
  }

  Future<void> _showContextMenu(TapDownDetails details) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          details.globalPosition.dx,
          details.globalPosition.dy,
          1,
          1,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<int>(
          value: _menuToggleFavorite,
          child: Text(widget.isFavorite ? 'Unpin' : 'Pin'),
        ),
        if (widget.onEditNote != null)
          const PopupMenuItem<int>(
            value: _menuEditNote,
            child: Text('Edit Note...'),
          ),
        if (widget.onDownload != null)
          const PopupMenuItem<int>(
            value: _menuDownloadAs,
            child: Text('Download As...'),
          ),
        if (widget.onRemove != null)
          const PopupMenuItem<int>(value: _menuRemove, child: Text('Remove')),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case _menuToggleFavorite:
        widget.onToggleFavorite();
        break;
      case _menuDownloadAs:
        await widget.onDownload?.call();
        break;
      case _menuEditNote:
        await widget.onEditNote?.call();
        break;
      case _menuRemove:
        widget.onRemove?.call();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconData = _iconForName(widget.item.name);
    final iconColor = _iconColorForName(widget.item.name, theme);
    final iconBytes = widget.item.iconBytes;
    final note = widget.note == null ? '' : normalizeItemNote(widget.note!);
    final hasNote = note.isNotEmpty;
    final iconSize = widget.iconSize.clamp(44.0, 96.0);
    final iconGlyphSize = max(20.0, min(iconSize * 0.56, 44.0));
    final label = p.basename(widget.item.name);
    final badges = Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: widget.item.local
                ? Colors.greenAccent.shade100.withValues(alpha: 0.25)
                : Colors.blueAccent.shade100.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            widget.item.local ? 'LOCAL' : 'REMOTE',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            widget.item.owner,
            style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
          ),
        ),
      ],
    );

    final iconCard = Stack(
      children: [
        Container(
          width: iconSize,
          height: iconSize,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(widget.compact ? 10 : 12),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: iconBytes == null
              ? Icon(iconData, size: iconGlyphSize, color: iconColor)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(widget.compact ? 8 : 10),
                  child: Image.memory(
                    iconBytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: widget.item.local
                  ? Colors.greenAccent.shade400
                  : Colors.blueAccent.shade200,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.surface, width: 1.2),
            ),
          ),
        ),
        if (widget.selected)
          Positioned(
            left: 4,
            top: 4,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check,
                size: 12,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        if (hasNote)
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sticky_note_2_outlined,
                size: 10,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
      ],
    );

    final actionButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: widget.isFavorite ? 'Unpin' : 'Pin',
          visualDensity: VisualDensity.compact,
          onPressed: widget.onToggleFavorite,
          icon: Icon(
            widget.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
            size: 16,
          ),
        ),
        if (widget.onDownload != null)
          IconButton(
            tooltip: 'Download...',
            visualDensity: VisualDensity.compact,
            onPressed: () => widget.onDownload?.call(),
            icon: const Icon(Icons.download, size: 16),
          ),
        if (widget.onEditNote != null)
          IconButton(
            tooltip: hasNote ? 'Edit note' : 'Add note',
            visualDensity: VisualDensity.compact,
            onPressed: () => widget.onEditNote?.call(),
            icon: Icon(
              hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
              size: 16,
            ),
          ),
        if (widget.onRemove != null)
          IconButton(
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onRemove,
            icon: const Icon(Icons.close, size: 16),
          ),
      ],
    );

    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: _provider,
      child: DraggableWidget(
        child: AnimatedOpacity(
          opacity: dragging ? 0.6 : 1,
          duration: const Duration(milliseconds: 90),
          child: Tooltip(
            message: hasNote
                ? '${widget.item.rel}\n${_fmt(widget.item.size)} • ${widget.item.owner}\nNote: $note'
                : '${widget.item.rel}\n${_fmt(widget.item.size)} • ${widget.item.owner}',
            waitDuration: const Duration(milliseconds: 500),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onSecondaryTapDown: _showContextMenu,
              child: widget.compact
                  ? Container(
                      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? theme.colorScheme.primaryContainer.withValues(
                                alpha: 0.38,
                              )
                            : theme.colorScheme.surface.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: widget.selected
                              ? theme.colorScheme.primary.withValues(alpha: 0.8)
                              : theme.colorScheme.outlineVariant.withValues(
                                  alpha: 0.42,
                                ),
                        ),
                      ),
                      child: Row(
                        children: [
                          iconCard,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_fmt(widget.item.size)} • ${widget.item.rel}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 4),
                                badges,
                              ],
                            ),
                          ),
                          actionButtons,
                        ],
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? theme.colorScheme.primaryContainer.withValues(
                                alpha: 0.28,
                              )
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: widget.selected
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.78,
                                )
                              : Colors.transparent,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          iconCard,
                          const SizedBox(height: 8),
                          badges,
                          const SizedBox(height: 6),
                          SizedBox(
                            width: max(96.0, iconSize + 36),
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          actionButtons,
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferPanel extends StatelessWidget {
  const _TransferPanel({
    required this.transfers,
    required this.onClearFinished,
    required this.onCancelTransfer,
    required this.onOpenTransferLocation,
  });

  final List<TransferEntry> transfers;
  final VoidCallback onClearFinished;
  final void Function(String transferId) onCancelTransfer;
  final void Function(String transferId) onOpenTransferLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = transfers
        .where((t) => t.state == TransferState.running)
        .length;
    final finished = transfers.length - active;

    return Align(
      alignment: Alignment.bottomRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.swap_horiz, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Transfers: $active active, $finished finished',
                      style: theme.textTheme.labelLarge,
                    ),
                    const Spacer(),
                    if (finished > 0)
                      TextButton(
                        onPressed: onClearFinished,
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: transfers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _TransferRow(
                        transfer: transfers[index],
                        onCancelTransfer: onCancelTransfer,
                        onOpenTransferLocation: onOpenTransferLocation,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.transfer,
    required this.onCancelTransfer,
    required this.onOpenTransferLocation,
  });

  final TransferEntry transfer;
  final void Function(String transferId) onCancelTransfer;
  final void Function(String transferId) onOpenTransferLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = transfer.direction == TransferDirection.download
        ? Icons.south_east
        : Icons.north_west;
    final progress = transfer.totalBytes <= 0
        ? null
        : (transfer.transferredBytes / transfer.totalBytes)
              .clamp(0, 1)
              .toDouble();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    transfer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _transferStateLabel(transfer.state),
                  style: theme.textTheme.labelSmall,
                ),
                if (transfer.state == TransferState.running &&
                    transfer.direction == TransferDirection.download)
                  IconButton(
                    tooltip: 'Cancel transfer',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onCancelTransfer(transfer.id),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                if (transfer.state == TransferState.completed &&
                    transfer.outputPath != null)
                  IconButton(
                    tooltip: 'Open containing folder',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onOpenTransferLocation(transfer.id),
                    icon: const Icon(Icons.folder_open, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              transfer.peerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              _transferStats(transfer),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _transferStats(TransferEntry t) {
    if (t.state == TransferState.failed) {
      return t.error == null ? 'Failed' : 'Failed: ${t.error}';
    }
    if (t.state == TransferState.canceled) {
      return 'Canceled';
    }
    if (t.state == TransferState.completed) {
      final duration = t.updatedAt.difference(t.startedAt);
      return '${_fmt(t.totalBytes)} in ${_fmtDuration(duration)}';
    }
    final eta = t.eta;
    final etaText = eta == null ? '' : ' • ETA ${_fmtDuration(eta)}';
    return '${_fmt(t.transferredBytes)} / ${_fmt(t.totalBytes)} • '
        '${_fmtRate(t.speedBytesPerSecond)}$etaText';
  }
}

String _transferStateLabel(TransferState state) {
  switch (state) {
    case TransferState.running:
      return 'Running';
    case TransferState.completed:
      return 'Done';
    case TransferState.failed:
      return 'Failed';
    case TransferState.canceled:
      return 'Canceled';
  }
}

Future<List<String>> _readDroppedPaths(PerformDropEvent event) async {
  final paths = <String>[];
  final seen = <String>{};
  final futures = <Future<void>>[];

  for (final item in event.session.items) {
    final reader = item.dataReader;
    if (reader == null) {
      continue;
    }

    if (reader.canProvide(Formats.fileUri)) {
      final completer = Completer<void>();
      futures.add(completer.future);
      reader.getValue<Uri>(Formats.fileUri, (value) {
        if (value != null) {
          final path = _uriToPath(value);
          _addDroppedPath(paths, seen, path);
        }
        completer.complete();
      }, onError: (_) => completer.complete());
    } else if (reader.canProvide(Formats.plainText)) {
      final completer = Completer<void>();
      futures.add(completer.future);
      reader.getValue<String>(Formats.plainText, (value) {
        if (value != null && value.isNotEmpty) {
          for (final line in value.split(RegExp(r'[\r\n]+'))) {
            _addDroppedPath(paths, seen, line);
          }
        }
        completer.complete();
      }, onError: (_) => completer.complete());
    }
  }

  if (futures.isNotEmpty) {
    await Future.wait(futures);
  }

  return paths;
}

void _addDroppedPath(List<String> out, Set<String> seen, String raw) {
  var path = raw.trim();
  if (path.isEmpty) {
    return;
  }
  if (path.length > 1 && path.startsWith('"') && path.endsWith('"')) {
    path = path.substring(1, path.length - 1);
  }
  if (path.startsWith('file://')) {
    try {
      path = _uriToPath(Uri.parse(path));
    } catch (_) {
      return;
    }
  }
  path = p.normalize(path);
  final key = Platform.isWindows ? path.toLowerCase() : path;
  if (!seen.add(key)) {
    return;
  }
  out.add(path);
}

String _uriToPath(Uri uri) {
  try {
    if (uri.isScheme('file')) {
      return uri.toFilePath(windows: Platform.isWindows);
    }
  } catch (_) {}
  try {
    return p.fromUri(uri);
  } catch (_) {
    return uri.toString();
  }
}

String _safeFileName(String name) {
  final sanitized = name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1F]'), '_')
      .trim();
  if (sanitized.isEmpty) return 'file';
  if (sanitized == '.' || sanitized == '..') return 'file';
  return sanitized;
}

bool _isValidRemoteFileName(String name) {
  return nv.isValidRemoteFileName(name, maxChars: _maxItemNameChars);
}

bool _isValidRelativePath(String rel) {
  return nv.isValidRelativePath(rel, maxChars: _maxRelativePathChars);
}

class Controller extends ChangeNotifier {
  final deviceId = _id();
  final deviceName = Platform.localHostname;

  final Map<String, LocalItem> _local = {};
  final Map<String, String> _pathToId = {};
  final Map<String, Peer> peers = {};

  RawDatagramSocket? _udp;
  ServerSocket? _tcp;
  Timer? _announce;
  Timer? _refresh;
  Timer? _prune;
  Timer? _housekeeping;

  int listenPort = 0;
  int revision = 0;
  int _counter = 0;
  List<String> localIps = [];
  bool multicastEnabled = false;
  int nudgeTick = 0;
  final Map<String, Uint8List> _iconCache = {};
  final Map<String, String> peerHealth = {};
  final Map<String, String> peerStatus = {};
  final Map<String, String> incompatiblePeers = {};
  final Map<String, DateTime> _lastNudgeFrom = {};
  final Map<String, TransferEntry> _transfers = {};
  final Map<String, Timer> _transferDismissTimers = {};
  final Set<String> _canceledTransfers = <String>{};
  final Map<String, Future<String?>> _dragMaterializationInFlight = {};
  final _SlidingRateLimiter _udpRateLimiter = _SlidingRateLimiter();
  final _SlidingRateLimiter _tcpRateLimiter = _SlidingRateLimiter();
  final _PerPeerRateLimiter _uploadRateLimiter = _PerPeerRateLimiter();
  final _PerPeerRateLimiter _downloadRateLimiter = _PerPeerRateLimiter();
  final Map<String, int> _activePeerUploads = <String, int>{};
  final Map<String, int> _activePeerDownloads = <String, int>{};
  final Map<String, int> _networkDiagnostics = <String, int>{};
  bool _latencyProfilingEnabled = false;
  final Map<String, DateTime> _peerFirstSeenAt = <String, DateTime>{};
  final Map<String, Duration> _peerFirstSyncLatency = <String, Duration>{};
  int _transferCounter = 0;
  int _activeInboundClients = 0;
  DateTime _lastTransferNotify = DateTime.fromMillisecondsSinceEpoch(0);
  String _sharedRoomKey = '';
  final Set<String> _peerAllowlist = <String>{};
  final Set<String> _peerBlocklist = <String>{};
  bool _autoUpdateChecks = false;
  UpdateChannel _updateChannel = UpdateChannel.stable;
  DiscoveryProfile _discoveryProfile = DiscoveryProfile.balanced;
  DateTime _lastDiscoveryProfileEval = DateTime.fromMillisecondsSinceEpoch(0);
  String? latestReleaseTag;
  String? latestReleaseUrl;
  final int _simulatedLatencyMs = max(
    0,
    int.tryParse(Platform.environment[_simLatencyEnv] ?? '') ?? 0,
  );
  final int _simulatedDropPercent =
      (int.tryParse(Platform.environment[_simDropEnv] ?? '') ?? 0).clamp(0, 95);
  final Random _simRandom = Random();

  String get sharedRoomKey => _sharedRoomKey;
  Set<String> get peerAllowlist => Set<String>.unmodifiable(_peerAllowlist);
  Set<String> get peerBlocklist => Set<String>.unmodifiable(_peerBlocklist);

  void setSharedRoomKey(String key) {
    _sharedRoomKey = key.trim();
  }

  void setTrustLists({
    required Set<String> allowlist,
    required Set<String> blocklist,
  }) {
    Set<String> sanitize(Set<String> input) {
      final out = <String>{};
      for (final raw in input) {
        final token = _normalizeTrustKey(raw);
        if (token.isEmpty || token.length > 128) continue;
        out.add(token);
      }
      return out;
    }

    final nextAllow = sanitize(allowlist);
    final nextBlock = sanitize(blocklist);
    nextAllow.removeWhere(nextBlock.contains);
    if (_stringSetEquals(nextAllow, _peerAllowlist) &&
        _stringSetEquals(nextBlock, _peerBlocklist)) {
      return;
    }
    _peerAllowlist
      ..clear()
      ..addAll(nextAllow);
    _peerBlocklist
      ..clear()
      ..addAll(nextBlock);
    _dropUntrustedPeers();
    _evaluateDiscoveryProfile(force: true);
    _broadcast();
    notifyListeners();
  }

  bool _isPeerTrusted({
    String? peerId,
    required String remoteAddress,
    int? remotePort,
    bool countDiagnostics = true,
  }) {
    final keys = buildTrustCandidateKeys(
      peerId: peerId,
      address: remoteAddress,
      port: remotePort,
    );
    for (final key in keys) {
      if (_peerBlocklist.contains(key)) {
        if (countDiagnostics) _incDiagnostic('trust_block_drop');
        return false;
      }
    }
    if (_peerAllowlist.isEmpty) return true;
    for (final key in keys) {
      if (_peerAllowlist.contains(key)) {
        return true;
      }
    }
    if (countDiagnostics) _incDiagnostic('trust_allowlist_drop');
    return false;
  }

  bool _dropUntrustedPeers() {
    final removeIds = <String>[];
    for (final entry in peers.entries) {
      final peer = entry.value;
      if (_isPeerTrusted(
        peerId: peer.id,
        remoteAddress: peer.addr.address,
        remotePort: peer.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      removeIds.add(entry.key);
    }
    if (removeIds.isEmpty) return false;
    for (final id in removeIds) {
      peers.remove(id);
      peerStatus.remove(id);
      peerHealth.remove(id);
      _peerFirstSeenAt.remove(id);
      _peerFirstSyncLatency.remove(id);
    }
    return true;
  }

  void setAutoUpdateChecks(bool value) {
    _autoUpdateChecks = value;
  }

  void setUpdateChannel(UpdateChannel channel) {
    _updateChannel = channel;
  }

  Map<String, int> get networkDiagnostics =>
      Map<String, int>.unmodifiable(_networkDiagnostics);
  DiscoveryProfile get discoveryProfile => _discoveryProfile;
  bool get latencyProfilingEnabled => _latencyProfilingEnabled;
  Map<String, Duration> get peerFirstSyncLatency =>
      Map<String, Duration>.unmodifiable(_peerFirstSyncLatency);
  PeerState peerState(Peer peer) {
    final now = DateTime.now();
    if (now.difference(peer.lastGoodContact) > const Duration(seconds: 12)) {
      return PeerState.stale;
    }
    if (peer.fetching) {
      return PeerState.syncing;
    }
    if (!peer.hasManifest) {
      return PeerState.discovered;
    }
    return PeerState.reachable;
  }

  PeerAvailability peerAvailability(Peer peer) {
    final age = DateTime.now().difference(peer.lastGoodContact);
    if (age <= const Duration(seconds: 5)) return PeerAvailability.active;
    if (age <= const Duration(seconds: 20)) return PeerAvailability.away;
    return PeerAvailability.idle;
  }

  PeerHealthSummary peerHealthSummary(Peer peer) {
    final now = DateTime.now();
    final state = peerState(peer);
    return evaluatePeerHealth(
      contactAge: now.difference(peer.lastGoodContact),
      hasManifest: peer.hasManifest,
      fetchFailureStreak: peer.fetchFailureStreak,
      state: state,
    );
  }

  void _incDiagnostic(String key) {
    _networkDiagnostics.update(key, (v) => v + 1, ifAbsent: () => 1);
  }

  bool _shouldSimulateDrop(String channel) {
    if (_simulatedDropPercent <= 0) return false;
    if (_simRandom.nextInt(100) >= _simulatedDropPercent) return false;
    _incDiagnostic('sim_drop_$channel');
    return true;
  }

  Future<void> _simulateLatency() async {
    if (_simulatedLatencyMs <= 0) return;
    await Future<void>.delayed(Duration(milliseconds: _simulatedLatencyMs));
  }

  void setLatencyProfilingEnabled(bool enabled) {
    _latencyProfilingEnabled = enabled;
    if (!enabled) {
      _peerFirstSeenAt.clear();
      _peerFirstSyncLatency.clear();
    }
  }

  Duration _announceIntervalForProfile(DiscoveryProfile profile) {
    switch (profile) {
      case DiscoveryProfile.highReliability:
        return _announceIntervalHighReliability;
      case DiscoveryProfile.balanced:
        return _announceInterval;
      case DiscoveryProfile.lowTraffic:
        return _announceIntervalLowTraffic;
    }
  }

  Duration _refreshIntervalForProfile(DiscoveryProfile profile) {
    switch (profile) {
      case DiscoveryProfile.highReliability:
        return _refreshIntervalHighReliability;
      case DiscoveryProfile.balanced:
        return _refreshInterval;
      case DiscoveryProfile.lowTraffic:
        return _refreshIntervalLowTraffic;
    }
  }

  void _startDiscoveryTimers() {
    _announce?.cancel();
    _refresh?.cancel();
    _announce = Timer.periodic(
      _announceIntervalForProfile(_discoveryProfile),
      (_) => _broadcast(),
    );
    _refresh = Timer.periodic(
      _refreshIntervalForProfile(_discoveryProfile),
      (_) => refreshAll(),
    );
  }

  void _evaluateDiscoveryProfile({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastDiscoveryProfileEval) <
            const Duration(seconds: 3)) {
      return;
    }
    _lastDiscoveryProfileEval = now;
    var repeatedFailures = 0;
    for (final peer in peers.values) {
      if (peer.fetchFailureStreak >= 3) {
        repeatedFailures++;
      }
    }
    final rateLimitEvents =
        (_networkDiagnostics['udp_rate_limited'] ?? 0) +
        (_networkDiagnostics['tcp_req_rate_limited'] ?? 0);
    final next = selectDiscoveryProfile(
      connectedPeers: connectedPeerCount,
      repeatedFetchFailures: repeatedFailures,
      rateLimitEvents: rateLimitEvents,
    );
    if (next == _discoveryProfile) return;
    _discoveryProfile = next;
    _startDiscoveryTimers();
    notifyListeners();
  }

  Future<String> checkForUpdates() async {
    try {
      final client = HttpClient();
      try {
        final channel = _updateChannel;
        final endpoint = channel == UpdateChannel.stable
            ? _latestReleaseApiUrl
            : _allReleasesApiUrl;
        final req = await client.getUrl(Uri.parse(endpoint));
        req.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        req.headers.set(HttpHeaders.userAgentHeader, 'FileShare');
        final resp = await req.close().timeout(const Duration(seconds: 6));
        if (resp.statusCode != 200) {
          return 'Update check failed: HTTP ${resp.statusCode}';
        }
        final body = await utf8.decoder.bind(resp).join();
        Map<String, dynamic>? map;
        if (channel == UpdateChannel.stable) {
          map = _decodeJsonMap(body);
        } else {
          Map<String, dynamic>? asMap(Object? raw) {
            if (raw is Map<String, dynamic>) return raw;
            if (raw is Map) {
              final out = <String, dynamic>{};
              for (final entry in raw.entries) {
                if (entry.key is String) {
                  out[entry.key as String] = entry.value;
                }
              }
              return out;
            }
            return null;
          }

          final list = _decodeJsonList(body);
          if (list != null) {
            if (channel == UpdateChannel.beta) {
              for (final entry in list) {
                final candidate = asMap(entry);
                if (candidate == null) continue;
                if (candidate['prerelease'] == true) {
                  map = candidate;
                  break;
                }
              }
            } else if (channel == UpdateChannel.nightly) {
              for (final entry in list) {
                final candidate = asMap(entry);
                if (candidate == null || candidate['prerelease'] != true) {
                  continue;
                }
                final tag = _safeString(candidate['tag_name'], maxChars: 64);
                if (tag != null && tag.toLowerCase().contains('nightly')) {
                  map = candidate;
                  break;
                }
              }
              if (map == null) {
                for (final entry in list) {
                  final candidate = asMap(entry);
                  if (candidate != null && candidate['prerelease'] == true) {
                    map = candidate;
                    break;
                  }
                }
              }
            }
          }
        }
        if (map == null) {
          return 'No ${updateChannelLabel(channel).toLowerCase()} release found';
        }
        final tag = _safeString(map['tag_name'], maxChars: 64);
        final url = _safeString(map['html_url'], maxChars: 512);
        latestReleaseTag = tag;
        latestReleaseUrl = url ?? _latestReleasePageUrl;
        notifyListeners();
        if (tag == null) return 'Latest release found';
        return '${updateChannelLabel(channel)} release: $tag';
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      return 'Update check failed: $e';
    }
  }

  Future<void> openLatestReleasePage() async {
    final url = latestReleaseUrl ?? _latestReleasePageUrl;
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
      return;
    }
    await Process.run('xdg-open', [url]);
  }

  bool _acquirePeerSlot(Map<String, int> slots, String key, int maxSlots) {
    final current = slots[key] ?? 0;
    if (current >= maxSlots) return false;
    slots[key] = current + 1;
    return true;
  }

  void _releasePeerSlot(Map<String, int> slots, String key) {
    final current = slots[key];
    if (current == null) return;
    if (current <= 1) {
      slots.remove(key);
      return;
    }
    slots[key] = current - 1;
  }

  int get connectedPeerCount {
    final now = DateTime.now();
    return peers.values
        .where((p) => now.difference(p.lastGoodContact) <= _peerPruneAfter)
        .length;
  }

  List<TransferEntry> get transfers {
    final out = _transfers.values.toList(growable: false);
    out.sort((a, b) {
      final aRunning = a.state == TransferState.running ? 0 : 1;
      final bRunning = b.state == TransferState.running ? 0 : 1;
      final byState = aRunning.compareTo(bRunning);
      if (byState != 0) return byState;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return out;
  }

  List<ShareItem> get items {
    final out = <ShareItem>[];
    for (final e in _local.values) {
      out.add(
        ShareItem(
          ownerId: deviceId,
          owner: deviceName,
          itemId: e.id,
          name: e.name,
          rel: e.rel,
          size: e.size,
          local: true,
          path: e.path,
          iconBytes: e.iconBytes,
          peerId: null,
        ),
      );
    }
    for (final p in peers.values) {
      for (final e in p.items) {
        out.add(
          ShareItem(
            ownerId: p.id,
            owner: p.name,
            itemId: e.id,
            name: e.name,
            rel: e.rel,
            size: e.size,
            local: false,
            path: null,
            iconBytes: e.iconBytes,
            peerId: p.id,
          ),
        );
      }
    }
    out.sort((a, b) {
      final o = a.owner.compareTo(b.owner);
      if (o != 0) return o;
      return a.rel.compareTo(b.rel);
    });
    return out;
  }

  Future<void> start() async {
    try {
      _tcp = await ServerSocket.bind(InternetAddress.anyIPv4, _transferPort);
    } on SocketException {
      _tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    listenPort = _tcp!.port;
    _tcp!.listen(_onClient);

    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
    );
    _udp!.broadcastEnabled = true;
    try {
      _udp!.multicastLoopback = true;
      _udp!.multicastHops = 1;
      _udp!.joinMulticast(InternetAddress(_discoveryMulticastGroup));
      multicastEnabled = true;
    } catch (_) {
      multicastEnabled = false;
    }
    _udp!.listen(_onUdp);

    _startDiscoveryTimers();
    _prune = Timer.periodic(_pruneInterval, (_) => _prunePeers());
    _housekeeping = Timer.periodic(
      _housekeepingInterval,
      (_) => unawaited(_cleanupDragCache()),
    );

    await _loadIps();
    _evaluateDiscoveryProfile(force: true);
    unawaited(_cleanupDragCache());
    if (_autoUpdateChecks) {
      unawaited(checkForUpdates());
    }
    _broadcast();
    notifyListeners();
  }

  @override
  void dispose() {
    _announce?.cancel();
    _refresh?.cancel();
    _prune?.cancel();
    _housekeeping?.cancel();
    for (final timer in _transferDismissTimers.values) {
      timer.cancel();
    }
    _transferDismissTimers.clear();
    _udp?.close();
    _tcp?.close();
    super.dispose();
  }

  Future<void> _cleanupDragCache() async {
    try {
      final appDir = await _appDataDir();
      final dragDir = Directory(p.join(appDir.path, 'drag_cache'));
      if (!await dragDir.exists()) return;
      final now = DateTime.now();
      final files = <FileSystemEntity>[];
      int totalBytes = 0;
      await for (final entity in dragDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > _dragCacheMaxAge) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        totalBytes += stat.size;
        files.add(entity);
      }

      if (totalBytes <= _dragCacheMaxBytes) return;
      files.sort((a, b) {
        final sa = a.statSync();
        final sb = b.statSync();
        return sa.modified.compareTo(sb.modified);
      });
      for (final file in files) {
        if (totalBytes <= _dragCacheMaxBytes) break;
        try {
          final len = await (file as File).length();
          await file.delete();
          totalBytes = max(0, totalBytes - len);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> addDropped(List<String> paths) async {
    var changed = false;
    for (final path in paths) {
      changed = await _addPath(path) || changed;
    }
    if (changed) {
      revision++;
      _broadcast();
      notifyListeners();
    }
  }

  Map<String, dynamic> _buildNudgePayload() {
    return _withAuth(<String, dynamic>{
      'tag': _tag,
      'type': 'nudge',
      'protocolMajor': _protocolMajor,
      'protocolMinor': _protocolMinor,
      'id': deviceId,
      'name': deviceName,
      'clientId': deviceId,
      'clientName': deviceName,
      'clientPort': listenPort,
      'clientRevision': revision,
    });
  }

  void sendNudge() {
    final u = _udp;
    if (u == null) return;
    final payloadMap = _buildNudgePayload();
    final payloadBytes = utf8.encode(jsonEncode(payloadMap));
    for (final target in _broadcastTargets()) {
      if (_shouldSimulateDrop('udp_out_nudge')) continue;
      u.send(payloadBytes, target, _discoveryPort);
    }
    if (multicastEnabled) {
      if (!_shouldSimulateDrop('udp_out_nudge')) {
        u.send(
          payloadBytes,
          InternetAddress(_discoveryMulticastGroup),
          _discoveryPort,
        );
      }
    }

    // Broadcast can be asymmetric on some LAN setups; also nudge peers directly.
    final sent = <String>{};
    for (final p in peers.values) {
      if (!_isPeerTrusted(
        peerId: p.id,
        remoteAddress: p.addr.address,
        remotePort: p.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      final ip = p.addr.address;
      if (!sent.add(ip)) continue;
      if (_shouldSimulateDrop('udp_out_nudge')) continue;
      u.send(payloadBytes, p.addr, _discoveryPort);
      unawaited(_sendNudgeTcp(p, payloadMap));
    }
  }

  void sendNudgeToPeerIds(Set<String> peerIds) {
    if (peerIds.isEmpty) return;
    final u = _udp;
    if (u == null) return;
    final payloadMap = _buildNudgePayload();
    final payloadBytes = utf8.encode(jsonEncode(payloadMap));
    final sent = <String>{};
    for (final peerId in peerIds) {
      final p = peers[peerId];
      if (p == null) continue;
      if (!_isPeerTrusted(
        peerId: p.id,
        remoteAddress: p.addr.address,
        remotePort: p.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      final ip = p.addr.address;
      if (!sent.add(ip)) continue;
      if (_shouldSimulateDrop('udp_out_nudge')) continue;
      u.send(payloadBytes, p.addr, _discoveryPort);
      unawaited(_sendNudgeTcp(p, payloadMap));
    }
  }

  Future<void> addClipboardText(String text, {String? fileName}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final appDir = await _appDataDir();
    final clipDir = Directory(p.join(appDir.path, 'clipboard'));
    await clipDir.create(recursive: true);
    final base = _safeFileName(
      (fileName ?? buildClipboardShareName(DateTime.now())).trim(),
    );
    final candidateBase = base.toLowerCase().endsWith('.txt')
        ? base
        : '$base.txt';
    var target = File(p.join(clipDir.path, candidateBase));
    var counter = 2;
    while (await target.exists()) {
      final ext = p.extension(candidateBase);
      final stem = ext.isEmpty
          ? candidateBase
          : candidateBase.substring(0, candidateBase.length - ext.length);
      target = File(p.join(clipDir.path, '$stem ($counter)$ext'));
      counter++;
    }
    await target.writeAsString(trimmed, flush: true);
    final changed = await _addPath(target.path);
    if (changed) {
      revision++;
      _broadcast();
      notifyListeners();
    }
  }

  bool sendProbe(String raw) {
    final u = _udp;
    if (u == null) return false;
    var host = raw.trim();
    var port = _discoveryPort;
    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length == 2) {
        final parsed = int.tryParse(parts[1]);
        if (parsed != null) {
          host = parts[0];
          port = parsed;
        }
      }
    }
    InternetAddress? addr;
    try {
      addr = InternetAddress(host);
    } catch (_) {
      return false;
    }
    final payload = jsonEncode(
      _withAuth({
        'tag': _tag,
        'type': 'probe',
        'protocolMajor': _protocolMajor,
        'protocolMinor': _protocolMinor,
        'id': deviceId,
        'name': deviceName,
        'port': listenPort,
        'revision': revision,
      }),
    );
    if (_shouldSimulateDrop('udp_out_probe')) return true;
    u.send(utf8.encode(payload), addr, port);
    return true;
  }

  void _applyManifestToPeer({
    required InternetAddress addr,
    required int port,
    required ({String id, String name, int revision, List<RemoteItem> items})
    manifest,
    bool notify = true,
  }) {
    final id = manifest.id;
    if (!_isPeerTrusted(
      peerId: id,
      remoteAddress: addr.address,
      remotePort: port,
    )) {
      return;
    }
    final name = manifest.name;
    final rev = manifest.revision;
    final list = manifest.items;
    final now = DateTime.now();
    final p = peers.putIfAbsent(
      id,
      () => Peer(
        id: id,
        name: name,
        addr: addr,
        port: port,
        rev: rev,
        items: [],
        lastSeen: now,
        lastGoodContact: now,
      ),
    );
    p
      ..name = name
      ..addr = addr
      ..port = port
      ..rev = rev
      ..lastSeen = now
      ..lastGoodContact = now
      ..hasManifest = true;
    _mergeDuplicatePeersFor(id);
    p.items
      ..clear()
      ..addAll(list);
    peerStatus[id] = 'OK (${list.length} items)';
    if (notify) {
      notifyListeners();
    }
  }

  Future<bool> _probePeerAddress(
    InternetAddress addr,
    int port, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    if (!_isPeerTrusted(
      peerId: null,
      remoteAddress: addr.address,
      remotePort: port,
      countDiagnostics: false,
    )) {
      return false;
    }
    try {
      if (_shouldSimulateDrop('tcp_out_sweep_probe')) return false;
      final s = await Socket.connect(addr, port, timeout: timeout);
      try {
        await _sendManifestRequest(s);
        ({String id, String name, int revision, List<RemoteItem> items})?
        manifest;
        try {
          manifest = await _readManifestFromSocket(
            s,
            fallbackId: '${addr.address}:$port',
            fallbackName: addr.address,
          ).timeout(timeout);
        } on _ProtocolMismatchException {
          _incDiagnostic('sweep_protocol_mismatch');
          return false;
        }
        if (manifest == null) return false;
        _applyManifestToPeer(
          addr: addr,
          port: port,
          manifest: manifest,
          notify: false,
        );
        return true;
      } finally {
        await s.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<String> sweepLocalSubnets() async {
    final targets = buildSubnetSweepTargets(localIps);
    if (targets.isEmpty) {
      return 'Sweep skipped: no local IPv4 subnet detected';
    }
    var scanned = 0;
    var found = 0;
    final queue = Queue<String>.from(targets);
    final workers = min(24, queue.length);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final host = queue.removeFirst();
        scanned++;
        InternetAddress? addr;
        try {
          addr = InternetAddress(host);
        } catch (_) {
          continue;
        }
        final ok = await _probePeerAddress(addr, _transferPort);
        if (ok) {
          found++;
        }
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    if (found > 0) {
      notifyListeners();
    }
    return 'Sweep complete: scanned $scanned hosts, found $found peer${found == 1 ? '' : 's'}';
  }

  Future<String> addPeerByAddress(String raw) async {
    var host = raw.trim();
    var port = _transferPort;
    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length == 2) {
        final parsed = int.tryParse(parts[1]);
        if (parsed != null) {
          host = parts[0];
          port = parsed;
        }
      }
    }
    InternetAddress? addr;
    try {
      addr = InternetAddress(host);
    } catch (_) {
      return 'Invalid IP';
    }
    if (!_isPeerTrusted(
      peerId: null,
      remoteAddress: addr.address,
      remotePort: port,
      countDiagnostics: false,
    )) {
      return 'Blocked by trust policy';
    }
    try {
      if (_shouldSimulateDrop('tcp_out_connect')) {
        return 'Simulated drop (tcp_out_connect)';
      }
      await _simulateLatency();
      final s = await Socket.connect(
        addr,
        port,
        timeout: const Duration(seconds: 5),
      );
      try {
        await _sendManifestRequest(s);
        ({String id, String name, int revision, List<RemoteItem> items})?
        manifest;
        try {
          manifest = await _readManifestFromSocket(
            s,
            fallbackId: '${addr.address}:$port',
            fallbackName: addr.address,
          );
        } on _ProtocolMismatchException catch (e) {
          return 'Version mismatch: local $_protocolMajor.x, peer ${e.remoteMajor ?? 'unknown'}.x';
        }
        if (manifest == null) return 'Bad response';
        if (!_isPeerTrusted(
          peerId: manifest.id,
          remoteAddress: addr.address,
          remotePort: port,
          countDiagnostics: false,
        )) {
          return 'Blocked by trust policy';
        }
        _applyManifestToPeer(addr: addr, port: port, manifest: manifest);
        return 'Connected: ${manifest.name} (${manifest.items.length} items)';
      } finally {
        await s.close();
      }
    } catch (e) {
      return 'Connect failed: $e';
    }
  }

  void removeLocal(String itemId) {
    final removed = _local.remove(itemId);
    if (removed == null) return;
    _pathToId.remove(removed.path);
    revision++;
    _broadcast();
    notifyListeners();
  }

  Future<DragItem?> buildDragItem(ShareItem s) async {
    final item = DragItem(localData: s.key, suggestedName: s.name);
    try {
      if (Platform.isWindows) {
        final dragPath = await _materializeWindowsDragPath(s);
        if (dragPath == null) return null;
        item.add(Formats.fileUri(Uri.file(dragPath, windows: true)));
        return item;
      }

      if (s.local) {
        final path = s.path;
        if (path == null || path.isEmpty) return null;
        item.add(Formats.fileUri(Uri.file(path, windows: Platform.isWindows)));
        return item;
      }

      if (!item.virtualFileSupported) return null;
      item.addVirtualFile(
        format: _fileFormat(s.name),
        provider: (sinkProvider, progress) {
          unawaited(_streamForDrag(s, sinkProvider, progress));
        },
      );
      return item;
    } catch (e, st) {
      _diagnostics.warn(
        'Failed to build drag item for ${s.name}',
        error: e,
        stack: st,
      );
      return null;
    }
  }

  Future<String?> _materializeWindowsDragPath(ShareItem s) async {
    if (s.local) {
      final path = s.path;
      if (path == null || path.isEmpty) return null;
      return path;
    }

    final key = '${s.ownerId}:${s.itemId}';
    final existingJob = _dragMaterializationInFlight[key];
    if (existingJob != null) {
      return existingJob;
    }

    final job = () async {
      final appDir = await _appDataDir();
      final dragDir = Directory(p.join(appDir.path, 'drag_cache'));
      await dragDir.create(recursive: true);
      final safeName = _safeFileName(s.name);
      final itemDir = Directory(
        p.join(dragDir.path, '${s.ownerId}_${s.itemId}'),
      );
      await itemDir.create(recursive: true);
      final targetPath = p.join(itemDir.path, safeName);
      final target = File(targetPath);
      if (await target.exists()) {
        final len = await target.length();
        if (len == s.size) {
          return target.path;
        }
      }
      _diagnostics.info('Materializing remote drag file: ${s.name}');
      await downloadRemoteToPath(s, target.path, allowOverwrite: true);
      return target.path;
    }();

    _dragMaterializationInFlight[key] = job;
    try {
      return await job;
    } catch (e, st) {
      _diagnostics.warn(
        'Failed to materialize remote drag file: ${s.name}',
        error: e,
        stack: st,
      );
      return null;
    } finally {
      _dragMaterializationInFlight.remove(key);
    }
  }

  Future<void> downloadRemoteToPath(
    ShareItem item,
    String outputPath, {
    bool allowOverwrite = false,
  }) async {
    if (item.local) {
      throw Exception('Item is already local');
    }
    final normalizedPath = p.normalize(outputPath.trim());
    if (normalizedPath.isEmpty || !p.isAbsolute(normalizedPath)) {
      throw Exception('Invalid output path');
    }
    final target = File(normalizedPath);
    await target.parent.create(recursive: true);
    if (!allowOverwrite && await target.exists()) {
      throw Exception('Target file already exists');
    }
    final temp = File('${target.path}.fileshare.part');
    if (await temp.exists()) {
      await temp.delete();
    }
    String? transferId;
    final sink = temp.openWrite(mode: FileMode.writeOnly);
    try {
      final completed = await _streamRemote(
        item,
        sink,
        () => false,
        onTransferStart: (id) => transferId = id,
      );
      await sink.flush();
      await sink.close();
      if (!completed) {
        if (await temp.exists()) {
          await temp.delete();
        }
        throw _TransferCanceledException();
      }
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
      if (transferId != null) {
        final entry = _transfers[transferId!];
        if (entry != null) {
          entry.outputPath = target.path;
          _notifyTransferListeners(force: true);
        }
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> refreshAll() async {
    final now = DateTime.now();
    final droppedUntrusted = _dropUntrustedPeers();
    if (droppedUntrusted) {
      notifyListeners();
    }
    for (final p in peers.values.toList(growable: false)) {
      if (!_isPeerTrusted(
        peerId: p.id,
        remoteAddress: p.addr.address,
        remotePort: p.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      if (p.fetching) continue;
      if (!p.canFetchAt(now)) continue;
      if (now.difference(p.lastFetch) < _minFetchInterval) continue;
      unawaited(_fetchManifest(p));
    }
    _evaluateDiscoveryProfile();
  }

  Future<void> runHealthCheck() async {
    final peersSnapshot = peers.values.toList(growable: false);
    for (final peer in peersSnapshot) {
      peerHealth[peer.id] =
          _isPeerTrusted(
            peerId: peer.id,
            remoteAddress: peer.addr.address,
            remotePort: peer.port,
            countDiagnostics: false,
          )
          ? 'Checking...'
          : 'Blocked by trust policy';
    }
    notifyListeners();

    for (final peer in peersSnapshot) {
      if (!_isPeerTrusted(
        peerId: peer.id,
        remoteAddress: peer.addr.address,
        remotePort: peer.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      final result = await _pingPeer(peer);
      peerHealth[peer.id] = result;
      notifyListeners();
    }
  }

  void clearFinishedTransfers() {
    final ids = _transfers.entries
        .where((e) => e.value.state != TransferState.running)
        .map((e) => e.key)
        .toList(growable: false);
    if (ids.isEmpty) return;
    for (final id in ids) {
      _transfers.remove(id);
      _transferDismissTimers.remove(id)?.cancel();
      _canceledTransfers.remove(id);
    }
    notifyListeners();
  }

  void cancelTransfer(String transferId) {
    final entry = _transfers[transferId];
    if (entry == null || entry.state != TransferState.running) return;
    _canceledTransfers.add(transferId);
    _finishTransfer(transferId, state: TransferState.canceled);
  }

  Future<void> openTransferLocation(String transferId) async {
    final entry = _transfers[transferId];
    final outputPath = entry?.outputPath;
    if (outputPath == null || outputPath.isEmpty) return;
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', outputPath]);
      return;
    }
    final file = File(outputPath);
    final dirPath = file.parent.path;
    if (Platform.isMacOS) {
      await Process.run('open', [dirPath]);
      return;
    }
    await Process.run('xdg-open', [dirPath]);
  }

  Future<bool> _addPath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      return _upsert(path, p.basename(path));
    }
    if (type == FileSystemEntityType.directory) {
      final root = p.basename(path);
      var changed = false;
      await for (final e in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        changed =
            await _upsert(
              e.path,
              p.join(root, p.relative(e.path, from: path)),
            ) ||
            changed;
      }
      return changed;
    }
    return false;
  }

  Future<bool> _upsert(String absPath, String rel) async {
    final norm = p.normalize(absPath);
    final f = File(norm);
    if (!await f.exists()) return false;
    final size = await f.length();
    final existing = _pathToId[norm];
    if (existing != null && _local[existing] != null) {
      _local[existing] = _local[existing]!.copyWith(
        name: p.basename(norm),
        rel: rel,
        size: size,
        iconBytes: _local[existing]!.iconBytes,
      );
      unawaited(_resolveAndApplyIcon(norm, existing));
      return true;
    }
    _counter++;
    final id = '$deviceId-${DateTime.now().microsecondsSinceEpoch}-$_counter';
    _local[id] = LocalItem(
      id: id,
      name: p.basename(norm),
      rel: rel,
      path: norm,
      size: size,
      iconBytes: null,
    );
    _pathToId[norm] = id;
    unawaited(_resolveAndApplyIcon(norm, id));
    return true;
  }

  Future<void> _resolveAndApplyIcon(String path, String itemId) async {
    try {
      final iconBytes = await _resolveIconBytes(path);
      if (iconBytes == null) return;
      final current = _local[itemId];
      if (current == null) return;
      if (current.path != path) return;
      final existing = current.iconBytes;
      if (existing != null &&
          existing.length == iconBytes.length &&
          _fastBytesFingerprint(existing) == _fastBytesFingerprint(iconBytes)) {
        return;
      }
      _local[itemId] = current.copyWith(iconBytes: iconBytes);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadIps() async {
    try {
      final n = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      localIps =
          n.expand((e) => e.addresses).map((e) => e.address).toSet().toList()
            ..sort();
    } catch (_) {
      localIps = [];
    }
  }

  void _broadcast() {
    for (final target in _broadcastTargets()) {
      _sendPresenceTo(target);
    }
    if (multicastEnabled) {
      _sendPresenceTo(InternetAddress(_discoveryMulticastGroup));
    }
    final sent = <String>{};
    for (final p in peers.values) {
      if (!_isPeerTrusted(
        peerId: p.id,
        remoteAddress: p.addr.address,
        remotePort: p.port,
        countDiagnostics: false,
      )) {
        continue;
      }
      final ip = p.addr.address;
      if (!sent.add(ip)) continue;
      _sendPresenceTo(p.addr);
    }
  }

  Iterable<InternetAddress> _broadcastTargets() sync* {
    final targets = <String>{'255.255.255.255'};
    for (final ip in localIps) {
      final parts = ip.split('.');
      if (parts.length != 4) continue;
      // Directed broadcast for common /24 LANs.
      targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
    }
    for (final target in targets) {
      yield InternetAddress(target);
    }
  }

  void _sendPresenceTo(InternetAddress addr) {
    final u = _udp;
    if (u == null) return;
    final payload = jsonEncode(
      _withAuth({
        'tag': _tag,
        'type': 'presence',
        'protocolMajor': _protocolMajor,
        'protocolMinor': _protocolMinor,
        'id': deviceId,
        'name': deviceName,
        'port': listenPort,
        'revision': revision,
      }),
    );
    if (_shouldSimulateDrop('udp_out_presence')) return;
    u.send(utf8.encode(payload), addr, _discoveryPort);
  }

  Future<void> _sendNudgeTcp(Peer peer, Map<String, dynamic> payload) async {
    try {
      if (_shouldSimulateDrop('tcp_out_nudge')) return;
      await _simulateLatency();
      final s = await Socket.connect(
        peer.addr,
        peer.port,
        timeout: const Duration(seconds: 2),
      );
      try {
        s.write(jsonEncode(payload));
        s.write('\n');
        await s.flush();
      } finally {
        await s.close();
      }
    } catch (_) {}
  }

  bool _applyNudgeFrom(String id) {
    if (id == deviceId) return false;
    final now = DateTime.now();
    final last = _lastNudgeFrom[id];
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 350)) {
      return false;
    }
    _lastNudgeFrom[id] = now;
    nudgeTick++;
    notifyListeners();
    return true;
  }

  void _onUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udp == null) return;
    Datagram? d;
    while ((d = _udp!.receive()) != null) {
      final g = d!;
      final remoteIp = g.address.address;
      if (g.data.length > _maxUdpDatagramBytes) {
        _incDiagnostic('udp_oversize_drop');
        continue;
      }
      if (_shouldSimulateDrop('udp_inbound')) {
        continue;
      }
      if (!_udpRateLimiter.allow(
        'udp:$remoteIp',
        maxEvents: 350,
        window: const Duration(seconds: 5),
      )) {
        _incDiagnostic('udp_rate_limited');
        continue;
      }
      try {
        final map = _decodeJsonMap(utf8.decode(g.data));
        if (map == null) {
          _incDiagnostic('udp_invalid_json');
          continue;
        }
        if (map['tag'] != _tag) continue;
        if (!_verifyAuth(map)) {
          _incDiagnostic('udp_auth_drop');
          continue;
        }
        final incomingMajor = _safeInt(
          map['protocolMajor'],
          min: 0,
          max: 0x7fffffff,
        );
        if (incomingMajor != _protocolMajor) {
          _incDiagnostic('udp_protocol_mismatch');
          final id = _safeString(map['id'], maxChars: _maxPeerIdChars);
          final name = _safeString(map['name'], maxChars: _maxPeerNameChars);
          final port = _safeInt(map['port'], min: 1, max: 65535);
          final key =
              id ?? '${name ?? g.address.address}:${port ?? _discoveryPort}';
          incompatiblePeers[key] =
              '${name ?? g.address.address} (${g.address.address}:${port ?? _discoveryPort}) '
              'uses protocol ${incomingMajor ?? 'unknown'}.x';
          continue;
        }
        final type = _safeString(map['type'], maxChars: 24);
        if (type == null) continue;
        final id = _safeString(map['id'], maxChars: _maxPeerIdChars);
        final port = _safeInt(map['port'], min: 1, max: 65535);
        if (!_isPeerTrusted(
          peerId: id,
          remoteAddress: g.address.address,
          remotePort: port,
        )) {
          continue;
        }
        if (type == 'nudge') {
          if (id != null) _applyNudgeFrom(id);
          continue;
        }
        if (type == 'probe') {
          if (id != null && id != deviceId) {
            _sendPresenceTo(g.address);
          }
        }
        final name = _safeString(map['name'], maxChars: _maxPeerNameChars);
        final rev = _safeInt(map['revision'], min: 0, max: 0x7fffffff) ?? 0;
        if (id == null || name == null || port == null || id == deviceId) {
          continue;
        }
        _clearIncompatiblePeerHints(
          peerId: id,
          address: g.address.address,
          port: port,
        );

        final now = DateTime.now();
        final existed = peers.containsKey(id);
        if (!existed && _latencyProfilingEnabled) {
          _peerFirstSeenAt.putIfAbsent(id, () => now);
        }
        final beforeCount = peers.length;
        final p = peers.putIfAbsent(
          id,
          () => Peer(
            id: id,
            name: name,
            addr: g.address,
            port: port,
            rev: rev,
            items: [],
            lastSeen: now,
            lastGoodContact: now,
          ),
        );
        _mergeDuplicatePeersFor(id);
        final dedupedPeers = peers.length != beforeCount;

        final nameChanged = p.name != name;
        final endpointChanged =
            p.addr.address != g.address.address || p.port != port;
        final revChanged = p.rev != rev;
        p
          ..name = name
          ..addr = g.address
          ..port = port
          ..rev = rev
          ..lastSeen = now
          ..lastGoodContact = now;

        if (revChanged ||
            now.difference(p.lastFetch) > const Duration(seconds: 3)) {
          unawaited(_fetchManifest(p, force: revChanged));
        }
        if (!existed ||
            nameChanged ||
            endpointChanged ||
            revChanged ||
            dedupedPeers) {
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  void _prunePeers() {
    final droppedUntrusted = _dropUntrustedPeers();
    final now = DateTime.now();
    final stale = peers.values
        .where((e) => now.difference(e.lastGoodContact) > _peerPruneAfter)
        .map((e) => e.id)
        .toList();
    if (stale.isEmpty) {
      if (droppedUntrusted) {
        _evaluateDiscoveryProfile(force: true);
        notifyListeners();
      }
      return;
    }
    for (final id in stale) {
      peers.remove(id);
      peerStatus.remove(id);
      peerHealth.remove(id);
    }
    _evaluateDiscoveryProfile(force: true);
    notifyListeners();
  }

  Future<void> _fetchManifest(Peer p0, {bool force = false}) async {
    if (p0.fetching) return;
    if (!_isPeerTrusted(
      peerId: p0.id,
      remoteAddress: p0.addr.address,
      remotePort: p0.port,
      countDiagnostics: false,
    )) {
      peerStatus[p0.id] = 'Blocked by trust policy';
      return;
    }
    if (!force && !p0.canFetchAt(DateTime.now())) return;
    p0.fetching = true;
    p0.lastFetch = DateTime.now();
    peerStatus[p0.id] = 'Fetching...';
    try {
      if (_shouldSimulateDrop('tcp_out_fetch_manifest')) {
        throw Exception('Simulated drop (tcp_out_fetch_manifest)');
      }
      await _simulateLatency();
      final s = await Socket.connect(
        p0.addr,
        p0.port,
        timeout: const Duration(seconds: 5),
      );
      try {
        await _sendManifestRequest(s);
        ({String id, String name, int revision, List<RemoteItem> items})?
        manifest;
        try {
          manifest = await _readManifestFromSocket(
            s,
            fallbackId: p0.id,
            fallbackName: p0.name,
          );
        } on _ProtocolMismatchException catch (e) {
          peerStatus[p0.id] =
              'Version mismatch: local $_protocolMajor.x, peer ${e.remoteMajor ?? 'unknown'}.x';
          notifyListeners();
          return;
        }
        if (manifest == null) return;
        p0.rev = manifest.revision;
        p0.name = manifest.name;
        final now = DateTime.now();
        p0.lastSeen = now;
        p0.lastGoodContact = now;
        p0.hasManifest = true;
        p0.recordFetchSuccess();
        if (_latencyProfilingEnabled &&
            !_peerFirstSyncLatency.containsKey(p0.id)) {
          final firstSeen = _peerFirstSeenAt[p0.id];
          if (firstSeen != null) {
            _peerFirstSyncLatency[p0.id] = now.difference(firstSeen);
          }
        }
        final changed = !_sameRemoteItems(p0.items, manifest.items);
        if (changed) {
          p0.items
            ..clear()
            ..addAll(manifest.items);
        }
        peerStatus[p0.id] = 'OK (${manifest.items.length} items)';
        if (changed) {
          notifyListeners();
        }
      } finally {
        await s.close();
      }
    } catch (e) {
      p0.recordFetchFailure();
      peerStatus[p0.id] = 'Fetch failed: $e';
      notifyListeners();
    } finally {
      p0.fetching = false;
    }
  }

  bool _sameRemoteItems(List<RemoteItem> a, List<RemoteItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.name != y.name ||
          x.rel != y.rel ||
          x.size != y.size ||
          x.iconFingerprint != y.iconFingerprint) {
        return false;
      }
    }
    return true;
  }

  Future<void> _sendManifestRequest(Socket s) async {
    s.write(
      jsonEncode(
        _withAuth({
          'type': 'manifest',
          'protocolMajor': _protocolMajor,
          'protocolMinor': _protocolMinor,
          'clientId': deviceId,
          'clientName': deviceName,
          'clientPort': listenPort,
          'clientRevision': revision,
        }),
      ),
    );
    s.write('\n');
    await s.flush();
  }

  void _learnPeerFromRequest(
    InternetAddress remoteAddress,
    Map<String, dynamic> req,
  ) {
    final id = _safeString(req['clientId'], maxChars: _maxPeerIdChars);
    final name = _safeString(req['clientName'], maxChars: _maxPeerNameChars);
    final port = _safeInt(req['clientPort'], min: 1, max: 65535);
    final rev = _safeInt(req['clientRevision'], min: 0, max: 0x7fffffff) ?? 0;
    if (id == null || name == null || port == null || id == deviceId) {
      return;
    }
    if (!_isPeerTrusted(
      peerId: id,
      remoteAddress: remoteAddress.address,
      remotePort: port,
    )) {
      return;
    }
    _clearIncompatiblePeerHints(
      peerId: id,
      address: remoteAddress.address,
      port: port,
    );
    final now = DateTime.now();
    final p = peers.putIfAbsent(
      id,
      () => Peer(
        id: id,
        name: name,
        addr: remoteAddress,
        port: port,
        rev: rev,
        items: [],
        lastSeen: now,
        lastGoodContact: now,
      ),
    );
    _mergeDuplicatePeersFor(id);
    p
      ..name = name
      ..addr = remoteAddress
      ..port = port
      ..rev = rev
      ..lastSeen = now
      ..lastGoodContact = now;
  }

  void _mergeDuplicatePeersFor(String canonicalId) {
    final canonical = peers[canonicalId];
    if (canonical == null) return;
    final duplicates = <String>[];
    for (final entry in peers.entries) {
      if (entry.key == canonicalId) continue;
      if (entry.value.addr.address == canonical.addr.address &&
          entry.value.port == canonical.port) {
        duplicates.add(entry.key);
      }
    }
    if (duplicates.isEmpty) return;
    for (final duplicateId in duplicates) {
      final duplicate = peers.remove(duplicateId);
      if (duplicate != null &&
          canonical.items.isEmpty &&
          duplicate.items.isNotEmpty) {
        canonical.items = duplicate.items;
      }
      final status = peerStatus.remove(duplicateId);
      if (status != null &&
          (peerStatus[canonicalId] == null ||
              peerStatus[canonicalId]!.isEmpty)) {
        peerStatus[canonicalId] = status;
      }
      final health = peerHealth.remove(duplicateId);
      if (health != null &&
          (peerHealth[canonicalId] == null ||
              peerHealth[canonicalId]!.isEmpty)) {
        peerHealth[canonicalId] = health;
      }
    }
  }

  String _beginTransfer({
    required String name,
    required String peerName,
    required TransferDirection direction,
    required int totalBytes,
  }) {
    _transferCounter++;
    final id = '${DateTime.now().microsecondsSinceEpoch}-$_transferCounter';
    _canceledTransfers.remove(id);
    _transfers[id] = TransferEntry(
      id: id,
      name: name,
      peerName: peerName,
      direction: direction,
      totalBytes: totalBytes,
      startedAt: DateTime.now(),
    );
    _notifyTransferListeners(force: true);
    return id;
  }

  void _addTransferProgress(String id, int bytes) {
    final entry = _transfers[id];
    if (entry == null || bytes <= 0) return;
    entry.addBytes(bytes);
    _notifyTransferListeners();
  }

  void _finishTransfer(
    String id, {
    required TransferState state,
    String? error,
  }) {
    final entry = _transfers[id];
    if (entry == null) return;
    if (entry.state != TransferState.running) return;
    entry.complete(state: state, error: error);
    if (state != TransferState.canceled) {
      _canceledTransfers.remove(id);
    }
    _scheduleTransferAutoDismiss(id);
    _trimTransferHistory();
    _notifyTransferListeners(force: true);
  }

  void _scheduleTransferAutoDismiss(String id) {
    _transferDismissTimers.remove(id)?.cancel();
    _transferDismissTimers[id] = Timer(const Duration(seconds: 5), () {
      final entry = _transfers[id];
      if (entry == null || entry.state == TransferState.running) {
        _transferDismissTimers.remove(id);
        return;
      }
      _transfers.remove(id);
      _transferDismissTimers.remove(id);
      _canceledTransfers.remove(id);
      _notifyTransferListeners(force: true);
    });
  }

  void _notifyTransferListeners({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastTransferNotify) <
            const Duration(milliseconds: 180)) {
      return;
    }
    _lastTransferNotify = now;
    notifyListeners();
  }

  void _trimTransferHistory() {
    const maxTransfers = 30;
    if (_transfers.length <= maxTransfers) return;
    final finished =
        _transfers.values
            .where((e) => e.state != TransferState.running)
            .toList(growable: false)
          ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final removeCount = _transfers.length - maxTransfers;
    for (var i = 0; i < min(removeCount, finished.length); i++) {
      final id = finished[i].id;
      _transfers.remove(id);
      _transferDismissTimers.remove(id)?.cancel();
      _canceledTransfers.remove(id);
    }
  }

  Future<String> _pingPeer(Peer p0) async {
    if (!_isPeerTrusted(
      peerId: p0.id,
      remoteAddress: p0.addr.address,
      remotePort: p0.port,
      countDiagnostics: false,
    )) {
      return 'Blocked by trust policy';
    }
    try {
      if (_shouldSimulateDrop('tcp_out_ping')) {
        return 'Simulated drop (tcp_out_ping)';
      }
      await _simulateLatency();
      final s = await Socket.connect(
        p0.addr,
        p0.port,
        timeout: const Duration(seconds: 3),
      );
      try {
        await _sendManifestRequest(s);
        final line = await _readLine(s).timeout(const Duration(seconds: 4));
        final m = _decodeJsonMap(line);
        if (m == null || m['type'] != 'manifest') {
          return 'Bad response';
        }
        final incomingMajor = _safeInt(
          m['protocolMajor'],
          min: 0,
          max: 0x7fffffff,
        );
        if (incomingMajor != _protocolMajor) {
          return 'Version mismatch: ${incomingMajor ?? 'unknown'}.x';
        }
        final count =
            ((m['items'] as List<dynamic>? ?? const <dynamic>[]).length).clamp(
              0,
              _maxManifestItems,
            );
        return 'OK ($count items)';
      } finally {
        await s.close();
      }
    } catch (e) {
      return 'Failed: $e';
    }
  }

  Future<void> _onClient(Socket s) async {
    final remoteIp = s.remoteAddress.address;
    if (_shouldSimulateDrop('tcp_inbound_accept')) {
      await s.close();
      return;
    }
    if (!_tcpRateLimiter.allow(
      'tcp-conn:$remoteIp',
      maxEvents: 120,
      window: const Duration(seconds: 10),
    )) {
      _incDiagnostic('tcp_conn_rate_limited');
      await s.close();
      return;
    }
    if (_activeInboundClients >= _maxConcurrentInboundClients) {
      _incDiagnostic('tcp_conn_limit_drop');
      await s.close();
      return;
    }
    _activeInboundClients++;
    try {
      await _simulateLatency();
      final line = await _readLine(s).timeout(const Duration(seconds: 5));
      final req = _decodeJsonMap(line);
      if (req == null) {
        _incDiagnostic('tcp_invalid_json');
        return;
      }
      if (!_verifyAuth(req)) {
        _incDiagnostic('tcp_auth_drop');
        return;
      }
      final incomingMajor = _safeInt(
        req['protocolMajor'],
        min: 0,
        max: 0x7fffffff,
      );
      if (incomingMajor != _protocolMajor) {
        _incDiagnostic('tcp_protocol_mismatch');
        s.write(
          jsonEncode({
            'type': 'error',
            'message':
                'Protocol mismatch. Local $_protocolMajor.x, peer ${incomingMajor ?? 'unknown'}.x',
          }),
        );
        s.write('\n');
        await s.flush();
        return;
      }
      final trustPeerId =
          _safeString(req['clientId'], maxChars: _maxPeerIdChars) ??
          _safeString(req['id'], maxChars: _maxPeerIdChars);
      final trustPort =
          _safeInt(req['clientPort'], min: 1, max: 65535) ??
          _safeInt(req['port'], min: 1, max: 65535);
      if (!_isPeerTrusted(
        peerId: trustPeerId,
        remoteAddress: remoteIp,
        remotePort: trustPort,
      )) {
        s.write(
          jsonEncode(
            _withAuth({
              'type': 'error',
              'message': 'Peer blocked by trust policy',
            }),
          ),
        );
        s.write('\n');
        await s.flush();
        return;
      }
      _learnPeerFromRequest(s.remoteAddress, req);
      final type = _safeString(req['type'], maxChars: 24);
      if (type == null) return;
      if (!_tcpRateLimiter.allow(
        'tcp-req:$remoteIp:$type',
        maxEvents: 200,
        window: const Duration(seconds: 10),
      )) {
        _incDiagnostic('tcp_req_rate_limited');
        return;
      }
      if (type == 'nudge') {
        final id =
            _safeString(req['id'], maxChars: _maxPeerIdChars) ??
            _safeString(req['clientId'], maxChars: _maxPeerIdChars);
        if (id != null) {
          _applyNudgeFrom(id);
        }
        s.write(jsonEncode({'type': 'ok'}));
        s.write('\n');
        await s.flush();
        return;
      }
      if (type == 'manifest') {
        final manifestItems = _local.values
            .take(_maxManifestItems)
            .map((e) {
              final iconBytes = e.iconBytes;
              return {
                'id': e.id,
                'name': e.name,
                'relativePath': e.rel,
                'size': e.size,
                'iconPngBase64':
                    (iconBytes == null || iconBytes.length > _maxIconBytes)
                    ? null
                    : base64Encode(iconBytes),
              };
            })
            .toList(growable: false);
        s.write(
          jsonEncode(
            _withAuth({
              'type': 'manifest',
              'protocolMajor': _protocolMajor,
              'protocolMinor': _protocolMinor,
              'id': deviceId,
              'name': deviceName,
              'revision': revision,
              'items': manifestItems,
            }),
          ),
        );
        s.write('\n');
        await s.flush();
        return;
      }
      if (type == 'download') {
        final id = _safeString(req['id'], maxChars: 256);
        if (id == null) return;
        final peerKey =
            _safeString(req['clientId'], maxChars: _maxPeerIdChars) ?? remoteIp;
        if (!_acquirePeerSlot(
          _activePeerUploads,
          peerKey,
          _maxConcurrentTransfersPerPeer,
        )) {
          _incDiagnostic('upload_peer_slot_reject');
          s.write(
            jsonEncode(
              _withAuth({
                'type': 'error',
                'message': 'Too many concurrent uploads for this peer',
              }),
            ),
          );
          s.write('\n');
          await s.flush();
          return;
        }
        final item = _local[id];
        if (item == null) {
          s.write(
            jsonEncode(
              _withAuth({'type': 'error', 'message': 'File not found'}),
            ),
          );
          s.write('\n');
          await s.flush();
          return;
        }
        final file = File(item.path);
        if (!await file.exists()) {
          s.write(
            jsonEncode(
              _withAuth({'type': 'error', 'message': 'Source file missing'}),
            ),
          );
          s.write('\n');
          await s.flush();
          return;
        }
        s.write(
          jsonEncode(
            _withAuth({
              'type': 'file',
              'name': item.name,
              'relativePath': item.rel,
              'size': item.size,
            }),
          ),
        );
        s.write('\n');
        await s.flush();
        final peerName =
            (req['clientName'] as String?) ?? s.remoteAddress.address;
        final transferId = _beginTransfer(
          name: item.rel,
          peerName: peerName,
          direction: TransferDirection.upload,
          totalBytes: item.size,
        );
        try {
          await for (final chunk in file.openRead()) {
            await _uploadRateLimiter.consume(
              peerKey,
              chunk.length,
              _perPeerUploadRateLimitBytesPerSecond,
            );
            s.add(chunk);
            _addTransferProgress(transferId, chunk.length);
          }
          await s.flush();
          _finishTransfer(transferId, state: TransferState.completed);
        } catch (e) {
          _finishTransfer(
            transferId,
            state: TransferState.failed,
            error: e.toString(),
          );
          rethrow;
        } finally {
          _releasePeerSlot(_activePeerUploads, peerKey);
        }
      }
    } catch (_) {
    } finally {
      _activeInboundClients = max(0, _activeInboundClients - 1);
      await s.close();
    }
  }

  Future<void> _streamForDrag(
    ShareItem it,
    clip.VirtualFileEventSinkProvider sinkProvider,
    clip.WriteProgress progress,
  ) async {
    var canceled = false;
    void onCancel() => canceled = true;
    progress.onCancel.addListener(onCancel);
    final sink = sinkProvider(fileSize: it.size);
    try {
      if (it.local) {
        final path = it.path;
        if (path == null) throw Exception('Missing local path');
        await for (final chunk in File(path).openRead()) {
          if (canceled) break;
          sink.add(chunk);
        }
      } else {
        await _streamRemote(it, sink, () => canceled);
      }
    } catch (e, st) {
      _diagnostics.warn(
        'Virtual drag stream failed for ${it.name}',
        error: e,
        stack: st,
      );
    } finally {
      progress.onCancel.removeListener(onCancel);
      try {
        sink.close();
      } catch (e, st) {
        _diagnostics.warn(
          'Virtual drag sink close failed for ${it.name}',
          error: e,
          stack: st,
        );
      }
    }
  }

  Future<bool> _streamRemote(
    ShareItem it,
    EventSink sink,
    bool Function() canceled, {
    void Function(String transferId)? onTransferStart,
  }) async {
    final peer = peers[it.peerId];
    if (peer == null) throw Exception('Peer not found');
    if (!_isPeerTrusted(
      peerId: peer.id,
      remoteAddress: peer.addr.address,
      remotePort: peer.port,
      countDiagnostics: false,
    )) {
      throw Exception('Peer blocked by trust policy');
    }
    if (_shouldSimulateDrop('tcp_out_download')) {
      throw Exception('Simulated drop (tcp_out_download)');
    }
    await _simulateLatency();
    final s = await Socket.connect(
      peer.addr,
      peer.port,
      timeout: const Duration(seconds: 5),
    );
    try {
      s.write(
        jsonEncode(
          _withAuth({
            'type': 'download',
            'protocolMajor': _protocolMajor,
            'protocolMinor': _protocolMinor,
            'clientId': deviceId,
            'clientName': deviceName,
            'clientPort': listenPort,
            'id': it.itemId,
          }),
        ),
      );
      s.write('\n');
      await s.flush();
      final h = await _readHeader(s);
      final m = jsonDecode(h.line) as Map<String, dynamic>;
      if (!_verifyAuth(m)) throw Exception('Peer authentication failed');
      if (m['type'] == 'error') throw Exception('Peer rejected transfer');
      if (m['type'] != 'file') throw Exception('Bad response');
      final totalBytes = (m['size'] as num).toInt();
      final transferId = _beginTransfer(
        name: (m['relativePath'] as String?) ?? it.rel,
        peerName: peer.name,
        direction: TransferDirection.download,
        totalBytes: totalBytes,
      );
      onTransferStart?.call(transferId);
      if (!_acquirePeerSlot(
        _activePeerDownloads,
        peer.id,
        _maxConcurrentTransfersPerPeer,
      )) {
        _incDiagnostic('download_peer_slot_reject');
        _finishTransfer(
          transferId,
          state: TransferState.failed,
          error: 'Too many concurrent downloads for this peer',
        );
        throw Exception('Too many concurrent downloads for this peer');
      }
      try {
        var left = totalBytes;
        if (h.rem.isNotEmpty) {
          final n = min(left, h.rem.length);
          if (n > 0 &&
              !canceled() &&
              !_canceledTransfers.contains(transferId)) {
            await _downloadRateLimiter.consume(
              peer.id,
              n,
              _perPeerDownloadRateLimitBytesPerSecond,
            );
            sink.add(h.rem.sublist(0, n));
            _addTransferProgress(transferId, n);
          }
          left -= n;
        }
        while (left > 0 &&
            !canceled() &&
            !_canceledTransfers.contains(transferId) &&
            await h.it.moveNext()) {
          final chunk = h.it.current;
          final n = min(left, chunk.length);
          if (n > 0) {
            await _downloadRateLimiter.consume(
              peer.id,
              n,
              _perPeerDownloadRateLimitBytesPerSecond,
            );
            sink.add(chunk.sublist(0, n));
            _addTransferProgress(transferId, n);
          }
          left -= n;
        }
        if (canceled() || _canceledTransfers.contains(transferId)) {
          _finishTransfer(transferId, state: TransferState.canceled);
          return false;
        }
        if (left > 0) {
          _finishTransfer(
            transferId,
            state: TransferState.failed,
            error: 'Transfer interrupted',
          );
          throw Exception('Transfer interrupted');
        }
        _finishTransfer(transferId, state: TransferState.completed);
        return true;
      } catch (e) {
        if (_canceledTransfers.contains(transferId)) {
          _finishTransfer(transferId, state: TransferState.canceled);
          return false;
        }
        _finishTransfer(
          transferId,
          state: TransferState.failed,
          error: e.toString(),
        );
        rethrow;
      } finally {
        _releasePeerSlot(_activePeerDownloads, peer.id);
      }
    } finally {
      await s.close();
    }
  }

  clip.FileFormat _fileFormat(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.txt':
      case '.log':
      case '.md':
        return Formats.plainTextFile;
      case '.html':
      case '.htm':
        return Formats.htmlFile;
      case '.jpg':
      case '.jpeg':
        return Formats.jpeg;
      case '.png':
        return Formats.png;
      case '.gif':
        return Formats.gif;
      case '.webp':
        return Formats.webp;
      case '.svg':
        return Formats.svg;
      case '.bmp':
        return Formats.bmp;
      case '.ico':
        return Formats.ico;
      case '.mp4':
        return Formats.mp4;
      case '.mov':
        return Formats.mov;
      case '.avi':
        return Formats.avi;
      case '.mkv':
        return Formats.mkv;
      case '.mp3':
        return Formats.mp3;
      case '.wav':
        return Formats.wav;
      case '.pdf':
        return Formats.pdf;
      case '.doc':
        return Formats.doc;
      case '.docx':
        return Formats.docx;
      case '.xls':
        return Formats.xls;
      case '.xlsx':
        return Formats.xlsx;
      case '.ppt':
        return Formats.ppt;
      case '.pptx':
        return Formats.pptx;
      case '.csv':
        return Formats.csv;
      case '.json':
        return Formats.json;
      case '.zip':
        return Formats.zip;
      case '.rar':
        return Formats.rar;
      case '.7z':
        return Formats.sevenZip;
      case '.exe':
        return Formats.exe;
      case '.msi':
        return Formats.msi;
      case '.dll':
        return Formats.dll;
      default:
        return const clip.SimpleFileFormat(
          mimeTypes: ['application/octet-stream'],
        );
    }
  }

  Future<String> _readLine(Socket s) async {
    final it = StreamIterator<Uint8List>(s);
    final b = BytesBuilder(copy: false);
    while (await it.moveNext()) {
      final c = it.current;
      final i = c.indexOf(10);
      if (i >= 0) {
        if (i > 0) b.add(c.sublist(0, i));
        return utf8.decode(b.takeBytes()).trim();
      }
      b.add(c);
      if (b.length > _maxHeaderBytes) throw Exception('Header too large');
    }
    throw Exception('No newline');
  }

  Future<({String id, String name, int revision, List<RemoteItem> items})?>
  _readManifestFromSocket(
    Socket s, {
    required String fallbackId,
    required String fallbackName,
  }) async {
    final line = await _readLine(s).timeout(const Duration(seconds: 5));
    final m = _decodeJsonMap(line);
    if (m == null) return null;
    return _parseManifestMap(
      m,
      fallbackId: fallbackId,
      fallbackName: fallbackName,
    );
  }

  ({String id, String name, int revision, List<RemoteItem> items})?
  _parseManifestMap(
    Map<String, dynamic> m, {
    required String fallbackId,
    required String fallbackName,
  }) {
    if (m['type'] != 'manifest') return null;
    if (!_verifyAuth(m)) return null;
    final incomingMajor = _safeInt(m['protocolMajor'], min: 0, max: 0x7fffffff);
    if (incomingMajor != _protocolMajor) {
      throw _ProtocolMismatchException(incomingMajor);
    }
    final id = _safeString(m['id'], maxChars: _maxPeerIdChars) ?? fallbackId;
    final name =
        _safeString(m['name'], maxChars: _maxPeerNameChars) ?? fallbackName;
    final revision = _safeInt(m['revision'], min: 0, max: 0x7fffffff) ?? 0;
    final rawItems = m['items'];
    if (rawItems is! List) {
      return (id: id, name: name, revision: revision, items: <RemoteItem>[]);
    }
    final items = <RemoteItem>[];
    for (final raw in rawItems.take(_maxManifestItems)) {
      if (raw is! Map) continue;
      final map = <String, dynamic>{};
      for (final entry in raw.entries) {
        if (entry.key is String) {
          map[entry.key as String] = entry.value;
        }
      }
      final itemId = _safeString(map['id'], maxChars: 256);
      final itemName = _safeString(map['name'], maxChars: _maxItemNameChars);
      final relativePath = _safeString(
        map['relativePath'],
        maxChars: _maxRelativePathChars,
      );
      final size = _safeInt(map['size'], min: 0, max: 0x7fffffff);
      if (itemId == null ||
          itemName == null ||
          relativePath == null ||
          size == null) {
        continue;
      }
      if (!_isValidRemoteFileName(itemName) ||
          !_isValidRelativePath(relativePath)) {
        _incDiagnostic('manifest_item_rejected');
        continue;
      }
      Uint8List? iconBytes;
      final iconBase64 = map['iconPngBase64'];
      if (iconBase64 is String && iconBase64.length <= _maxIconBase64Chars) {
        try {
          final decoded = base64Decode(iconBase64);
          if (decoded.length <= _maxIconBytes) {
            iconBytes = decoded;
          }
        } catch (_) {}
      }
      items.add(
        RemoteItem(
          id: itemId,
          name: itemName,
          rel: relativePath,
          size: size,
          iconBytes: iconBytes,
          iconFingerprint: iconBytes == null
              ? null
              : _fastBytesFingerprint(iconBytes),
        ),
      );
    }
    return (id: id, name: name, revision: revision, items: items);
  }

  Map<String, dynamic>? _decodeJsonMap(String input) {
    try {
      final data = jsonDecode(input);
      if (data is Map<String, dynamic>) return data;
      if (data is Map) {
        final out = <String, dynamic>{};
        for (final entry in data.entries) {
          if (entry.key is String) {
            out[entry.key as String] = entry.value;
          }
        }
        return out;
      }
    } catch (_) {}
    return null;
  }

  List<dynamic>? _decodeJsonList(String input) {
    try {
      final data = jsonDecode(input);
      if (data is List<dynamic>) return data;
      if (data is List) return data.toList(growable: false);
    } catch (_) {}
    return null;
  }

  String? _safeString(Object? value, {required int maxChars}) {
    if (value is! String) return null;
    final s = value.trim();
    if (s.isEmpty || s.length > maxChars) return null;
    return s;
  }

  int? _safeInt(Object? value, {required int min, required int max}) {
    if (value is! num) return null;
    final v = value.toInt();
    if (v < min || v > max) return null;
    return v;
  }

  Map<String, dynamic> _withAuth(Map<String, dynamic> payload) {
    if (_sharedRoomKey.isEmpty) return payload;
    final signed = Map<String, dynamic>.from(payload);
    signed['auth'] = _computeAuthSignature(signed);
    return signed;
  }

  bool _verifyAuth(Map<String, dynamic> payload) {
    if (_sharedRoomKey.isEmpty) return true;
    final auth = payload['auth'];
    if (auth is! String || auth.isEmpty) return false;
    final expected = _computeAuthSignature(payload);
    return _constantTimeEquals(auth, expected);
  }

  String _computeAuthSignature(Map<String, dynamic> payload) {
    final normalized = _normalizeForAuth(payload);
    final digest = crypto.Hmac(
      crypto.sha256,
      utf8.encode(_sharedRoomKey),
    ).convert(utf8.encode(jsonEncode(normalized)));
    return digest.toString();
  }

  dynamic _normalizeForAuth(dynamic value) {
    if (value is Map) {
      final out = SplayTreeMap<String, dynamic>();
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) continue;
        if (key == 'auth') continue;
        out[key] = _normalizeForAuth(entry.value);
      }
      return out;
    }
    if (value is List) {
      return value.map(_normalizeForAuth).toList(growable: false);
    }
    if (value is num || value is String || value is bool || value == null) {
      return value;
    }
    return value.toString();
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }

  int _fastBytesFingerprint(Uint8List bytes) {
    return nv.fastBytesFingerprint(bytes);
  }

  void _clearIncompatiblePeerHints({
    required String peerId,
    required String address,
    required int port,
  }) {
    incompatiblePeers.remove(peerId);
    final endpoint = '$address:$port';
    final removeKeys = incompatiblePeers.entries
        .where((e) => e.key.contains(endpoint) || e.value.contains(endpoint))
        .map((e) => e.key)
        .toList(growable: false);
    for (final key in removeKeys) {
      incompatiblePeers.remove(key);
    }
  }

  Future<_Header> _readHeader(Socket s) async {
    final it = StreamIterator<Uint8List>(s);
    final b = BytesBuilder(copy: false);
    while (await it.moveNext()) {
      final c = it.current;
      final i = c.indexOf(10);
      if (i >= 0) {
        if (i > 0) b.add(c.sublist(0, i));
        final rem = i + 1 < c.length
            ? Uint8List.fromList(c.sublist(i + 1))
            : Uint8List(0);
        return _Header(
          line: utf8.decode(b.takeBytes()).trim(),
          it: it,
          rem: rem,
        );
      }
      b.add(c);
      if (b.length > _maxHeaderBytes) throw Exception('Header too large');
    }
    throw Exception('No header');
  }

  Future<Uint8List?> _resolveIconBytes(String path) async {
    if (!Platform.isWindows) {
      return null;
    }
    final key = p.normalize(path).toLowerCase();
    final cached = _iconCache[key];
    if (cached != null) {
      return cached;
    }
    final bytes = await _extractWindowsIconPng(path);
    if (bytes != null) {
      _iconCache[key] = bytes;
    }
    return bytes;
  }
}

Future<Uint8List?> _extractWindowsIconPng(String path) async {
  if (!Platform.isWindows) {
    return null;
  }

  final pathPtr = path.toNativeUtf16();
  final info = calloc<win32.SHFILEINFO>();
  const flags = win32.SHGFI_ICON | win32.SHGFI_LARGEICON;

  final result = win32.SHGetFileInfo(
    pathPtr,
    0,
    info,
    ffi.sizeOf<win32.SHFILEINFO>(),
    flags,
  );
  calloc.free(pathPtr);

  if (result == 0 || info.ref.hIcon == 0) {
    calloc.free(info);
    return null;
  }

  final hIcon = info.ref.hIcon;
  calloc.free(info);

  final iconInfo = calloc<win32.ICONINFO>();
  if (win32.GetIconInfo(hIcon, iconInfo) == 0) {
    win32.DestroyIcon(hIcon);
    calloc.free(iconInfo);
    return null;
  }

  final hBitmap = iconInfo.ref.hbmColor;
  final bmp = calloc<win32.BITMAP>();
  win32.GetObject(hBitmap, ffi.sizeOf<win32.BITMAP>(), bmp.cast());

  final width = bmp.ref.bmWidth;
  final height = bmp.ref.bmHeight;

  final bmi = calloc<win32.BITMAPINFO>();
  bmi.ref.bmiHeader.biSize = ffi.sizeOf<win32.BITMAPINFOHEADER>();
  bmi.ref.bmiHeader.biWidth = width;
  bmi.ref.bmiHeader.biHeight = -height;
  bmi.ref.bmiHeader.biPlanes = 1;
  bmi.ref.bmiHeader.biBitCount = 32;
  bmi.ref.bmiHeader.biCompression = win32.BI_RGB;

  final hdc = win32.GetDC(0);
  final bufferSize = width * height * 4;
  final pixelBuffer = calloc<ffi.Uint8>(bufferSize);

  final scanLines = win32.GetDIBits(
    hdc,
    hBitmap,
    0,
    height,
    pixelBuffer.cast(),
    bmi,
    win32.DIB_RGB_COLORS,
  );

  win32.ReleaseDC(0, hdc);
  win32.DeleteObject(iconInfo.ref.hbmColor);
  win32.DeleteObject(iconInfo.ref.hbmMask);
  win32.DestroyIcon(hIcon);
  calloc.free(iconInfo);
  calloc.free(bmp);
  calloc.free(bmi);

  if (scanLines == 0) {
    calloc.free(pixelBuffer);
    return null;
  }

  final bytes = Uint8List.fromList(pixelBuffer.asTypedList(bufferSize));
  final completer = Completer<Uint8List?>();

  ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.bgra8888, (
    image,
  ) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    completer.complete(data?.buffer.asUint8List());
  });

  final pngBytes = await completer.future;
  calloc.free(pixelBuffer);
  return pngBytes;
}

class _WindowState {
  _WindowState({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.maximized,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final bool maximized;

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'maximized': maximized,
  };

  static _WindowState? fromJson(Map<String, dynamic> json) {
    final left = (json['left'] as num?)?.toDouble();
    final top = (json['top'] as num?)?.toDouble();
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();
    final maximized = json['maximized'] == true;
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) {
      return null;
    }
    return _WindowState(
      left: left,
      top: top,
      width: width,
      height: height,
      maximized: maximized,
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.darkMode,
    required this.themeIndex,
    required this.soundOnNudge,
    this.minimizeToTray = false,
    this.startWithWindows = false,
    this.startInTrayOnLaunch = false,
    this.sharedRoomKey = '',
    this.peerAllowlist = '',
    this.peerBlocklist = '',
    this.autoUpdateChecks = false,
    this.updateChannel = UpdateChannel.stable,
  });

  final bool darkMode;
  final int themeIndex;
  final bool soundOnNudge;
  final bool minimizeToTray;
  final bool startWithWindows;
  final bool startInTrayOnLaunch;
  final String sharedRoomKey;
  final String peerAllowlist;
  final String peerBlocklist;
  final bool autoUpdateChecks;
  final UpdateChannel updateChannel;

  Map<String, dynamic> toJson() => {
    'darkMode': darkMode,
    'themeIndex': themeIndex,
    'soundOnNudge': soundOnNudge,
    'minimizeToTray': minimizeToTray,
    'startWithWindows': startWithWindows,
    'startInTrayOnLaunch': startInTrayOnLaunch,
    'sharedRoomKey': sharedRoomKey,
    'peerAllowlist': peerAllowlist,
    'peerBlocklist': peerBlocklist,
    'autoUpdateChecks': autoUpdateChecks,
    'updateChannel': updateChannelToString(updateChannel),
  };

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      darkMode: json['darkMode'] == true,
      themeIndex: (json['themeIndex'] as num?)?.toInt() ?? 0,
      soundOnNudge: json['soundOnNudge'] == true,
      minimizeToTray: json['minimizeToTray'] == true,
      startWithWindows: json['startWithWindows'] == true,
      startInTrayOnLaunch: json['startInTrayOnLaunch'] == true,
      sharedRoomKey: (json['sharedRoomKey'] as String? ?? '').trim(),
      peerAllowlist: (json['peerAllowlist'] as String? ?? ''),
      peerBlocklist: (json['peerBlocklist'] as String? ?? ''),
      autoUpdateChecks: json['autoUpdateChecks'] == true,
      updateChannel: updateChannelFromString(json['updateChannel'] as String?),
    );
  }
}

String _peerStateLabel(PeerState state) {
  switch (state) {
    case PeerState.discovered:
      return 'Discovered';
    case PeerState.syncing:
      return 'Syncing';
    case PeerState.reachable:
      return 'Reachable';
    case PeerState.stale:
      return 'Stale';
  }
}

String _peerAvailabilityLabel(PeerAvailability availability) {
  switch (availability) {
    case PeerAvailability.active:
      return 'Active';
    case PeerAvailability.away:
      return 'Away';
    case PeerAvailability.idle:
      return 'Idle';
  }
}

Future<File> _windowStateFile() async {
  final dir = await _appDataDir();
  return File(p.join(dir.path, 'window_state.json'));
}

Future<File> _appSettingsFile() async {
  final dir = await _appDataDir();
  return File(p.join(dir.path, 'settings.json'));
}

Future<File> _favoritesFile() async {
  final dir = await _appDataDir();
  return File(p.join(dir.path, 'favorites.json'));
}

Future<File> _itemNotesFile() async {
  final dir = await _appDataDir();
  return File(p.join(dir.path, 'item_notes.json'));
}

Future<Set<String>> _loadFavoriteKeys() async {
  try {
    final file = await _favoritesFile();
    if (!await file.exists()) return <String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) return <String>{};
    final out = <String>{};
    for (final raw in decoded) {
      if (raw is! String) continue;
      final key = raw.trim();
      if (key.isNotEmpty && key.length <= 512) {
        out.add(key);
      }
    }
    return out;
  } catch (_) {
    return <String>{};
  }
}

Future<void> _saveFavoriteKeys(Set<String> keys) async {
  try {
    final file = await _favoritesFile();
    final sorted = keys.toList()..sort();
    await file.writeAsString(jsonEncode(sorted), flush: true);
  } catch (_) {}
}

Future<Map<String, String>> _loadItemNotes() async {
  try {
    final file = await _itemNotesFile();
    if (!await file.exists()) return <String, String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return <String, String>{};
    final out = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String) continue;
      if (key.isEmpty || key.length > 512) continue;
      if (entry.value is! String) continue;
      final note = normalizeItemNote(entry.value as String);
      if (note.isEmpty) continue;
      out[key] = note;
    }
    return out;
  } catch (_) {
    return <String, String>{};
  }
}

Future<void> _saveItemNotes(Map<String, String> notes) async {
  try {
    final file = await _itemNotesFile();
    final keys = notes.keys.toList()..sort();
    final out = <String, String>{};
    for (final key in keys) {
      final normalized = normalizeItemNote(notes[key] ?? '');
      if (normalized.isEmpty) continue;
      out[key] = normalized;
    }
    await file.writeAsString(jsonEncode(out), flush: true);
  } catch (_) {}
}

Future<Directory> _appDataDir() async {
  String? baseDir;
  if (Platform.isWindows) {
    baseDir = Platform.environment['APPDATA'];
  } else {
    baseDir =
        Platform.environment['XDG_CONFIG_HOME'] ?? Platform.environment['HOME'];
  }
  final root = (baseDir == null || baseDir.isEmpty)
      ? Directory.systemTemp.path
      : baseDir;
  final dir = Directory(p.join(root, 'FileShare'));
  await dir.create(recursive: true);
  return dir;
}

Future<_WindowState?> _loadWindowState() async {
  try {
    final file = await _windowStateFile();
    if (!await file.exists()) {
      return null;
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic>) {
      return null;
    }
    return _WindowState.fromJson(data);
  } catch (_) {
    return null;
  }
}

Future<void> _saveWindowState(_WindowState state) async {
  try {
    final file = await _windowStateFile();
    await file.writeAsString(jsonEncode(state.toJson()), flush: true);
  } catch (_) {}
}

Future<AppSettings> _loadAppSettings() async {
  try {
    final file = await _appSettingsFile();
    if (!await file.exists()) {
      return const AppSettings(
        darkMode: true,
        themeIndex: 0,
        soundOnNudge: false,
        minimizeToTray: false,
        sharedRoomKey: '',
        autoUpdateChecks: false,
      );
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic>) {
      return const AppSettings(
        darkMode: true,
        themeIndex: 0,
        soundOnNudge: false,
        minimizeToTray: false,
        sharedRoomKey: '',
        autoUpdateChecks: false,
      );
    }
    return AppSettings.fromJson(data);
  } catch (_) {
    return const AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      minimizeToTray: false,
      sharedRoomKey: '',
      autoUpdateChecks: false,
    );
  }
}

Future<void> _saveAppSettings(AppSettings settings) async {
  try {
    final file = await _appSettingsFile();
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  } catch (_) {}
}

class _Diagnostics {
  static const int _maxLogBytes = 2 * 1024 * 1024;
  static const int _maxLogBackups = 3;
  File? _logFile;
  Directory? _crashDir;
  Future<void> _writeChain = Future<void>.value();

  Future<void> initialize() async {
    final dir = await _appDataDir();
    _logFile = File(p.join(dir.path, 'fileshare.log'));
    _crashDir = Directory(p.join(dir.path, 'crashes'));
    await _crashDir!.create(recursive: true);
    await _write('INFO', 'Diagnostics initialized at ${dir.path}');
  }

  void info(String message) {
    unawaited(_write('INFO', message));
  }

  void warn(String message, {Object? error, StackTrace? stack}) {
    unawaited(_write('WARN', message, error: error, stack: stack));
  }

  void captureFlutterError(FlutterErrorDetails details) {
    final context = details.context?.toDescription() ?? 'unknown';
    final stack = details.stack ?? StackTrace.current;
    captureUnhandledError(
      'flutter',
      details.exception,
      stack,
      context: context,
      library: details.library,
    );
  }

  void captureUnhandledError(
    String source,
    Object error,
    StackTrace stack, {
    String? context,
    String? library,
  }) {
    unawaited(
      _write(
        'FATAL',
        'Unhandled error from $source',
        error: error,
        stack: stack,
      ),
    );
    unawaited(
      _writeCrashReport(
        source: source,
        error: error,
        stack: stack,
        context: context,
        library: library,
      ),
    );
  }

  Future<void> _write(
    String level,
    String message, {
    Object? error,
    StackTrace? stack,
  }) async {
    final file = _logFile;
    if (file == null) return;
    final line = StringBuffer()
      ..write('[${DateTime.now().toIso8601String()}] [$level] ')
      ..write(message);
    if (error != null) {
      line.write(' | error=$error');
    }
    if (stack != null) {
      line.write('\n$stack');
    }
    line.write('\n');

    _writeChain = _writeChain
        .then((_) async {
          await _rotateLogsIfNeeded(file);
          await file.writeAsString(
            line.toString(),
            mode: FileMode.writeOnlyAppend,
            flush: true,
          );
        })
        .catchError((_) {});
    await _writeChain;
  }

  Future<void> _rotateLogsIfNeeded(File file) async {
    int length;
    try {
      length = await file.length();
    } catch (_) {
      return;
    }
    if (length < _maxLogBytes) return;

    final base = file.path;
    for (var i = _maxLogBackups; i >= 1; i--) {
      final src = File(i == 1 ? base : '$base.${i - 1}');
      if (!await src.exists()) continue;
      final dst = File('$base.$i');
      try {
        if (await dst.exists()) {
          await dst.delete();
        }
      } catch (_) {}
      try {
        await src.rename(dst.path);
      } catch (_) {
        try {
          await src.copy(dst.path);
          await src.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _writeCrashReport({
    required String source,
    required Object error,
    required StackTrace stack,
    String? context,
    String? library,
  }) async {
    final crashDir = _crashDir;
    if (crashDir == null) return;
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final crashFile = File(p.join(crashDir.path, 'crash_$stamp.txt'));
    final content = StringBuffer()
      ..writeln('FileShare Crash Report')
      ..writeln('Timestamp: ${DateTime.now().toIso8601String()}')
      ..writeln('Source: $source')
      ..writeln(
        'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('Dart: ${Platform.version}')
      ..writeln('Context: ${context ?? 'n/a'}')
      ..writeln('Library: ${library ?? 'n/a'}')
      ..writeln('Error: $error')
      ..writeln()
      ..writeln('Stack trace:')
      ..writeln(stack.toString());
    try {
      await crashFile.writeAsString(content.toString(), flush: true);
      await _write('INFO', 'Crash report written: ${crashFile.path}');
    } catch (_) {}
  }
}

class _SlidingRateLimiter {
  final Map<String, ListQueue<int>> _eventsByKey = {};

  bool allow(String key, {required int maxEvents, required Duration window}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - window.inMilliseconds;
    final q = _eventsByKey.putIfAbsent(key, () => ListQueue<int>());
    while (q.isNotEmpty && q.first < cutoff) {
      q.removeFirst();
    }
    if (q.length >= maxEvents) {
      return false;
    }
    q.addLast(now);
    if (q.isEmpty) {
      _eventsByKey.remove(key);
    }
    return true;
  }
}

class _PerPeerRateLimiter {
  final Map<String, Future<void>> _chains = <String, Future<void>>{};
  final Map<String, DateTime> _nextAllowedAt = <String, DateTime>{};

  Future<void> consume(String peerKey, int bytes, int bytesPerSecond) {
    if (bytes <= 0 || bytesPerSecond <= 0) {
      return Future<void>.value();
    }
    final micros = ((bytes * 1000000) / bytesPerSecond).ceil();
    final previous = _chains[peerKey] ?? Future<void>.value();
    final completer = Completer<void>();
    _chains[peerKey] = previous
        .then((_) async {
          final now = DateTime.now();
          final next = _nextAllowedAt[peerKey];
          if (next != null && next.isAfter(now)) {
            await Future<void>.delayed(next.difference(now));
          }
          _nextAllowedAt[peerKey] = DateTime.now().add(
            Duration(microseconds: max(1, micros)),
          );
          completer.complete();
        })
        .catchError((_) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        });
    return completer.future;
  }
}

class _ProtocolMismatchException implements Exception {
  _ProtocolMismatchException(this.remoteMajor);

  final int? remoteMajor;

  @override
  String toString() {
    return 'Protocol mismatch: local $_protocolMajor.x, '
        'remote ${remoteMajor ?? 'unknown'}.x';
  }
}

class _TransferCanceledException implements Exception {
  @override
  String toString() => 'Transfer canceled';
}

enum PeerState { discovered, syncing, reachable, stale }

enum PeerAvailability { active, away, idle }

class PeerHealthSummary {
  const PeerHealthSummary({
    required this.score,
    required this.tier,
    required this.hint,
  });

  final int score;
  final String tier;
  final String hint;
}

PeerHealthSummary evaluatePeerHealth({
  required Duration contactAge,
  required bool hasManifest,
  required int fetchFailureStreak,
  required PeerState state,
}) {
  var score = 100;
  String hint = 'Healthy';

  if (state == PeerState.stale) {
    score -= 55;
    hint =
        'Peer looks stale. Confirm both apps are open and firewall allows ports 40405/40406.';
  } else if (state == PeerState.discovered) {
    score -= 18;
    hint = 'Peer discovered but not fully synced yet.';
  } else if (state == PeerState.syncing) {
    score -= 10;
    hint = 'Peer is syncing.';
  }

  if (!hasManifest) {
    score -= 12;
    if (hint == 'Healthy') {
      hint = 'Manifest not synced yet.';
    }
  }

  if (fetchFailureStreak > 0) {
    score -= min(35, fetchFailureStreak * 8);
    if (fetchFailureStreak >= 3) {
      hint = 'Repeated fetch failures. Try Send Probe or Connect TCP.';
    }
  }

  if (contactAge > const Duration(seconds: 25)) {
    score -= 22;
    if (hint == 'Healthy') hint = 'Peer is idle.';
  } else if (contactAge > const Duration(seconds: 8)) {
    score -= 10;
    if (hint == 'Healthy') hint = 'Peer may be away.';
  }

  final clamped = score.clamp(0, 100).toInt();
  String tier;
  if (clamped >= 85) {
    tier = 'Excellent';
  } else if (clamped >= 65) {
    tier = 'Good';
  } else if (clamped >= 40) {
    tier = 'Fair';
  } else {
    tier = 'Poor';
  }

  return PeerHealthSummary(score: clamped, tier: tier, hint: hint);
}

enum TransferDirection { download, upload }

enum TransferState { running, completed, failed, canceled }

class TransferEntry {
  TransferEntry({
    required this.id,
    required this.name,
    required this.peerName,
    required this.direction,
    required this.totalBytes,
    required this.startedAt,
  }) : updatedAt = startedAt,
       _sampleAt = startedAt;

  final String id;
  final String name;
  final String peerName;
  final TransferDirection direction;
  final int totalBytes;
  final DateTime startedAt;
  DateTime updatedAt;
  int transferredBytes = 0;
  double speedBytesPerSecond = 0;
  TransferState state = TransferState.running;
  String? error;
  String? outputPath;

  DateTime _sampleAt;
  int _sampleBytes = 0;

  Duration? get eta {
    final speed = speedBytesPerSecond;
    if (speed <= 0 || totalBytes <= 0 || transferredBytes >= totalBytes) {
      return null;
    }
    final remainingBytes = totalBytes - transferredBytes;
    final seconds = remainingBytes / speed;
    if (seconds.isNaN || seconds.isInfinite || seconds < 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void addBytes(int bytes) {
    if (state != TransferState.running) return;
    final now = DateTime.now();
    transferredBytes = min(totalBytes, transferredBytes + bytes);
    updatedAt = now;

    final dtMs = now.difference(_sampleAt).inMilliseconds;
    if (dtMs >= 200) {
      final deltaBytes = transferredBytes - _sampleBytes;
      if (deltaBytes > 0) {
        speedBytesPerSecond = deltaBytes * 1000 / dtMs;
      }
      _sampleAt = now;
      _sampleBytes = transferredBytes;
    }
  }

  void complete({required TransferState state, String? error}) {
    this.state = state;
    if (state == TransferState.completed) {
      transferredBytes = totalBytes;
    }
    this.error = error;
    updatedAt = DateTime.now();
  }
}

class LocalItem {
  LocalItem({
    required this.id,
    required this.name,
    required this.rel,
    required this.path,
    required this.size,
    required this.iconBytes,
  });

  final String id;
  final String name;
  final String rel;
  final String path;
  final int size;
  final Uint8List? iconBytes;

  LocalItem copyWith({
    String? name,
    String? rel,
    int? size,
    Uint8List? iconBytes,
  }) => LocalItem(
    id: id,
    name: name ?? this.name,
    rel: rel ?? this.rel,
    path: path,
    size: size ?? this.size,
    iconBytes: iconBytes ?? this.iconBytes,
  );
}

class RemoteItem {
  RemoteItem({
    required this.id,
    required this.name,
    required this.rel,
    required this.size,
    required this.iconBytes,
    required this.iconFingerprint,
  });

  final String id;
  final String name;
  final String rel;
  final int size;
  final Uint8List? iconBytes;
  final int? iconFingerprint;
}

class ShareItem {
  ShareItem({
    required this.ownerId,
    required this.owner,
    required this.itemId,
    required this.name,
    required this.rel,
    required this.size,
    required this.local,
    required this.path,
    required this.iconBytes,
    required this.peerId,
  });

  final String ownerId;
  final String owner;
  final String itemId;
  final String name;
  final String rel;
  final int size;
  final bool local;
  final String? path;
  final Uint8List? iconBytes;
  final String? peerId;

  String get key => '$ownerId::$itemId';
}

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.addr,
    required this.port,
    required this.rev,
    required this.items,
    required this.lastSeen,
    required this.lastGoodContact,
  });

  final String id;
  String name;
  InternetAddress addr;
  int port;
  int rev;
  List<RemoteItem> items;
  DateTime lastSeen;
  DateTime lastGoodContact;
  bool fetching = false;
  bool hasManifest = false;
  DateTime lastFetch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime nextFetchAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int fetchFailureStreak = 0;

  bool canFetchAt(DateTime now) => !now.isBefore(nextFetchAllowedAt);

  void recordFetchSuccess() {
    fetchFailureStreak = 0;
    nextFetchAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void recordFetchFailure() {
    fetchFailureStreak = min(fetchFailureStreak + 1, 6);
    final backoffMs = 300 * (1 << (fetchFailureStreak - 1));
    nextFetchAllowedAt = DateTime.now().add(
      Duration(milliseconds: backoffMs.clamp(300, 9600)),
    );
  }
}

class _Header {
  _Header({required this.line, required this.it, required this.rem});

  final String line;
  final StreamIterator<Uint8List> it;
  final Uint8List rem;
}

String _fmt(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _fmtRate(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  return '${_fmt(bytesPerSecond.round())}/s';
}

String _fmtDuration(Duration d) {
  if (d.inSeconds <= 0) return '<1s';
  if (d.inHours > 0) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${h}h ${m}m ${s}s';
  }
  if (d.inMinutes > 0) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${m}m ${s}s';
  }
  return '${d.inSeconds}s';
}

IconData _iconForName(String name) {
  final ext = p.extension(name).toLowerCase();
  if (ext.isEmpty) return Icons.insert_drive_file_outlined;
  if ([
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
  ].contains(ext)) {
    return Icons.image_outlined;
  }
  if (['.mp4', '.mov', '.avi', '.mkv', '.wmv', '.webm'].contains(ext)) {
    return Icons.movie_outlined;
  }
  if (['.mp3', '.wav', '.flac', '.aac', '.ogg'].contains(ext)) {
    return Icons.audiotrack_outlined;
  }
  if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) {
    return Icons.archive_outlined;
  }
  if (['.pdf'].contains(ext)) {
    return Icons.picture_as_pdf_outlined;
  }
  if (['.doc', '.docx', '.rtf'].contains(ext)) {
    return Icons.description_outlined;
  }
  if (['.xls', '.xlsx', '.csv'].contains(ext)) {
    return Icons.table_chart_outlined;
  }
  if (['.ppt', '.pptx'].contains(ext)) {
    return Icons.slideshow_outlined;
  }
  if (['.exe', '.msi', '.dll'].contains(ext)) {
    return Icons.settings_applications_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

Color _iconColorForName(String name, ThemeData theme) {
  final ext = p.extension(name).toLowerCase();
  if ([
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
  ].contains(ext)) {
    return Colors.tealAccent.shade400;
  }
  if (['.mp4', '.mov', '.avi', '.mkv', '.wmv', '.webm'].contains(ext)) {
    return Colors.deepPurpleAccent.shade100;
  }
  if (['.mp3', '.wav', '.flac', '.aac', '.ogg'].contains(ext)) {
    return Colors.orangeAccent.shade200;
  }
  if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) {
    return Colors.blueGrey.shade200;
  }
  if (['.pdf'].contains(ext)) {
    return Colors.redAccent.shade200;
  }
  if (['.doc', '.docx', '.rtf'].contains(ext)) {
    return Colors.lightBlueAccent.shade100;
  }
  if (['.xls', '.xlsx', '.csv'].contains(ext)) {
    return Colors.greenAccent.shade200;
  }
  if (['.ppt', '.pptx'].contains(ext)) {
    return Colors.deepOrangeAccent.shade100;
  }
  if (['.exe', '.msi', '.dll'].contains(ext)) {
    return theme.colorScheme.onSurface.withValues(alpha: 0.8);
  }
  return theme.colorScheme.onSurface.withValues(alpha: 0.8);
}

String _id() {
  final r = Random.secure();
  return List<int>.generate(
    8,
    (_) => r.nextInt(256),
  ).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
}
