import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const LoopTrainerApp());

class LoopTrainerApp extends StatelessWidget {
  const LoopTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoopTrainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00C2D1), // cyan
          secondary: Color(0xFFFFB300), // orange A/B
        ),
        useMaterial3: true,
      ),
      home: const HomeTabs(),
    );
  }
}

/// -------------------- NAV 4 onglets --------------------
class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});
  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int index = 0;

  final pages = const [
    PlayerScreen(),
    TunerScreen(),
    MetronomeScreen(),
    SettingsScreen(), // <--- Réglages
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            selectedIcon: Icon(Icons.play_circle_filled),
            label: 'Lecture',
          ),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Accordeur'),
          NavigationDestination(icon: Icon(Icons.av_timer), label: 'Métronome'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Réglages'),
        ],
      ),
    );
  }
}

/// -------------------- LECTEUR --------------------
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Fichier courant
  String? mediaPath;
  bool isVideo = false;

  // Session (prefs)
  SharedPreferences? _prefs;
  static const _kSessionKey = 'looptrainer_session_v1';
  Timer? _autosaveTimer;

  // Players
  VideoPlayerController? _video;
  final _audio = AudioPlayer();
  StreamSubscription<Duration>? _audioPosSub;

  // Boucle A/B
  Duration? a;
  Duration? b;
  bool loopEnabled = false;

  // Vitesse
  double speed = 1.0;

  // ---------- Getters réglages (prefs) ----------
  // Fallback: 4000ms et 12000ms si rien en prefs.
  int get _kDefaultGapMs {
    final v = _prefs?.getInt('loopGapMs');
    return (v == null || v <= 0) ? 4000 : v;
  }

  int get _kZoomWindowMs {
    final v = _prefs?.getInt('zoomWindowMs');
    return (v == null || v <= 0) ? 12000 : v;
  }

  // ---------- cycle de vie ----------
  @override
  void initState() {
    super.initState();
    _initPrefsAndMaybeRestore();
  }

  Future<void> _initPrefsAndMaybeRestore() async {
    _prefs = await SharedPreferences.getInstance();
    await _restoreSession();
    _startAutoSave();
  }

  void _startAutoSave() {
    _autosaveTimer?.cancel();
    _autosaveTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _saveSession());
  }

  @override
  void dispose() {
    _video?.removeListener(_onVideoTick);
    _audioPosSub?.cancel();
    _autosaveTimer?.cancel();
    _video?.dispose();
    _audio.dispose();
    super.dispose();
  }

  // ---------- import / unload ----------
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'mkv', 'mp3', 'wav', 'm4a', 'flac'],
    );
    if (res == null || res.files.single.path == null) return;

    final path = res.files.single.path!;
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    final videoExts = {'mp4', 'mov', 'mkv'};

    await _unload();

    setState(() {
      mediaPath = path;
      isVideo = videoExts.contains(ext);
      a = null;
      b = null;
      loopEnabled = false;
      speed = 1.0;
    });

    if (isVideo) {
      _video = VideoPlayerController.file(File(path));
      await _video!.initialize();
      await _video!.setLooping(false);
      await _video!.setPlaybackSpeed(speed);
      _video!.addListener(_onVideoTick);
      setState(() {});
    } else {
      await _audio.setFilePath(path);
      await _audio.setLoopMode(LoopMode.off);
      await _audio.setSpeed(speed);
      _audioPosSub = _audio.positionStream.listen((_) {
        if (!mounted) return;
        _checkLoopBoundaries();
        setState(() {});
      });
    }

    await _saveSession();
  }

  Future<void> _unload() async {
    _video?.removeListener(_onVideoTick);
    _audioPosSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();
    _video = null;
  }

  // ---------- tick vidéo ----------
  void _onVideoTick() {
    if (!mounted) return;
    _checkLoopBoundaries();
    setState(() {});
  }

  // ---------- getters durée/position ----------
  Duration get _duration {
    if (isVideo) {
      final v = _video;
      if (v == null || !v.value.isInitialized) return Duration.zero;
      return v.value.duration;
    } else {
      return _audio.duration ?? Duration.zero;
    }
  }

  Duration get _position {
    if (isVideo) {
      final v = _video;
      if (v == null || !v.value.isInitialized) return Duration.zero;
      return v.value.position;
    } else {
      return _audio.position;
    }
  }

  // ---------- actions ----------
  Future<void> _seek(Duration pos) async {
    final d = _duration;
    if (d == Duration.zero) return;
    final clamped = pos < Duration.zero ? Duration.zero : (pos > d ? d : pos);
    if (isVideo) {
      await _video?.seekTo(clamped);
    } else {
      await _audio.seek(clamped);
    }
    setState(() {});
    await _saveSession();
  }

  Future<void> _playPause() async {
    if (isVideo) {
      final v = _video;
      if (v == null) return;
      if (v.value.isPlaying) {
        await v.pause();
      } else {
        await v.play();
      }
      setState(() {});
    } else {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        await _audio.play();
      }
      setState(() {});
    }
  }

  Future<void> _setSpeed(double s) async {
    setState(() => speed = s);
    if (isVideo) {
      await _video?.setPlaybackSpeed(s);
    } else {
      await _audio.setSpeed(s);
    }
    await _saveSession();
  }

  // ---------- fenêtre A/B auto : écart FIXE autour du curseur ----------
  void _autoSetFixedGapAroundCursor() {
    final d = _duration;
    if (d == Duration.zero) return;

    final posMs = _position.inMilliseconds;
    final totalMs = d.inMilliseconds;
    final gap = _kDefaultGapMs;

    int aMs = posMs - gap ~/ 2;
    int bMs = posMs + gap ~/ 2;

    // Recaler si on déborde
    if (aMs < 0) {
      bMs -= aMs;
      aMs = 0;
    }
    if (bMs > totalMs) {
      aMs -= (bMs - totalMs);
      bMs = totalMs;
      if (aMs < 0) aMs = 0;
    }

    // Double sécurité
    if (bMs <= aMs) bMs = (aMs + gap).clamp(0, totalMs);
    if (bMs - aMs < gap) {
      bMs = (aMs + gap).clamp(0, totalMs);
      if (bMs == totalMs) aMs = (bMs - gap).clamp(0, totalMs);
    }

    setState(() {
      a = Duration(milliseconds: aMs);
      b = Duration(milliseconds: bMs);
    });
    _saveSession();
  }

  void _setA() {
    setState(() => a = _position);
    _saveSession();
  }

  // B rapide → crée une fenêtre fixe + active la boucle
  void _setBQuick() {
    _autoSetFixedGapAroundCursor();
    setState(() => loopEnabled = true);
    _saveSession();
  }

  void _toggleLoop() {
    if (!loopEnabled) {
      if (a == null || b == null || b! <= a!) {
        _autoSetFixedGapAroundCursor();
      }
      setState(() => loopEnabled = true);
    } else {
      setState(() => loopEnabled = false);
    }
    _saveSession();
  }

  void _clearLoop() {
    setState(() {
      a = null;
      b = null;
      loopEnabled = false;
    });
    _saveSession();
  }

  void _checkLoopBoundaries() {
    if (!loopEnabled) return;
    if (a == null || b == null) return;
    final pos = _position;
    if (pos >= b! || pos < a!) {
      _seek(a!);
    }
  }

  // ---------- sauvegarde / restauration ----------
  Map<String, dynamic> _buildSession() {
    return {
      'mediaPath': mediaPath,
      'isVideo': isVideo,
      'speed': speed,
      'a': a?.inMilliseconds,
      'b': b?.inMilliseconds,
      'loopEnabled': loopEnabled,
      'position': _position.inMilliseconds,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> _saveSession() async {
    if (_prefs == null) return;
    if (mediaPath == null) return;
    final jsonStr = jsonEncode(_buildSession());
    await _prefs!.setString(_kSessionKey, jsonStr);
  }

  Future<void> _restoreSession() async {
    if (_prefs == null) return;
    final str = _prefs!.getString(_kSessionKey);
    if (str == null) return;

    final data = jsonDecode(str) as Map<String, dynamic>;
    final path = data['mediaPath'] as String?;
    if (path == null || !File(path).existsSync()) return;

    final wasVideo = (data['isVideo'] as bool?) ?? false;
    final savedSpeed = (data['speed'] as num?)?.toDouble() ?? 1.0;
    final aMs = data['a'] as int?;
    final bMs = data['b'] as int?;
    final loop = data['loopEnabled'] as bool? ?? false;
    final posMs = data['position'] as int? ?? 0;

    await _unload();

    setState(() {
      mediaPath = path;
      isVideo = wasVideo;
      speed = savedSpeed;
      a = aMs != null ? Duration(milliseconds: aMs) : null;
      b = bMs != null ? Duration(milliseconds: bMs) : null;
      loopEnabled = loop;
    });

    if (isVideo) {
      _video = VideoPlayerController.file(File(path));
      await _video!.initialize();
      await _video!.setLooping(false);
      await _video!.setPlaybackSpeed(speed);
      _video!.addListener(_onVideoTick);
      setState(() {});
    } else {
      await _audio.setFilePath(path);
      await _audio.setLoopMode(LoopMode.off);
      await _audio.setSpeed(speed);
      _audioPosSub = _audio.positionStream.listen((_) {
        if (!mounted) return;
        _checkLoopBoundaries();
        setState(() {});
      });
    }

    await _seek(Duration(milliseconds: posMs));
  }

  // ---------- util ----------
  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // Fenêtre de zoom centrée sur la boucle ou le curseur
  (Duration, Duration) _zoomWindow() {
    final d = _duration;
    if (d == Duration.zero) return (Duration.zero, Duration.zero);
    final totalMs = d.inMilliseconds;
    final centerMs = (a != null && b != null)
        ? ((a!.inMilliseconds + b!.inMilliseconds) ~/ 2)
        : _position.inMilliseconds;

    int start = centerMs - _kZoomWindowMs ~/ 2;
    if (start < 0) start = 0;
    if (start > totalMs - _kZoomWindowMs) {
      start = (totalMs - _kZoomWindowMs).clamp(0, totalMs);
    }
    final end = (start + _kZoomWindowMs).clamp(0, totalMs);
    return (Duration(milliseconds: start), Duration(milliseconds: end));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPlayingNow =
    isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;
    const speedSteps = [0.5, 0.7, 1.0, 1.2, 1.5];

    final (winStart, winEnd) = _zoomWindow();

    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'LoopTrainer',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Importer média',
                  onPressed: _pickFile,
                  icon: const Icon(Icons.file_open),
                ),
              ],
            ),
          ),

          // Zone média
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Builder(
                  builder: (_) {
                    if (mediaPath == null) {
                      return const Text(
                        'Importer une vidéo ou un audio',
                        style: TextStyle(color: Colors.white54),
                      );
                    }
                    if (isVideo) {
                      final v = _video;
                      if (v == null || !v.value.isInitialized) {
                        return const CircularProgressIndicator();
                      }
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio:
                          v.value.aspectRatio == 0 ? 16 / 9 : v.value.aspectRatio,
                          child: VideoPlayer(v),
                        ),
                      );
                    } else {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.audiotrack,
                              size: 72, color: Colors.white30),
                          Text(
                            p.basename(mediaPath!),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      );
                    }
                  },
                ),
              ),
            ),
          ),

          // Seek rapides
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _SeekTextButton(
                  text: '<< 10 S',
                  onTap: () => _seek(_position - const Duration(seconds: 10)),
                ),
                _SeekTextButton(
                  text: '<< 2 S',
                  onTap: () => _seek(_position - const Duration(seconds: 2)),
                ),
                IconButton(
                  iconSize: 36,
                  onPressed: _playPause,
                  icon: Icon(
                    isPlayingNow
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                ),
                _SeekTextButton(
                  text: '2 S >>',
                  onTap: () => _seek(_position + const Duration(seconds: 2)),
                ),
                _SeekTextButton(
                  text: '10 S >>',
                  onTap: () => _seek(_position + const Duration(seconds: 10)),
                ),
              ],
            ),
          ),

          // A / Loop / Reset / B
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ABSmallButton(
                  label: 'A',
                  active: a != null,
                  color: cs.secondary,
                  onPressed: _setA,
                  onLongPress: () => setState(() => a = null),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: loopEnabled ? 'Désactiver la boucle' : 'Activer la boucle',
                      onPressed: _toggleLoop,
                      icon: Icon(Icons.loop, color: loopEnabled ? cs.secondary : Colors.white),
                    ),
                    IconButton(
                      tooltip: 'Réinitialiser A/B',
                      onPressed: _clearLoop,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                _ABSmallButton(
                  label: 'B',
                  active: b != null,
                  color: cs.secondary,
                  onPressed: _setBQuick,
                  onLongPress: () => setState(() => b = null),
                ),
              ],
            ),
          ),

          // Timeline GLOBALE (toute la durée)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: _GlobalTimelineBar(
              duration: _duration,
              position: _position,
              a: a,
              b: b,
              accent: cs.secondary,
              onScrub: (ratio) {
                final d = _duration;
                if (d == Duration.zero) return;
                final targetMs = (d.inMilliseconds * ratio).round();
                _seek(Duration(milliseconds: targetMs));
              },
            ),
          ),

          // Timeline ZOOM (fenêtre réglable via Réglages)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: _ZoomTimelineBar(
              duration: _duration,
              position: _position,
              a: a,
              b: b,
              windowStart: winStart,
              windowEnd: winEnd,
              accent: cs.secondary,
              onScrub: (ratio) {
                final startMs = winStart.inMilliseconds;
                final visMs = (winEnd - winStart).inMilliseconds;
                final targetMs = startMs + (visMs * ratio).round();
                _seek(Duration(milliseconds: targetMs));
              },
              onDragA: (ratio) {
                final startMs = winStart.inMilliseconds;
                final visMs = (winEnd - winStart).inMilliseconds;
                setState(() {
                  a = Duration(milliseconds: startMs + (visMs * ratio).round());
                });
                _saveSession();
              },
              onDragB: (ratio) {
                final startMs = winStart.inMilliseconds;
                final visMs = (winEnd - winStart).inMilliseconds;
                setState(() {
                  b = Duration(milliseconds: startMs + (visMs * ratio).round());
                });
                _saveSession();
              },
            ),
          ),

          // Temps
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('00:00'),
                Text('${_fmt(_position)} / ${_fmt(_duration)}'),
              ],
            ),
          ),

          // Vitesse
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: speed,
                min: 0.5,
                max: 1.5,
                divisions: 20,
                label: '${speed.toStringAsFixed(2)}×',
                onChanged: (v) => _setSpeed(v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekTextButton extends StatelessWidget {
  const _SeekTextButton({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(text, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

class _ABSmallButton extends StatelessWidget {
  const _ABSmallButton({
    required this.label,
    required this.onPressed,
    required this.active,
    required this.color,
    this.onLongPress,
  });

  final String label;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? color : Colors.white,
        side: BorderSide(color: active ? color : Colors.white24, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: const Size(44, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(letterSpacing: 0.5)),
    );
  }
}

/// -------------------- Timeline GLOBALE --------------------
class _GlobalTimelineBar extends StatelessWidget {
  const _GlobalTimelineBar({
    required this.duration,
    required this.position,
    required this.a,
    required this.b,
    required this.accent,
    required this.onScrub,
  });

  final Duration duration;
  final Duration position;
  final Duration? a;
  final Duration? b;
  final Color accent;
  final ValueChanged<double> onScrub; // ratio 0..1

  @override
  Widget build(BuildContext context) {
    final dMs = duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds;
    final p = position.inMilliseconds / dMs;
    final aR = (a?.inMilliseconds ?? 0) / dMs;
    final bR = (b?.inMilliseconds ?? dMs) / dMs;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double dxFromR(double r) => r.clamp(0.0, 1.0) * w;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) => onScrub((e.localPosition.dx / (w == 0 ? 1 : w)).clamp(0.0, 1.0)),
          onHorizontalDragUpdate: (e) => onScrub((e.localPosition.dx / (w == 0 ? 1 : w)).clamp(0.0, 1.0)),
          child: SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                if (a != null && b != null)
                  Positioned(
                    left: dxFromR(aR),
                    right: w - dxFromR(bR),
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Positioned(
                  left: dxFromR(p) - 1,
                  child: Container(width: 2, height: 12, color: Colors.white),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// -------------------- Timeline ZOOM (fenêtre fixe) --------------------
class _ZoomTimelineBar extends StatelessWidget {
  const _ZoomTimelineBar({
    required this.duration,
    required this.position,
    required this.a,
    required this.b,
    required this.windowStart,
    required this.windowEnd,
    required this.accent,
    required this.onScrub,
    required this.onDragA,
    required this.onDragB,
  });

  final Duration duration;
  final Duration position;
  final Duration? a;
  final Duration? b;
  final Duration windowStart;
  final Duration windowEnd;
  final Color accent;

  final ValueChanged<double> onScrub; // 0..1 dans la fenêtre
  final ValueChanged<double> onDragA; // 0..1
  final ValueChanged<double> onDragB; // 0..1

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds;
    final ws = windowStart.inMilliseconds.clamp(0, totalMs);
    final we = windowEnd.inMilliseconds.clamp(0, totalMs);
    final visMs = (we - ws).clamp(1, totalMs);

    double rFromMs(int ms) => ((ms - ws) / visMs).clamp(0.0, 1.0);
    final pR = rFromMs(position.inMilliseconds);
    final aR = a != null ? rFromMs(a!.inMilliseconds) : null;
    final bR = b != null ? rFromMs(b!.inMilliseconds) : null;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double dx(double r) => r.clamp(0.0, 1.0) * w;

        void _scrubAt(double x) =>
            onScrub(((x.clamp(0, w)) / (w == 0 ? 1 : w)).clamp(0.0, 1.0));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) => _scrubAt(e.localPosition.dx),
          onHorizontalDragUpdate: (e) => _scrubAt(e.localPosition.dx),
          child: SizedBox(
            height: 42,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                if (aR != null && bR != null)
                  Positioned(
                    left: dx(aR),
                    right: w - dx(bR),
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                Positioned(
                  left: dx(pR) - 1,
                  child: Container(width: 2, height: 16, color: Colors.white),
                ),
                if (aR != null)
                  _Handle(dx: dx(aR), color: accent, onDrag: (newDx) {
                    final r = ((newDx.clamp(0, w)) / (w == 0 ? 1 : w)).clamp(0.0, 1.0);
                    onDragA(r);
                  }),
                if (bR != null)
                  _Handle(dx: dx(bR), color: accent, onDrag: (newDx) {
                    final r = ((newDx.clamp(0, w)) / (w == 0 ? 1 : w)).clamp(0.0, 1.0);
                    onDragB(r);
                  }),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.dx, required this.color, required this.onDrag});
  final double dx;
  final Color color;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: dx - 8,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) => onDrag(dx + d.delta.dx),
        child: Container(
          width: 16,
          height: 24,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

/// -------------------- Placeholders --------------------
class TunerScreen extends StatelessWidget {
  const TunerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text('Accordeur (à venir)',
            style: TextStyle(fontSize: 16, color: Colors.white70)),
      ),
    );
  }
}

class MetronomeScreen extends StatelessWidget {
  const MetronomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text('Métronome (à venir)',
            style: TextStyle(fontSize: 16, color: Colors.white70)),
      ),
    );
  }
}

// --------------------------------------
// Réglages (⚙️ onglet) — prefs persistées
// --------------------------------------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SharedPreferences? _prefs;

  static const _defaultLoopGapMs = 4000;
  static const _defaultZoomWindowMs = 12000;

  int loopGapMs = _defaultLoopGapMs;
  int zoomWindowMs = _defaultZoomWindowMs;

  final loopOptions = const [3000, 4000, 6000, 8000, 10000];
  final zoomOptions = const [10000, 12000, 15000, 20000, 30000];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      loopGapMs = _prefs!.getInt('loopGapMs') ?? _defaultLoopGapMs;
      zoomWindowMs = _prefs!.getInt('zoomWindowMs') ?? _defaultZoomWindowMs;
    });
  }

  Future<void> _savePrefs() async {
    if (_prefs == null) return;
    await _prefs!.setInt('loopGapMs', loopGapMs);
    await _prefs!.setInt('zoomWindowMs', zoomWindowMs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Durée par défaut de la boucle',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButton<int>(
            value: loopGapMs,
            isExpanded: true,
            items: loopOptions
                .map((ms) => DropdownMenuItem(
              value: ms,
              child: Text('${ms ~/ 1000} secondes'),
            ))
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              setState(() => loopGapMs = v);
              _savePrefs();
            },
          ),
          const SizedBox(height: 24),
          const Text('Fenêtre zoom (timeline détaillée)',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButton<int>(
            value: zoomWindowMs,
            isExpanded: true,
            items: zoomOptions
                .map((ms) => DropdownMenuItem(
              value: ms,
              child: Text('${ms ~/ 1000} secondes'),
            ))
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              setState(() => zoomWindowMs = v);
              _savePrefs();
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Ces réglages s’appliquent quand tu crées une nouvelle boucle '
                '(B rapide ou activation de la boucle si A/B vides).',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
