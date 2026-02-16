import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart' as clip;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:win32/win32.dart' as win32;
import 'package:window_manager/window_manager.dart';

const int _discoveryPort = 40405;
const int _transferPort = 40406;
const String _discoveryMulticastGroup = '239.255.77.77';
const String _tag = 'fileshare_lan_v2';
const int _maxHeaderBytes = 5 * 1024 * 1024;
const Size _minWindowSize = Size(420, 280);
const Size _defaultWindowSize = Size(900, 600);
const Duration _announceInterval = Duration(milliseconds: 700);
const Duration _refreshInterval = Duration(milliseconds: 350);
const Duration _minFetchInterval = Duration(milliseconds: 280);
const Duration _pruneInterval = Duration(seconds: 3);
const Duration _peerPruneAfter = Duration(seconds: 20);
final bool _isTest =
    bool.fromEnvironment('FLUTTER_TEST') ||
    Platform.environment.containsKey('FLUTTER_TEST');

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
  await windowManager.ensureInitialized();
  final savedWindowState = await _loadWindowState();

  runApp(const MyApp());

  doWhenWindowReady(() {
    unawaited(_restoreWindow(savedWindowState));
  });
}

Future<void> _restoreWindow(_WindowState? saved) async {
  appWindow.minSize = _minWindowSize;
  await windowManager.setMinimumSize(_minWindowSize);

  if (saved == null) {
    await windowManager.setSize(_defaultWindowSize);
    await windowManager.setAlignment(Alignment.center);
    appWindow.show();
    return;
  }

  final width = max(saved.width, _minWindowSize.width);
  final height = max(saved.height, _minWindowSize.height);
  await windowManager.setBounds(
    Rect.fromLTWH(saved.left, saved.top, width, height),
  );
  appWindow.show();

  if (saved.maximized) {
    await windowManager.maximize();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool dark = true;
  int themeIndex = 0;

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
        onToggleTheme: () => setState(() => dark = !dark),
        onSelectTheme: (index) => setState(() => themeIndex = index),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.dark,
    required this.themeIndex,
    required this.onToggleTheme,
    required this.onSelectTheme,
  });

  final bool dark;
  final int themeIndex;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home>
    with WindowListener, SingleTickerProviderStateMixin {
  final c = Controller();
  late final AudioPlayer _nudgeAudioPlayer;
  bool over = false;
  bool _isFocused = true;
  int _lastNudge = 0;
  bool _flash = false;
  bool _soundOnNudge = false;
  bool _showTransferDetails = false;
  Timer? _flashTimer;
  Timer? _windowSaveDebounce;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeProgress;

  @override
  void initState() {
    super.initState();
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
    unawaited(_initFocus());
    unawaited(c.start());
  }

  Future<void> _initFocus() async {
    _isFocused = await windowManager.isFocused();
  }

  void _changed() {
    if (c.nudgeTick != _lastNudge) {
      _lastNudge = c.nudgeTick;
      _handleNudge();
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
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => c.sendNudge(),
            child: AnimatedBuilder(
              animation: _shakeProgress,
              builder: (context, child) {
                final t = _shakeProgress.value;
                final amp = (1 - t) * 10;
                final dx = sin(t * pi * 10) * amp;
                return Transform.translate(offset: Offset(dx, 0), child: child);
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
                    child: _isTest
                        ? _TitleBarContent(
                            dark: widget.dark,
                            themeIndex: widget.themeIndex,
                            connectedCount: c.peers.length,
                            onToggleTheme: widget.onToggleTheme,
                            onSelectTheme: widget.onSelectTheme,
                            onShowSettings: _showSettings,
                            showMoveArea: false,
                            showWindowButtons: false,
                          )
                        : WindowTitleBarBox(
                            child: _TitleBarContent(
                              dark: widget.dark,
                              themeIndex: widget.themeIndex,
                              connectedCount: c.peers.length,
                              onToggleTheme: widget.onToggleTheme,
                              onSelectTheme: widget.onSelectTheme,
                              onShowSettings: _showSettings,
                              showMoveArea: true,
                              showWindowButtons: true,
                            ),
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
                        expanded: _showTransferDetails,
                        onToggleExpanded: () {
                          setState(
                            () => _showTransferDetails = !_showTransferDetails,
                          );
                        },
                        onClearFinished: c.clearFinishedTransfers,
                      ),
                    ),
                ],
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
    final localIpSummary = c.localIps.isEmpty
        ? 'Unavailable'
        : c.localIps.join(', ');
    final probeController = TextEditingController();
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
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sound on nudge'),
                    value: _soundOnNudge,
                    onChanged: (value) {
                      setDialogState(() => _soundOnNudge = value);
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
                  Text('Peers Online: ${peers.length}'),
                  if (peers.isEmpty) const Text('No peers connected'),
                  for (final p in peers)
                    Text('- ${p.name} | ${p.addr.address}:${p.port}'),
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
  }
}

class _SettingsButton extends StatefulWidget {
  const _SettingsButton({
    required this.dark,
    required this.themeIndex,
    required this.connectedCount,
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onShowSettings,
  });

  final bool dark;
  final int themeIndex;
  final int connectedCount;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final VoidCallback onShowSettings;

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
    required this.onToggleTheme,
    required this.onSelectTheme,
    required this.onShowSettings,
    required this.showMoveArea,
    required this.showWindowButtons,
  });

  final bool dark;
  final int themeIndex;
  final int connectedCount;
  final VoidCallback onToggleTheme;
  final ValueChanged<int> onSelectTheme;
  final VoidCallback onShowSettings;
  final bool showMoveArea;
  final bool showWindowButtons;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 8),
        Expanded(child: showMoveArea ? MoveWindow() : const SizedBox()),
        _SettingsButton(
          dark: dark,
          themeIndex: themeIndex,
          connectedCount: connectedCount,
          onToggleTheme: onToggleTheme,
          onSelectTheme: onSelectTheme,
          onShowSettings: onShowSettings,
        ),
        const SizedBox(width: 8),
        if (showWindowButtons) WindowButtons(theme: Theme.of(context)),
      ],
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key, required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.8);
    final hover = theme.colorScheme.onSurface.withValues(alpha: 0.1);
    final closeHover = Colors.red.shade700;

    final buttonColors = WindowButtonColors(
      iconNormal: base,
      mouseOver: hover,
      mouseDown: hover,
      iconMouseOver: base,
      iconMouseDown: base,
    );

    final closeButtonColors = WindowButtonColors(
      iconNormal: base,
      mouseOver: closeHover,
      mouseDown: closeHover.withValues(alpha: 0.9),
      iconMouseOver: Colors.white,
      iconMouseDown: Colors.white,
    );

    return Row(
      children: [
        MinimizeWindowButton(colors: buttonColors),
        MaximizeWindowButton(colors: buttonColors),
        CloseWindowButton(colors: closeButtonColors),
      ],
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
  });

  final List<ShareItem> items;
  final Future<DragItem?> Function(ShareItem) buildDragItem;
  final ValueChanged<ShareItem> onRemove;
  final Future<void> Function(ShareItem) onDownload;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = 120.0;
        final columns = max(1, (constraints.maxWidth / tileWidth).floor());
        return CustomPaint(
          painter: _ExplorerGridPainter(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.06),
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
    final item = await widget.createItem(widget.item);
    if (item == null) return null;

    void upd() {
      if (mounted) setState(() => dragging = r.session.dragging.value);
    }

    r.session.dragging.addListener(upd);
    upd();
    return item;
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
    required this.expanded,
    required this.onToggleExpanded,
    required this.onClearFinished,
  });

  final List<TransferEntry> transfers;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onClearFinished;

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
                    TextButton(
                      onPressed: onToggleExpanded,
                      child: Text(expanded ? 'Hide details' : 'More details'),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: transfers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        return _TransferRow(transfer: transfers[index]);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer});

  final TransferEntry transfer;

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

  int listenPort = 0;
  int revision = 0;
  int _counter = 0;
  List<String> localIps = [];
  bool multicastEnabled = false;
  int nudgeTick = 0;
  final Map<String, Uint8List> _iconCache = {};
  final Map<String, String> peerHealth = {};
  final Map<String, String> peerStatus = {};
  final Map<String, DateTime> _lastNudgeFrom = {};
  final Map<String, TransferEntry> _transfers = {};
  int _transferCounter = 0;
  DateTime _lastTransferNotify = DateTime.fromMillisecondsSinceEpoch(0);

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

    await _loadIps();
    _broadcast();
    notifyListeners();
  }

  @override
  void dispose() {
    _announce?.cancel();
    _refresh?.cancel();
    _prune?.cancel();
    _udp?.close();
    _tcp?.close();
    super.dispose();
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
    final payloadMap = <String, dynamic>{
      'tag': _tag,
      'type': 'nudge',
      'id': deviceId,
      'name': deviceName,
      'clientId': deviceId,
      'clientName': deviceName,
      'clientPort': listenPort,
      'clientRevision': revision,
    };
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
    final payload = jsonEncode({
      'tag': _tag,
      'type': 'probe',
      'id': deviceId,
      'name': deviceName,
      'port': listenPort,
      'revision': revision,
    });
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
        final line = await _readLine(s);
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m['type'] != 'manifest') return 'Bad response';
        final id = m['id'] as String? ?? '${addr.address}:$port';
        final name = m['name'] as String? ?? addr.address;
        final rev = (m['revision'] as num?)?.toInt() ?? 0;
        final list = (m['items'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map((e) {
              final iconBase64 = e['iconPngBase64'] as String?;
              return RemoteItem(
                id: e['id'] as String,
                name: e['name'] as String,
                rel: e['relativePath'] as String,
                size: (e['size'] as num).toInt(),
                iconBytes: iconBase64 == null ? null : base64Decode(iconBase64),
              );
            })
            .toList(growable: false);
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
          ),
        );
        p
          ..name = name
          ..addr = addr
          ..port = port
          ..rev = rev
          ..lastSeen = now;
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
    if (!item.virtualFileSupported) return null;
    item.addVirtualFile(
      format: _fileFormat(s.name),
      provider: (sinkProvider, progress) {
        unawaited(_streamForDrag(s, sinkProvider, progress));
      },
    );
    return item;
  }

  Future<void> downloadRemoteToPath(ShareItem item, String outputPath) async {
    if (item.local) {
      throw Exception('Item is already local');
    }
    final target = File(outputPath);
    await target.parent.create(recursive: true);
    final temp = File('$outputPath.fileshare.part');
    if (await temp.exists()) {
      await temp.delete();
    }
    final sink = temp.openWrite(mode: FileMode.writeOnly);
    try {
      await _streamRemote(item, sink, () => false);
      await sink.flush();
      await sink.close();
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
    }
    notifyListeners();
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
    final payload = jsonEncode({
      'tag': _tag,
      'type': 'presence',
      'id': deviceId,
      'name': deviceName,
      'port': listenPort,
      'revision': revision,
    });
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
      try {
        final map = jsonDecode(utf8.decode(g.data)) as Map<String, dynamic>;
        if (map['tag'] != _tag) continue;
        final type = map['type'] as String?;
        if (type == 'nudge') {
          final id = map['id'] as String?;
          if (id != null) _applyNudgeFrom(id);
          continue;
        }
        if (type == 'probe') {
          final id = map['id'] as String?;
          if (id != null && id != deviceId) {
            _sendPresenceTo(g.address);
          }
        }
        final id = map['id'] as String?;
        final name = map['name'] as String?;
        final port = (map['port'] as num?)?.toInt();
        final rev = (map['revision'] as num?)?.toInt() ?? 0;
        if (id == null || name == null || port == null || id == deviceId) {
          continue;
        }

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
          ..lastSeen = now;

        if (revChanged ||
            now.difference(p.lastFetch) > const Duration(seconds: 3)) {
          unawaited(_fetchManifest(p));
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
        .where((e) => now.difference(e.lastSeen) > _peerPruneAfter)
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

  Future<void> _fetchManifest(Peer p0) async {
    if (p0.fetching) return;
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
        final line = await _readLine(s);
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m['type'] != 'manifest') return;
        final name = m['name'] as String?;
        final list = (m['items'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map((e) {
              final iconBase64 = e['iconPngBase64'] as String?;
              return RemoteItem(
                id: e['id'] as String,
                name: e['name'] as String,
                rel: e['relativePath'] as String,
                size: (e['size'] as num).toInt(),
                iconBytes: iconBase64 == null ? null : base64Decode(iconBase64),
              );
            })
            .toList(growable: false);
        p0.rev = (m['revision'] as num?)?.toInt() ?? p0.rev;
        if (name != null && name.isNotEmpty) {
          p0.name = name;
        }
        p0.lastSeen = DateTime.now();
        final changed = !_sameRemoteItems(p0.items, list);
        if (changed) {
          p0.items
            ..clear()
            ..addAll(list);
        }
        peerStatus[p0.id] = 'OK (${list.length} items)';
        if (changed) {
          notifyListeners();
        }
      } finally {
        await s.close();
      }
    } catch (e) {
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
      jsonEncode({
        'type': 'manifest',
        'clientId': deviceId,
        'clientName': deviceName,
        'clientPort': listenPort,
        'clientRevision': revision,
      }),
    );
    s.write('\n');
    await s.flush();
  }

  void _learnPeerFromRequest(
    InternetAddress remoteAddress,
    Map<String, dynamic> req,
  ) {
    final id = req['clientId'] as String?;
    final name = req['clientName'] as String?;
    final port = (req['clientPort'] as num?)?.toInt();
    final rev = (req['clientRevision'] as num?)?.toInt() ?? 0;
    if (id == null || name == null || port == null || id == deviceId) {
      return;
    }
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
      ),
    );
    _mergeDuplicatePeersFor(id);
    p
      ..name = name
      ..addr = remoteAddress
      ..port = port
      ..rev = rev
      ..lastSeen = now;
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
    _trimTransferHistory();
    _notifyTransferListeners(force: true);
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
      _transfers.remove(finished[i].id);
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
        final line = await _readLine(s);
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m['type'] != 'manifest') {
          return 'Bad response';
        }
        final count = (m['items'] as List<dynamic>? ?? <dynamic>[]).length;
        return 'OK ($count items)';
      } finally {
        await s.close();
      }
    } catch (e) {
      return 'Failed: $e';
    }
  }

  Future<void> _onClient(Socket s) async {
    try {
      final req = jsonDecode(await _readLine(s)) as Map<String, dynamic>;
      _learnPeerFromRequest(s.remoteAddress, req);
      final type = req['type'] as String?;
      if (type == 'nudge') {
        final id = (req['id'] as String?) ?? (req['clientId'] as String?);
        if (id != null) {
          _applyNudgeFrom(id);
        }
        s.write(jsonEncode({'type': 'ok'}));
        s.write('\n');
        await s.flush();
        return;
      }
      if (type == 'manifest') {
        s.write(
          jsonEncode({
            'type': 'manifest',
            'id': deviceId,
            'name': deviceName,
            'revision': revision,
            'items': _local.values.map((e) {
              return {
                'id': e.id,
                'name': e.name,
                'relativePath': e.rel,
                'size': e.size,
                'iconPngBase64': e.iconBytes == null
                    ? null
                    : base64Encode(e.iconBytes!),
              };
            }).toList(),
          }),
        );
        s.write('\n');
        await s.flush();
        return;
      }
      if (type == 'download') {
        final id = req['id'] as String?;
        if (id == null) return;
        final item = _local[id];
        if (item == null) {
          s.write(jsonEncode({'type': 'error', 'message': 'File not found'}));
          s.write('\n');
          await s.flush();
          return;
        }
        final file = File(item.path);
        if (!await file.exists()) {
          s.write(
            jsonEncode({'type': 'error', 'message': 'Source file missing'}),
          );
          s.write('\n');
          await s.flush();
          return;
        }
        s.write(
          jsonEncode({
            'type': 'file',
            'name': item.name,
            'relativePath': item.rel,
            'size': item.size,
          }),
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
    } catch (_) {
    } finally {
      progress.onCancel.removeListener(onCancel);
      sink.close();
    }
  }

  Future<void> _streamRemote(
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
      s.write(jsonEncode({'type': 'download', 'id': it.itemId}));
      s.write('\n');
      await s.flush();
      final h = await _readHeader(s);
      final m = jsonDecode(h.line) as Map<String, dynamic>;
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
          if (n > 0 && !canceled()) {
            sink.add(h.rem.sublist(0, n));
            _addTransferProgress(transferId, n);
          }
          left -= n;
        }
        while (left > 0 && !canceled() && await h.it.moveNext()) {
          final chunk = h.it.current;
          final n = min(left, chunk.length);
          if (n > 0) {
            sink.add(chunk.sublist(0, n));
            _addTransferProgress(transferId, n);
          }
          left -= n;
        }
        if (canceled()) {
          _finishTransfer(transferId, state: TransferState.canceled);
          return;
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
      } catch (e) {
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

Future<File> _windowStateFile() async {
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
  return File(p.join(dir.path, 'window_state.json'));
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
  });

  final String id;
  String name;
  InternetAddress addr;
  int port;
  int rev;
  List<RemoteItem> items;
  DateTime lastSeen;
  bool fetching = false;
  DateTime lastFetch = DateTime.fromMillisecondsSinceEpoch(0);
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
