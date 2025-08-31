import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
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

/// -------------------- NAV 3 onglets --------------------
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

  @override
  void dispose() {
    _video?.removeListener(_onVideoTick);
    _audioPosSub?.cancel();
    _video?.dispose();
    _audio.dispose();
    super.dispose();
  }

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
      _video!.addListener(_onVideoTick); // avance timeline + check loop
      setState(() {});
    } else {
      await _audio.setFilePath(path);
      await _audio.setLoopMode(LoopMode.off);
      await _audio.setSpeed(speed);
      _audioPosSub = _audio.positionStream.listen((_) {
        if (!mounted) return;
        _checkLoopBoundaries();
        setState(() {}); // avance timeline
      });
    }
  }

  Future<void> _unload() async {
    _video?.removeListener(_onVideoTick);
    _audioPosSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();
    _video = null;
  }

  void _onVideoTick() {
    if (!mounted) return;
    _checkLoopBoundaries();
    setState(() {}); // avance timeline
  }

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

  Future<void> _seek(Duration pos) async {
    final d = _duration;
    if (d == Duration.zero) return;
    final clamped =
    pos < Duration.zero ? Duration.zero : (pos > d ? d : pos);
    if (isVideo) {
      await _video?.seekTo(clamped);
    } else {
      await _audio.seek(clamped);
    }
    setState(() {});
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
  }

  void _setA() => setState(() => a = _position);

  void _setBQuick() {
    final pos = _position;
    setState(() {
      b = pos;
      a = pos - const Duration(seconds: 4);
      if (a!.isNegative) a = Duration.zero;
      loopEnabled = true;
    });
  }

  void _toggleLoop() => setState(() => loopEnabled = !loopEnabled);

  void _clearLoop() {
    setState(() {
      a = null;
      b = null;
      loopEnabled = false;
    });
  }

  /// Vérifie les bornes A/B uniquement si la boucle est activée
  void _checkLoopBoundaries() {
    if (!loopEnabled) return;
    if (a == null || b == null) return;

    final pos = _position;
    if (pos >= b! || pos < a!) {
      _seek(a!);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPlayingNow =
    isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;
    const speedSteps = [0.5, 0.7, 1.0, 1.2, 1.5];

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

          // Zone vidéo / audio
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
                  onLongPress: () => setState(() => a = null), // efface A
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: loopEnabled
                          ? 'Désactiver la boucle'
                          : 'Activer la boucle',
                      onPressed: _toggleLoop,
                      icon: Icon(
                        Icons.loop,
                        color: loopEnabled ? cs.secondary : Colors.white,
                      ),
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
                  onLongPress: () => setState(() => b = null), // efface B
                ),
              ],
            ),
          ),

          // Timeline
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: _TimelineBar(
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
              onDragA: (ratio) {
                final d = _duration;
                if (d == Duration.zero) return;
                setState(() => a =
                    Duration(milliseconds: (d.inMilliseconds * ratio).round()));
              },
              onDragB: (ratio) {
                final d = _duration;
                if (d == Duration.zero) return;
                setState(() => b =
                    Duration(milliseconds: (d.inMilliseconds * ratio).round()));
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
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: speedSteps.map((v) {
                    final selected = (speed - v).abs() < 0.025;
                    return GestureDetector(
                      onTap: () => _setSpeed(v),
                      child: Text(
                        v == 1.0 ? '1×' : '${v.toStringAsFixed(1)}×',
                        style: TextStyle(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white70,
                          fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
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

/// -------------------- Timeline simple (scrubbable) --------------------
class _TimelineBar extends StatefulWidget {
  const _TimelineBar({
    required this.duration,
    required this.position,
    required this.a,
    required this.b,
    required this.accent,
    required this.onScrub,
    required this.onDragA,
    required this.onDragB,
  });

  final Duration duration;
  final Duration position;
  final Duration? a;
  final Duration? b;
  final Color accent;

  /// 0..1
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onDragA;
  final ValueChanged<double> onDragB;

  @override
  State<_TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends State<_TimelineBar> {
  final GlobalKey _key = GlobalKey();

  double _ratioFromDx(double dx) {
    final box = _key.currentContext!.findRenderObject() as RenderBox;
    final w = box.size.width;
    return (dx.clamp(0, w)) / w;
  }

  double _width() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.width ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final dMs =
    widget.duration.inMilliseconds == 0 ? 1 : widget.duration.inMilliseconds;
    final p = widget.position.inMilliseconds / dMs;
    final a = (widget.a?.inMilliseconds ?? 0) / dMs;
    final b = (widget.b?.inMilliseconds ?? dMs) / dMs;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (e) => widget.onScrub(_ratioFromDx(e.localPosition.dx)),
      onHorizontalDragUpdate: (e) =>
          widget.onScrub(_ratioFromDx(e.localPosition.dx)),
      child: SizedBox(
        height: 42,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              key: _key,
              height: 6,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Positioned.fill(
              left: a * _width(),
              right: (1 - b) * _width(),
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  color: widget.accent.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Positioned(
              left: p * _width() - 1,
              child: Container(width: 2, height: 16, color: Colors.white),
            ),
            if (widget.a != null)
              _Handle(
                dx: a * _width(),
                color: widget.accent,
                onDrag: (dx) => widget.onDragA(_ratioFromDx(dx)),
              ),
            if (widget.b != null)
              _Handle(
                dx: b * _width(),
                color: widget.accent,
                onDrag: (dx) => widget.onDragB(_ratioFromDx(dx)),
              ),
          ],
        ),
      ),
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
