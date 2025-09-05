// lib/screens/player_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:just_audio/just_audio.dart';

// --- helpers ---
Duration _clampDur(Duration d, Duration min, Duration max) {
  if (d < min) return min;
  if (d > max) return max;
  return d;
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Media
  String? _path;
  bool _isVideo = false;

  // Players
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _audioPosSub;

  // Durations
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // Loop A/B
  Duration? _a;
  Duration? _b;
  bool _loopEnabled = false;

  // Speed
  double _speed = 1.0;

  // Ticker pour la boucle (vidéo)
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _audioPosSub?.cancel();
    _audio.dispose();
    _video?.dispose();
    super.dispose();
  }

  // --- Chargement d’un fichier ---
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'm4v', 'mp3', 'wav', 'aac', 'm4a'],
    );
    if (res == null || res.files.isEmpty) return;

    final p = res.files.single.path!;
    _path = p;
    _isVideo = _isVideoExt(p);

    await _loadMedia();
  }

  bool _isVideoExt(String p) {
    final lower = p.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm');
  }

  Future<void> _loadMedia() async {
    _ticker?.cancel();
    _audioPosSub?.cancel();
    await _audio.stop();
    await _video?.dispose();
    _video = null;

    setState(() {
      _duration = Duration.zero;
      _position = Duration.zero;
      _a = null;
      _b = null;
      _loopEnabled = false;
    });

    if (_path == null) return;

    if (_isVideo) {
      final c = VideoPlayerController.file(File(_path!));
      await c.initialize();
      await c.setLooping(false);
      await c.setPlaybackSpeed(_speed);
      _video = c;

      // Durée
      _duration = c.value.duration;

      // Position listener
      c.addListener(() {
        final pos = c.value.position;
        if (mounted) {
          setState(() => _position = pos);
        }
      });

      _startTicker();
      setState(() {});
    } else {
      await _audio.setFilePath(_path!);
      await _audio.setSpeed(_speed);
      await _audio.setPitch(1.0); // tonalité inchangée
      _duration = _audio.duration ?? Duration.zero;

      _audioPosSub = _audio.positionStream.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });

      _startTicker();
      setState(() {});
    }
  }

  // --- Lecture / Pause / Seek ---
  Future<void> _playPause() async {
    if (_isVideo) {
      final c = _video;
      if (c == null) return;
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        await c.play();
      }
    } else {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        await _audio.play();
      }
    }
    setState(() {});
  }

  Future<void> _seek(Duration d) async {
    d = _clampDur(d, Duration.zero, _duration);
    if (_isVideo) {
      await _video?.seekTo(d);
    } else {
      await _audio.seek(d);
    }
  }

  // --- Speed ---
  Future<void> _setSpeed(double s) async {
    _speed = s;
    if (_isVideo) {
      await _video?.setPlaybackSpeed(s);
    } else {
      await _audio.setPitch(1.0);
      await _audio.setSpeed(s);
    }
    setState(() {});
  }

  // --- Ticker: gère la boucle A/B ---
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (!_loopEnabled) return;
      if (_a == null || _b == null) return;
      final a = _a!;
      final b = _b!;
      if (b <= a) return;

      final pos = _position;
      // Si on dépasse B de ~60ms, on revient à A
      if (pos >= b - const Duration(milliseconds: 60)) {
        await _seek(a);
        if (_isVideo) {
          if (!(_video?.value.isPlaying ?? false)) {
            await _video?.play();
          }
        } else {
          if (!_audio.playing) await _audio.play();
        }
      }
    });
  }

  // --- Helpers format ---
  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  // --- UI ---
  @override
  Widget build(BuildContext context) {
    final isPlaying =
    _isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Zone média
            Positioned.fill(
              child: _buildMedia(),
            ),

            // Panneau bas semi-transparent
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomPanel(isPlaying),
            ),

            // Bouton "Ouvrir" si rien chargé
            if (_path == null)
              Positioned.fill(
                child: Center(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.1),
                      padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    ),
                    onPressed: _pickFile,
                    child: const Text('Ouvrir un fichier',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia() {
    if (_isVideo && _video != null && _video!.value.isInitialized) {
      final ar = _video!.value.aspectRatio;
      return Center(
        child: AspectRatio(
          aspectRatio: ar == 0 ? 16 / 9 : ar,
          child: VideoPlayer(_video!),
        ),
      );
    }
    // Audio ou rien : fond neutre
    return Container(color: Colors.black);
  }

  Widget _buildBottomPanel(bool isPlaying) {
    final durMs = _duration.inMilliseconds.toDouble().clamp(0.0, double.infinity);
    final posMs = _position.inMilliseconds.toDouble().clamp(0.0, durMs);

    final aMs = (_a?.inMilliseconds.toDouble() ?? 0.0).clamp(0.0, durMs);
    final bMs =
    (_b?.inMilliseconds.toDouble() ?? (durMs > 0 ? durMs : 0.0)).clamp(0.0, durMs);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(0, -1),
          end: Alignment(0, 1),
          colors: [Colors.transparent, Color.fromARGB(200, 0, 0, 0)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barre de progression fine (position seule)
          _buildPositionSlider(durMs, posMs),

          const SizedBox(height: 8),

          // Slider A/B (poignées de boucle)
          _buildLoopSlider(durMs, aMs, bMs),

          const SizedBox(height: 8),

          // Vitesse
          _buildSpeedRow(),

          const SizedBox(height: 8),

          // Contrôles
          _buildControlsRow(isPlaying),
        ],
      ),
    );
  }

  // --- Widgets détaillés ---

  Widget _buildPositionSlider(double durMs, double posMs) {
    final enabled = durMs > 0;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: enabled ? posMs : 0,
            min: 0,
            max: durMs > 0 ? durMs : 1,
            onChanged: enabled
                ? (v) => setState(() => _position = Duration(milliseconds: v.toInt()))
                : null,
            onChangeEnd: enabled ? (v) => _seek(Duration(milliseconds: v.toInt())) : null,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_fmt(_position), style: const TextStyle(color: Colors.white70)),
            Text(_fmt(_duration), style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ],
    );
  }

  Widget _buildLoopSlider(double durMs, double aMs, double bMs) {
    final enabled = durMs > 0;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
            thumbColor: Colors.amber,
            activeTrackColor: Colors.amber,
            inactiveTrackColor: Colors.white24,
          ),
          child: RangeSlider(
            values: RangeValues(
              enabled ? aMs / (durMs == 0 ? 1 : durMs) : 0.0,
              enabled ? bMs / (durMs == 0 ? 1 : durMs) : 1.0,
            ),
            onChanged: !enabled
                ? null
                : (rv) {
              final na = Duration(milliseconds: (rv.start * durMs).toInt());
              final nb = Duration(milliseconds: (rv.end * durMs).toInt());
              setState(() {
                _a = na;
                _b = nb;
              });
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('A: ${_a == null ? '--:--' : _fmt(_a!)}',
                style: const TextStyle(color: Colors.white70)),
            Text('B: ${_b == null ? '--:--' : _fmt(_b!)}',
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ],
    );
  }

  Widget _buildSpeedRow() {
    return Row(
      children: [
        const Icon(Icons.speed, size: 18, color: Colors.white70),
        Expanded(
          child: Slider(
            value: _speed,
            min: 0.5,
            max: 1.5,
            divisions: 10,
            label: '${_speed.toStringAsFixed(2)}×',
            onChanged: (v) => _setSpeed(v),
          ),
        ),
        Text('${_speed.toStringAsFixed(2)}×',
            style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  Widget _buildControlsRow(bool isPlaying) {
    final btnStyle = IconButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white24,
      iconSize: 28,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.filledTonal(
          style: btnStyle,
          onPressed: _duration == Duration.zero
              ? null
              : () {
            final back = _position - const Duration(seconds: 5);
            _seek(back);
          },
          icon: const Icon(Icons.replay_5),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          style: btnStyle,
          onPressed: _duration == Duration.zero ? null : _playPause,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          style: btnStyle,
          onPressed: _duration == Duration.zero
              ? null
              : () {
            final fwd = _position + const Duration(seconds: 5);
            _seek(fwd);
          },
          icon: const Icon(Icons.forward_5),
        ),
        const SizedBox(width: 16),
        FilterChip(
          selectedColor: Colors.amber.shade700,
          checkmarkColor: Colors.white,
          label: const Text('A↻B', style: TextStyle(color: Colors.white)),
          selected: _loopEnabled,
          onSelected: (v) => setState(() => _loopEnabled = v),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: _pickFile,
          child: const Text('Ouvrir'),
        ),
      ],
    );
  }
}