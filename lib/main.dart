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
import 'package:local_notifier/local_notifier.dart';
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
const int _maxConcurrentInboundClients = 64;
const int _dragCacheMaxBytes = 2 * 1024 * 1024 * 1024; // 2 GiB
const Duration _dragCacheMaxAge = Duration(days: 7);
const Duration _housekeepingInterval = Duration(minutes: 15);
const Size _minWindowSize = Size(420, 280);
const Size _defaultWindowSize = Size(900, 600);
const Duration _announceInterval = Duration(milliseconds: 700);
const Duration _refreshInterval = Duration(milliseconds: 350);
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

Future<void> main() async {
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

  await runZonedGuarded(() async {
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

    runApp(MyApp(initialSettings: savedAppSettings));
    _diagnostics.info('Application started');
    unawaited(_restoreWindow(savedWindowState));
  }, (error, stack) {
    _diagnostics.captureUnhandledError('zone', error, stack);
  });
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
  const MyApp({super.key, required this.initialSettings});

  final AppSettings initialSettings;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late bool dark;
  late int themeIndex;
  late bool soundOnNudge;
  late bool minimizeToTray;
  late String sharedRoomKey;

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
    sharedRoomKey = widget.initialSettings.sharedRoomKey;
  }

  Future<void> _persistSettings() async {
    await _saveAppSettings(
      AppSettings(
        darkMode: dark,
        themeIndex: themeIndex,
        soundOnNudge: soundOnNudge,
        minimizeToTray: minimizeToTray,
        sharedRoomKey: sharedRoomKey,
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
        initialSharedRoomKey: sharedRoomKey,
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
        onSharedRoomKeyChanged: (value) {
          setState(() => sharedRoomKey = value);
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
    required this.initialSharedRoomKey,
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onSoundOnNudgeChanged,
    required this.onMinimizeToTrayChanged,
    required this.onSharedRoomKeyChanged,
  });

  final bool dark;
  final int themeIndex;
  final bool initialSoundOnNudge;
  final bool initialMinimizeToTray;
  final String initialSharedRoomKey;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final ValueChanged<bool> onSoundOnNudgeChanged;
  final ValueChanged<bool> onMinimizeToTrayChanged;
  final ValueChanged<String> onSharedRoomKeyChanged;

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
  bool _flash = false;
  bool _soundOnNudge = false;
  bool _minimizeToTray = false;
  String _sharedRoomKey = '';
  bool _trayInitialized = false;
  bool _isHiddenToTray = false;
  bool _isQuitting = false;
  Timer? _flashTimer;
  Timer? _windowSaveDebounce;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeProgress;

  @override
  void initState() {
    super.initState();
    _minimizeToTray = widget.initialMinimizeToTray;
    _soundOnNudge = widget.initialSoundOnNudge;
    _sharedRoomKey = widget.initialSharedRoomKey;
    c.setSharedRoomKey(_sharedRoomKey);
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
    final remoteCount = c.items.where((e) => !e.local).length;
    if (_isHiddenToTray && remoteCount > _lastRemoteCount) {
      unawaited(
        _showTrayNotification('FileShare', 'New file shared by a peer.'),
      );
    }
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
      suggestedName: suggestedName,
      acceptedTypeGroups: acceptedGroups,
      confirmButtonText: 'Download',
    );
    if (location == null) return;
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
    if (_minimizeToTray) {
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
    String? notificationTitle,
    String? notificationBody,
  }) async {
    if (!_minimizeToTray || !Platform.isWindows) return;
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

  Future<void> _quitApplication() async {
    _isQuitting = true;
    _diagnostics.info('Application shutdown requested');
    await windowManager.setPreventClose(false);
    await windowManager.setSkipTaskbar(false);
    await _disposeTray();
    await windowManager.close();
  }

  Future<void> _onMinimizePressed() async {
    if (_minimizeToTray) {
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
                        child: c.items.isEmpty
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
                            : _ExplorerGrid(
                                items: c.items,
                                buildDragItem: c.buildDragItem,
                                onRemove: (item) => c.removeLocal(item.itemId),
                                onDownload: _downloadRemoteItem,
                                showGrid: _pointerHovering,
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
    final diagnostics = c.networkDiagnostics.entries
        .where((e) => e.value > 0)
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    final localIpSummary = c.localIps.isEmpty
        ? 'Unavailable'
        : c.localIps.join(', ');
    final probeController = TextEditingController();
    final keyController = TextEditingController(text: _sharedRoomKey);
    String? probeStatus;
    bool sendingProbe = false;
    String? connectStatus;
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
                    ],
                  ),
                  if (connectStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(connectStatus!),
                  ],
                  const SizedBox(height: 8),
                  Text('Peers Online: ${c.connectedPeerCount}'),
                  if (peers.isEmpty) const Text('No peers connected'),
                  for (final p in peers)
                    Text(
                      '- ${p.name} | ${p.addr.address}:${p.port}'
                      '${c.peerStatus[p.id] == null ? '' : ' | ${c.peerStatus[p.id]}'}',
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
    probeController.dispose();
  }
}

class _SettingsButton extends StatefulWidget {
  const _SettingsButton({
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
  State<_SettingsButton> createState() => _SettingsButtonState();
}

class _SettingsButtonState extends State<_SettingsButton> {
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
        _SettingsButton(
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

class _ExplorerGrid extends StatelessWidget {
  const _ExplorerGrid({
    required this.items,
    required this.buildDragItem,
    required this.onRemove,
    required this.onDownload,
    required this.showGrid,
  });

  final List<ShareItem> items;
  final Future<DragItem?> Function(ShareItem) buildDragItem;
  final ValueChanged<ShareItem> onRemove;
  final Future<void> Function(ShareItem) onDownload;
  final bool showGrid;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = 120.0;
        final columns = max(1, (constraints.maxWidth / tileWidth).floor());
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
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.9,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _IconTile(
                    key: ValueKey(item.key),
                    item: item,
                    createItem: buildDragItem,
                    onRemove: item.local ? () => onRemove(item) : null,
                    onDownload: item.local ? null : () => onDownload(item),
                  );
                },
              ),
            );
          },
        );
      },
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

class _IconTile extends StatefulWidget {
  const _IconTile({
    super.key,
    required this.item,
    required this.createItem,
    required this.onRemove,
    required this.onDownload,
  });

  final ShareItem item;
  final Future<DragItem?> Function(ShareItem) createItem;
  final VoidCallback? onRemove;
  final Future<void> Function()? onDownload;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile> {
  bool dragging = false;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconData = _iconForName(widget.item.name);
    final iconColor = _iconColorForName(widget.item.name, theme);
    final iconBytes = widget.item.iconBytes;
    final label = p.basename(widget.item.name);

    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: _provider,
      child: DraggableWidget(
        child: AnimatedOpacity(
          opacity: dragging ? 0.6 : 1,
          duration: const Duration(milliseconds: 90),
          child: Tooltip(
            message:
                '${widget.item.rel}\n${_fmt(widget.item.size)} • ${widget.item.owner}',
            waitDuration: const Duration(milliseconds: 500),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.shadow.withValues(
                              alpha: 0.15,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: iconBytes == null
                          ? Icon(iconData, size: 36, color: iconColor)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(10),
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
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 110,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (widget.onDownload != null || widget.onRemove != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onDownload != null)
                        IconButton(
                          tooltip: 'Download...',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => widget.onDownload?.call(),
                          icon: const Icon(Icons.download, size: 16),
                        ),
                      if (widget.onRemove != null)
                        IconButton(
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onRemove,
                          icon: const Icon(Icons.close, size: 16),
                        ),
                    ],
                  ),
              ],
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
  });

  final List<TransferEntry> transfers;
  final VoidCallback onClearFinished;
  final void Function(String transferId) onCancelTransfer;

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
  });

  final TransferEntry transfer;
  final void Function(String transferId) onCancelTransfer;

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
  final Map<String, int> _networkDiagnostics = <String, int>{};
  int _transferCounter = 0;
  int _activeInboundClients = 0;
  DateTime _lastTransferNotify = DateTime.fromMillisecondsSinceEpoch(0);
  String _sharedRoomKey = '';

  String get sharedRoomKey => _sharedRoomKey;

  void setSharedRoomKey(String key) {
    _sharedRoomKey = key.trim();
  }

  Map<String, int> get networkDiagnostics =>
      Map<String, int>.unmodifiable(_networkDiagnostics);

  void _incDiagnostic(String key) {
    _networkDiagnostics.update(key, (v) => v + 1, ifAbsent: () => 1);
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

    _announce = Timer.periodic(_announceInterval, (_) => _broadcast());
    _refresh = Timer.periodic(_refreshInterval, (_) => refreshAll());
    _prune = Timer.periodic(_pruneInterval, (_) => _prunePeers());
    _housekeeping = Timer.periodic(
      _housekeepingInterval,
      (_) => unawaited(_cleanupDragCache()),
    );

    await _loadIps();
    unawaited(_cleanupDragCache());
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
      await for (final entity in dragDir.list(recursive: true, followLinks: false)) {
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

  void sendNudge() {
    final u = _udp;
    if (u == null) return;
    final payloadMap = _withAuth(<String, dynamic>{
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
    final payloadBytes = utf8.encode(jsonEncode(payloadMap));
    for (final target in _broadcastTargets()) {
      u.send(payloadBytes, target, _discoveryPort);
    }
    if (multicastEnabled) {
      u.send(
        payloadBytes,
        InternetAddress(_discoveryMulticastGroup),
        _discoveryPort,
      );
    }

    // Broadcast can be asymmetric on some LAN setups; also nudge peers directly.
    final sent = <String>{};
    for (final p in peers.values) {
      final ip = p.addr.address;
      if (!sent.add(ip)) continue;
      u.send(payloadBytes, p.addr, _discoveryPort);
      unawaited(_sendNudgeTcp(p, payloadMap));
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
    final payload = jsonEncode(_withAuth({
      'tag': _tag,
      'type': 'probe',
      'protocolMajor': _protocolMajor,
      'protocolMinor': _protocolMinor,
      'id': deviceId,
      'name': deviceName,
      'port': listenPort,
      'revision': revision,
    }));
    u.send(utf8.encode(payload), addr, port);
    return true;
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
    try {
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
        final id = manifest.id;
        final name = manifest.name;
        final rev = manifest.revision;
        final list = manifest.items;
        final now = DateTime.now();
        final p = peers.putIfAbsent(
          id,
          () => Peer(
            id: id,
            name: name,
            addr: addr!,
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
          ..lastGoodContact = now;
        _mergeDuplicatePeersFor(id);
        p.items
          ..clear()
          ..addAll(list);
        peerStatus[id] = 'OK (${list.length} items)';
        notifyListeners();
        return 'Connected: $name (${list.length} items)';
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
        item.add(
          Formats.fileUri(
            Uri.file(dragPath, windows: true),
          ),
        );
        return item;
      }

      if (s.local) {
        final path = s.path;
        if (path == null || path.isEmpty) return null;
        item.add(
          Formats.fileUri(
            Uri.file(path, windows: Platform.isWindows),
          ),
        );
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
      final itemDir = Directory(p.join(dragDir.path, '${s.ownerId}_${s.itemId}'));
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
    final sink = temp.openWrite(mode: FileMode.writeOnly);
    try {
      final completed = await _streamRemote(item, sink, () => false);
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
    for (final p in peers.values.toList(growable: false)) {
      if (p.fetching) continue;
      if (!p.canFetchAt(now)) continue;
      if (now.difference(p.lastFetch) < _minFetchInterval) continue;
      unawaited(_fetchManifest(p));
    }
  }

  Future<void> runHealthCheck() async {
    final peersSnapshot = peers.values.toList(growable: false);
    for (final peer in peersSnapshot) {
      peerHealth[peer.id] = 'Checking...';
    }
    notifyListeners();

    for (final peer in peersSnapshot) {
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
    final iconBytes = await _resolveIconBytes(norm);
    final existing = _pathToId[norm];
    if (existing != null && _local[existing] != null) {
      _local[existing] = _local[existing]!.copyWith(
        name: p.basename(norm),
        rel: rel,
        size: size,
        iconBytes: iconBytes,
      );
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
      iconBytes: iconBytes,
    );
    _pathToId[norm] = id;
    return true;
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
    final payload = jsonEncode(_withAuth({
      'tag': _tag,
      'type': 'presence',
      'protocolMajor': _protocolMajor,
      'protocolMinor': _protocolMinor,
      'id': deviceId,
      'name': deviceName,
      'port': listenPort,
      'revision': revision,
    }));
    u.send(utf8.encode(payload), addr, _discoveryPort);
  }

  Future<void> _sendNudgeTcp(Peer peer, Map<String, dynamic> payload) async {
    try {
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
      if (
          !_udpRateLimiter.allow(
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
          final key = id ?? '${name ?? g.address.address}:${port ?? _discoveryPort}';
          incompatiblePeers[key] =
              '${name ?? g.address.address} (${g.address.address}:${port ?? _discoveryPort}) '
              'uses protocol ${incomingMajor ?? 'unknown'}.x';
          continue;
        }
        final type = _safeString(map['type'], maxChars: 24);
        if (type == null) continue;
        if (type == 'nudge') {
          final id = _safeString(map['id'], maxChars: _maxPeerIdChars);
          if (id != null) _applyNudgeFrom(id);
          continue;
        }
        if (type == 'probe') {
          final id = _safeString(map['id'], maxChars: _maxPeerIdChars);
          if (id != null && id != deviceId) {
            _sendPresenceTo(g.address);
          }
        }
        final id = _safeString(map['id'], maxChars: _maxPeerIdChars);
        final name = _safeString(map['name'], maxChars: _maxPeerNameChars);
        final port = _safeInt(map['port'], min: 1, max: 65535);
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
    final now = DateTime.now();
    final stale = peers.values
        .where((e) => now.difference(e.lastGoodContact) > _peerPruneAfter)
        .map((e) => e.id)
        .toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      peers.remove(id);
      peerStatus.remove(id);
      peerHealth.remove(id);
    }
    notifyListeners();
  }

  Future<void> _fetchManifest(Peer p0, {bool force = false}) async {
    if (p0.fetching) return;
    if (!force && !p0.canFetchAt(DateTime.now())) return;
    p0.fetching = true;
    p0.lastFetch = DateTime.now();
    peerStatus[p0.id] = 'Fetching...';
    try {
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
        p0.lastSeen = DateTime.now();
        p0.lastGoodContact = DateTime.now();
        p0.recordFetchSuccess();
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
          x.size != y.size) {
        return false;
      }
      final xb = x.iconBytes;
      final yb = y.iconBytes;
      if (xb == null && yb == null) continue;
      if (xb == null || yb == null) return false;
      if (xb.length != yb.length) return false;
      for (var j = 0; j < xb.length; j++) {
        if (xb[j] != yb[j]) return false;
      }
    }
    return true;
  }

  Future<void> _sendManifestRequest(Socket s) async {
    s.write(
      jsonEncode(_withAuth({
        'type': 'manifest',
        'protocolMajor': _protocolMajor,
        'protocolMinor': _protocolMinor,
        'clientId': deviceId,
        'clientName': deviceName,
        'clientPort': listenPort,
        'clientRevision': revision,
      })),
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
    try {
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
            ((m['items'] as List<dynamic>? ?? const <dynamic>[]).length)
                .clamp(0, _maxManifestItems);
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
        final manifestItems = _local.values.take(_maxManifestItems).map((e) {
          final iconBytes = e.iconBytes;
          return {
            'id': e.id,
            'name': e.name,
            'relativePath': e.rel,
            'size': e.size,
            'iconPngBase64': (iconBytes == null || iconBytes.length > _maxIconBytes)
                ? null
                : base64Encode(iconBytes),
          };
        }).toList(growable: false);
        s.write(
          jsonEncode(_withAuth({
            'type': 'manifest',
            'protocolMajor': _protocolMajor,
            'protocolMinor': _protocolMinor,
            'id': deviceId,
            'name': deviceName,
            'revision': revision,
            'items': manifestItems,
          })),
        );
        s.write('\n');
        await s.flush();
        return;
      }
      if (type == 'download') {
        final id = _safeString(req['id'], maxChars: 256);
        if (id == null) return;
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
          jsonEncode(_withAuth({
            'type': 'file',
            'name': item.name,
            'relativePath': item.rel,
            'size': item.size,
          })),
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
          await s.addStream(
            file.openRead().map((chunk) {
              _addTransferProgress(transferId, chunk.length);
              return chunk;
            }),
          );
          await s.flush();
          _finishTransfer(transferId, state: TransferState.completed);
        } catch (e) {
          _finishTransfer(
            transferId,
            state: TransferState.failed,
            error: e.toString(),
          );
          rethrow;
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
    bool Function() canceled,
  ) async {
    final peer = peers[it.peerId];
    if (peer == null) throw Exception('Peer not found');
    final s = await Socket.connect(
      peer.addr,
      peer.port,
      timeout: const Duration(seconds: 5),
    );
    try {
      s.write(
        jsonEncode(_withAuth({
          'type': 'download',
          'protocolMajor': _protocolMajor,
          'protocolMinor': _protocolMinor,
          'clientId': deviceId,
          'clientName': deviceName,
          'clientPort': listenPort,
          'id': it.itemId,
        })),
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
      try {
        var left = totalBytes;
        if (h.rem.isNotEmpty) {
          final n = min(left, h.rem.length);
          if (n > 0 && !canceled() && !_canceledTransfers.contains(transferId)) {
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
    final incomingMajor = _safeInt(
      m['protocolMajor'],
      min: 0,
      max: 0x7fffffff,
    );
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
      if (itemId == null || itemName == null || relativePath == null || size == null) {
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
    this.sharedRoomKey = '',
  });

  final bool darkMode;
  final int themeIndex;
  final bool soundOnNudge;
  final bool minimizeToTray;
  final String sharedRoomKey;

  Map<String, dynamic> toJson() => {
    'darkMode': darkMode,
    'themeIndex': themeIndex,
    'soundOnNudge': soundOnNudge,
    'minimizeToTray': minimizeToTray,
    'sharedRoomKey': sharedRoomKey,
  };

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      darkMode: json['darkMode'] == true,
      themeIndex: (json['themeIndex'] as num?)?.toInt() ?? 0,
      soundOnNudge: json['soundOnNudge'] == true,
      minimizeToTray: json['minimizeToTray'] == true,
      sharedRoomKey: (json['sharedRoomKey'] as String? ?? '').trim(),
    );
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

    _writeChain = _writeChain.then((_) async {
      await _rotateLogsIfNeeded(file);
      await file.writeAsString(
        line.toString(),
        mode: FileMode.writeOnlyAppend,
        flush: true,
      );
    }).catchError((_) {});
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
      ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
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

  bool allow(
    String key, {
    required int maxEvents,
    required Duration window,
  }) {
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
  });

  final String id;
  final String name;
  final String rel;
  final int size;
  final Uint8List? iconBytes;
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
