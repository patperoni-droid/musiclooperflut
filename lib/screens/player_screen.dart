// lib/screens/player_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

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

  // Ticker pour gérer le rebouclage
  Timer? _ticker;

  // Ecart par défaut pour la pose rapide de boucle via B
  static const Duration _kQuickGap = Duration(seconds: 4);

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
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  // ------------------ Fichier ------------------
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        // vidéo
        'mp4', 'mov', 'm4v', 'webm',
        // audio
        'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg',
      ],
    );
    if (res == null || res.files.isEmpty) return;
    final p = res.files.single.path;
    if (p == null) return;

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
    // Stop & reset
    _ticker?.cancel();
    _audioPosSub?.cancel();
    await _audio.stop();
    _video?.removeListener(_onVideoTick);
    await _video?.pause();
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

      _duration = c.value.duration;
      c.addListener(_onVideoTick);

      _startTicker();
      setState(() {});
    } else {
      await _audio.setFilePath(_path!);
      await _audio.setSpeed(_speed);
      // force un pitch neutre si dispo
      try {
        await _audio.setPitch(1.0);
      } catch (_) {}
      _duration = _audio.duration ?? Duration.zero;

      _audioPosSub = _audio.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      });

      _startTicker();
      setState(() {});
    }
  }

  // ------------------ Lecture / Seek ------------------
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
    if (_duration == Duration.zero) return;
    d = _clampDur(d, Duration.zero, _duration);
    if (_isVideo) {
      await _video?.seekTo(d);
    } else {
      await _audio.seek(d);
    }
    setState(() => _position = d);
  }

  Future<void> _seekRel(Duration delta) => _seek(_position + delta);

  // ------------------ Vitesse ------------------
  Future<void> _setSpeed(double s) async {
    _speed = s;
    if (_isVideo) {
      await _video?.setPlaybackSpeed(s);
    } else {
      try {
        await _audio.setPitch(1.0);
      } catch (_) {}
      await _audio.setSpeed(s);
    }
    setState(() {});
  }

  // ------------------ Boucle A/B ------------------
  void _markA() {
    if (_duration == Duration.zero) return;
    setState(() => _a = _position);
  }

  void _markBAndAutoLoop() {
    if (_duration == Duration.zero) return;

    final b = _position;
    // calcule A = B - 4s, borné à 0
    final aCandidate = b - _kQuickGap;
    final a = _clampDur(aCandidate, Duration.zero, _duration);

    setState(() {
      _a = a;
      _b = b;
      _loopEnabled = true; // active la boucle immédiatement
    });
  }

  void _toggleLoop() {
    // petit toggle pour couper/réactiver la boucle sans perdre A/B
    if (_a == null || _b == null || _b! <= _a!) {
      // si A/B pas valides, on crée une fenêtre rapide autour du curseur
      final half = Duration(milliseconds: _kQuickGap.inMilliseconds ~/ 2);
      final a = _clampDur(_position - half, Duration.zero, _duration);
      var b = _clampDur(_position + half, Duration.zero, _duration);
      if (b <= a) b = _clampDur(a + _kQuickGap, Duration.zero, _duration);
      setState(() {
        _a = a;
        _b = b;
        _loopEnabled = true;
      });
    } else {
      setState(() => _loopEnabled = !_loopEnabled);
    }
  }

  void _clearLoop() {
    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
    });
  }

  // ------------------ Ticker / callbacks ------------------
  void _onVideoTick() {
    final v = _video;
    if (v == null) return;
    final pos = v.value.position;
    if (!mounted) return;
    setState(() => _position = pos);
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!_loopEnabled || _a == null || _b == null) return;
      final a = _a!;
      final b = _b!;
      if (b <= a) return;

      final pos = _position;
      if (pos >= b - const Duration(milliseconds: 40)) {
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

  // ------------------ UI helpers ------------------
  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying =
    _isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('MusicLooper'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Ouvrir un fichier',
            onPressed: _pickFile,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Média (vidéo plein écran, sinon fond noir)
            Positioned.fill(child: _buildMedia()),

            // Panneau bas (contrôles minimalistes)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomPanel(isPlaying),
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
    return Container(color: Colors.black);
  }

  Widget _buildBottomPanel(bool isPlaying) {
    final durMs =
    _duration.inMilliseconds.toDouble().clamp(0.0, double.infinity);
    final posMs = _position.inMilliseconds.toDouble().clamp(0.0, durMs);
    final aMs =
    (_a?.inMilliseconds.toDouble() ?? 0.0).clamp(0.0, durMs);
    final bMs =
    (_b?.inMilliseconds.toDouble() ?? (durMs > 0 ? durMs : 0.0))
        .clamp(0.0, durMs);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(0, -1),
          end: Alignment(0, 1),
          colors: [Colors.transparent, Color.fromARGB(210, 0, 0, 0)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barre de progression fine (seek)
          _buildPositionSlider(durMs, posMs),

          const SizedBox(height: 8),

          // Slider A/B (poignées)
          _buildLoopSlider(durMs, aMs, bMs),

          const SizedBox(height: 8),

          // Vitesse
          _buildSpeedRow(),

          const SizedBox(height: 8),

          // Contrôles + A/B rapides
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
                ? (v) => setState(
                    () => _position = Duration(milliseconds: v.toInt()))
                : null,
            onChangeEnd: enabled
                ? (v) => _seek(Duration(milliseconds: v.toInt()))
                : null,
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

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        rangeThumbShape:
        const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
        thumbColor: Colors.amber,
        activeTrackColor: Colors.amber,
        inactiveTrackColor: Colors.white24,
      ),
      child: RangeSlider(
        values: RangeValues(
          enabled ? (aMs / (durMs == 0 ? 1 : durMs)) : 0.0,
          enabled ? (bMs / (durMs == 0 ? 1 : durMs)) : 1.0,
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

    // Styles A/B selon état de la boucle
    final abOffBg = Colors.white10;
    final abOnBg  = Colors.amber.shade700;
    final abFgOff = Colors.white70;
    final abFgOn  = Colors.black;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Retour 5s
        IconButton.filledTonal(
          style: btnStyle,
          onPressed: _duration == Duration.zero
              ? null
              : () => _seekRel(const Duration(seconds: -5)),
          icon: const Icon(Icons.replay_5),
        ),
        const SizedBox(width: 8),

        // Play / Pause
        IconButton.filled(
          style: btnStyle,
          onPressed: _duration == Duration.zero ? null : _playPause,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        const SizedBox(width: 8),

        // Avance 5s
        IconButton.filledTonal(
          style: btnStyle,
          onPressed: _duration == Duration.zero
              ? null
              : () => _seekRel(const Duration(seconds: 5)),
          icon: const Icon(Icons.forward_5),
        ),
        const SizedBox(width: 12),

        // Bouton A (pose A = position)
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: _loopEnabled ? abOnBg : abOffBg,
            foregroundColor: _loopEnabled ? abFgOn : abFgOff,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          onPressed: _duration == Duration.zero ? null : _markA,
          child: const Text('A'),
        ),
        const SizedBox(width: 8),

        // Bouton B (pose B = now, A = B-4s, active boucle)
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: _loopEnabled ? abOnBg : abOffBg,
            foregroundColor: _loopEnabled ? abFgOn : abFgOff,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          onPressed: _duration == Duration.zero ? null : _markBAndAutoLoop,
          child: const Text('B'),
        ),
        const SizedBox(width: 12),

        // Toggle boucle (🔁) on/off sans perdre A/B
        IconButton(
          tooltip: _loopEnabled ? 'Boucle ON' : 'Boucle OFF',
          onPressed: (_a != null && _b != null) ? _toggleLoop : null,
          icon: Icon(
            Icons.repeat,
            color: _loopEnabled ? Colors.amber : Colors.white70,
          ),
        ),

        // Effacer A/B
        IconButton(
          tooltip: 'Effacer A/B',
          onPressed: (_a != null || _b != null) ? _clearLoop : null,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}