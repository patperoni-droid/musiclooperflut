import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // ----------- Session / prefs -----------
  SharedPreferences? _prefs;
  static const _kSessionKey = 'player_session_v1';

  // ----------- Média -----------
  String? _mediaPath; // chemin du fichier chargé
  bool _isVideo = false;
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();

  // ----------- Transport -----------
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool get _isPlaying => _isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;

  // ----------- Boucle A/B -----------
  Duration? _a;
  Duration? _b;
  bool _loop = false;

  // Écart par défaut pour la boucle rapide (4 s)
  static const int _kQuickLoopMs = 4000;

  // ----------- Vitesse -----------
  double _speed = 1.0; // 0.25→2.0

  // ----------- Ticker UI -----------
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _restoreSession();
    _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    _audio.dispose();
    super.dispose();
  }

  // -------------------- Utils temps --------------------
  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Duration _clampDur(Duration d, Duration min, Duration max) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }

  // -------------------- Ouverture média --------------------
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        // vidéo
        'mp4','mov','m4v','webm','mkv',
        // audio
        'mp3','m4a','aac','wav','flac','ogg'
      ],
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    await _open(path);
  }

  Future<void> _open(String path) async {
    // stop précédent
    await _stop();

    _mediaPath = path;
    _isVideo = _isLikelyVideo(path);

    if (_isVideo) {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      c.setLooping(false);
      _video = c;
      _duration = c.value.duration;
      c.addListener(_onVideoTick);
      setState(() {});
    } else {
      await _audio.setFilePath(path);
      _duration = _audio.duration ?? Duration.zero;
      _audio.positionStream.listen((pos) async {
        _position = pos;
        if (_loop && _a != null && _b != null && pos >= _b!) {
          await _audio.seek(_a!);
        }
        if (mounted) setState(() {});
      });
      setState(() {});
    }
    await _applySpeed(_speed);
    await _saveSession();
  }

  bool _isLikelyVideo(String path) {
    final ext = p.extension(path).toLowerCase();
    const vids = ['.mp4','.mov','.m4v','.webm','.mkv'];
    return vids.contains(ext);
  }

  // -------------------- Lecture / Seek --------------------
  Future<void> _togglePlay() async {
    if (_isVideo) {
      if (_video == null) return;
      if (_video!.value.isPlaying) {
        await _video!.pause();
      } else {
        await _video!.play();
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
    _position = d;
    setState(() {});
  }

  Future<void> _seekRel(Duration delta) => _seek(_position + delta);

  Future<void> _stop() async {
    if (_isVideo) {
      await _video?.pause();
      _video?.removeListener(_onVideoTick);
      await _video?.dispose();
      _video = null;
    } else {
      await _audio.stop();
    }
    _position = Duration.zero;
    _duration = Duration.zero;
    _a = null;
    _b = null;
    _loop = false;
    setState(() {});
  }

  // -------------------- Vitesse --------------------
  Future<void> _applySpeed(double v) async {
    _speed = v;
    if (_isVideo) {
      await _video?.setPlaybackSpeed(v); // pas de pitch-preserving sur video_player
    } else {
      await _audio.setSpeed(v);          // just_audio conserve le pitch sur Android
      try { await _audio.setPitch(1.0); } catch (_) {}
    }
    setState(() {});
    await _saveSession();
  }

  // -------------------- Boucle A/B --------------------
  void _quickLoopAroundCursor() {
    if (_duration == Duration.zero) return;
    final half = Duration(milliseconds: _kQuickLoopMs ~/ 2);
    var a = _position - half;
    var b = _position + half;
    a = _clampDur(a, Duration.zero, _duration);
    b = _clampDur(b, Duration.zero, _duration);
    if (b <= a) b = _clampDur(a + const Duration(milliseconds: _kQuickLoopMs), Duration.zero, _duration);
    setState(() { _a = a; _b = b; _loop = true; });
  }

  Future<void> _nudgeA(int ms) async {
    if (_a == null) return;
    final nd = _clampDur(_a! + Duration(milliseconds: ms), Duration.zero, _b ?? _duration);
    setState(() => _a = nd);
  }

  Future<void> _nudgeB(int ms) async {
    if (_b == null) return;
    final nd = _clampDur(_b! + Duration(milliseconds: ms), _a ?? Duration.zero, _duration);
    setState(() => _b = nd);
  }

  void _toggleLoop() {
    if (_loop) {
      setState(() => _loop = false);
    } else {
      if (_a == null || _b == null || _b! <= _a!) {
        _quickLoopAroundCursor();
      } else {
        setState(() => _loop = true);
      }
    }
  }

  // -------------------- Ticker / callbacks --------------------
  void _onVideoTick() {
    final v = _video;
    if (v == null) return;
    _position = v.value.position;
    if (_loop && _a != null && _b != null && _position >= _b!) {
      v.seekTo(_a!);
    }
    if (mounted) setState(() {});
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (_isVideo) {
        // position déjà suivie par _onVideoTick
      } else {
        // audio -> positionStream déjà branché
      }
      if (mounted) setState(() {});
    });
  }

  // -------------------- Session --------------------
  Future<void> _restoreSession() async {
    _prefs ??= await SharedPreferences.getInstance();
    final s = _prefs!.getString(_kSessionKey);
    if (s == null) return;
    final parts = s.split('|'); // path|speed
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      final path = parts[0];
      if (File(path).existsSync()) {
        await _open(path);
      }
    }
    if (parts.length > 1) {
      final sp = double.tryParse(parts[1]);
      if (sp != null) await _applySpeed(sp);
    }
  }

  Future<void> _saveSession() async {
    _prefs ??= await SharedPreferences.getInstance();
    final path = _mediaPath ?? '';
    await _prefs!.setString(_kSessionKey, '$path|$_speed');
  }

  // -------------------- Timeline --------------------
  static const double _tlHeight = 36;
  static const double _handleW = 14;
  static const double _playheadW = 2;

  double _xFromDur(Duration d, double width) {
    if (_duration == Duration.zero) return 0;
    final r = d.inMilliseconds / _duration.inMilliseconds;
    return (r.clamp(0.0, 1.0)) * width;
  }

  Duration _durFromX(double x, double width) {
    if (width <= 0 || _duration == Duration.zero) return Duration.zero;
    final r = (x / width).clamp(0.0, 1.0);
    final ms = (r * _duration.inMilliseconds).round();
    return Duration(milliseconds: ms);
  }

  Widget _handle(Color color) => Container(
    width: _handleW,
    height: _tlHeight,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );

  Widget _timeline(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final aX = _a != null ? _xFromDur(_a!, w) : null;
      final bX = _b != null ? _xFromDur(_b!, w) : null;
      final pX = _xFromDur(_position, w);

      return SizedBox(
        height: _tlHeight + 22,
        child: Column(
          children: [
            SizedBox(
              height: _tlHeight,
              child: Stack(
                children: [
                  // fond
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade700,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),

                  // zone de boucle
                  if (aX != null && bX != null && aX < bX)
                    Positioned(
                      left: aX,
                      width: (bX - aX).clamp(0, w),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),

                  // poignée A
                  if (aX != null)
                    Positioned(
                      left: (aX - _handleW / 2).clamp(0, math.max(0, w - _handleW)),
                      top: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: (d) {
                          final nx = (aX + d.delta.dx).clamp(0.0, w);
                          final nd = _durFromX(nx, w);
                          if (_b != null && nd > _b!) return;
                          setState(() => _a = nd);
                        },
                        onDoubleTap: () => setState(() => _a = null),
                        child: _handle(Colors.orange),
                      ),
                    ),

                  // poignée B
                  if (bX != null)
                    Positioned(
                      left: (bX - _handleW / 2).clamp(0, math.max(0, w - _handleW)),
                      top: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: (d) {
                          final nx = (bX + d.delta.dx).clamp(0.0, w);
                          final nd = _durFromX(nx, w);
                          if (_a != null && nd < _a!) return;
                          setState(() => _b = nd);
                        },
                        onDoubleTap: () => setState(() => _b = null),
                        child: _handle(Colors.orange),
                      ),
                    ),

                  // playhead
                  Positioned(
                    left: (pX - _playheadW / 2).clamp(0, math.max(0, w - _playheadW)),
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragUpdate: (d) {
                        final nx = (pX + d.delta.dx).clamp(0.0, w);
                        final nd = _durFromX(nx, w);
                        _seek(nd);
                      },
                      onTapDown: (t) {
                        final nd = _durFromX(t.localPosition.dx, w);
                        _seek(nd);
                      },
                      child: Container(width: _playheadW, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            // repères
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(Duration.zero), style: const TextStyle(fontSize: 12)),
                  Text(_fmt(_position), style: const TextStyle(fontSize: 12)),
                  Text(_fmt(_duration), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  // -------------------- UI --------------------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ready = _duration > Duration.zero;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecture'),
        actions: [
          IconButton(
            tooltip: 'Ouvrir',
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
          ),
          if (_mediaPath != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  p.basename(_mediaPath!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // viewport vidéo (ou pictogramme audio)
            AspectRatio(
              aspectRatio: _isVideo ? (_video?.value.aspectRatio ?? 16/9) : 16/9,
              child: Container(
                color: Colors.black,
                child: _isVideo
                    ? (_video != null && _video!.value.isInitialized
                    ? VideoPlayer(_video!)
                    : const Center(child: CircularProgressIndicator()))
                    : const Center(child: Icon(Icons.music_note, size: 72, color: Colors.white)),
              ),
            ),

            // timeline
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: _timeline(context),
            ),

            // seek rapides
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SeekBtn(label: '≪ 2s', onTap: () => _seekRel(const Duration(seconds: -2))),
                  _SeekBtn(label: '≪ 10s', onTap: () => _seekRel(const Duration(seconds: -10))),
                  _SeekBtn(label: '10s ≫', onTap: () => _seekRel(const Duration(seconds: 10))),
                  _SeekBtn(label: '2s ≫', onTap: () => _seekRel(const Duration(seconds: 2))),
                ],
              ),
            ),

            // A/B + loop
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton(
                    onPressed: ready ? () => setState(() => _a = _position) : null,
                    child: Text("A ${_a == null ? '--:--' : _fmt(_a!)}"),
                  ),
                  const SizedBox(width: 10),
                  Row(
                    children: [
                      _Mini(label: 'A-0.1', onTap: () => _nudgeA(-100)),
                      const SizedBox(width: 6),
                      _Mini(label: 'A+0.1', onTap: () => _nudgeA(100)),
                      const SizedBox(width: 6),
                      _Mini(label: 'A-1', onTap: () => _nudgeA(-1000)),
                      const SizedBox(width: 6),
                      _Mini(label: 'A+1', onTap: () => _nudgeA(1000)),
                    ],
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: ready ? () => setState(() => _b = _position) : null,
                    child: Text("B ${_b == null ? '--:--' : _fmt(_b!)}"),
                  ),
                  const SizedBox(width: 10),
                  Row(
                    children: [
                      _Mini(label: 'B-0.1', onTap: () => _nudgeB(-100)),
                      const SizedBox(width: 6),
                      _Mini(label: 'B+0.1', onTap: () => _nudgeB(100)),
                      const SizedBox(width: 6),
                      _Mini(label: 'B-1', onTap: () => _nudgeB(-1000)),
                      const SizedBox(width: 6),
                      _Mini(label: 'B+1', onTap: () => _nudgeB(1000)),
                    ],
                  ),
                ],
              ),
            ),

            // transport + loop + quick
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Aller à A',
                  onPressed: (_a != null && ready) ? () => _seek(_a!) : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton.filled(
                  onPressed: ready ? _togglePlay : null,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: 'Aller à B',
                  onPressed: (_b != null && ready) ? () => _seek(_b!) : null,
                  icon: const Icon(Icons.skip_next),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _loop ? 'Boucle ON' : 'Boucle OFF',
                  onPressed: ready ? _toggleLoop : null,
                  icon: Icon(Icons.loop, color: _loop ? cs.primary : null),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: ready ? _quickLoopAroundCursor : null,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Boucle rapide'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Effacer A/B',
                  onPressed: (_a != null || _b != null)
                      ? () => setState(() { _a = null; _b = null; _loop = false; })
                      : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),

            // vitesse
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.speed),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Slider(
                      value: _speed.clamp(0.25, 2.0),
                      min: 0.25,
                      max: 2.0,
                      onChanged: ready ? (v) => _applySpeed(v) : null,
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text('${_speed.toStringAsFixed(2)}x', textAlign: TextAlign.right),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Petits widgets utilitaires ----
class _SeekBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SeekBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(onPressed: onTap, child: Text(label));
  }
}

class _Mini extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Mini({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}