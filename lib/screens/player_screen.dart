import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // --------- Constantes / helpers ----------
  static const Duration _kQuickGap = Duration(seconds: 4);
  static const _kPosMsKey = 'looptrainer_session_v1.positionMs';
  static const _kResumeFlagKey = 'looptrainer_session_v1.resumeWanted';

  Duration _clampDur(Duration d, Duration min, Duration max) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }

  Future<Duration> _waitForNonZeroDuration({Duration timeout = const Duration(seconds: 2)}) async {
    final start = DateTime.now();
    while (true) {
      final dur = await _currentDuration();
      if (dur > Duration.zero) return dur;
      if (DateTime.now().difference(start) > timeout) return dur; // on sort quand même
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
  String _fmt(Duration d) {
    final s = d.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  // --------- Etat média ----------
  String? _mediaPath;
  bool _isVideo = false;

  VideoPlayerController? _video;
  final _audio = AudioPlayer();

  // Timeline
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // Boucle A/B
  Duration? _a;
  Duration? _b;
  bool _loopEnabled = false;

  // Vitesse
  double _speed = 1.0;

  // Ticker de position
  Timer? _ticker;

  // --------- Session / autosave ----------
  SharedPreferences? _prefs;
  Timer? _autosaveTimer;
  static const _kSessionKey = 'looptrainer_session_v1';

  int _durToMs(Duration? d) => d == null ? -1 : d.inMilliseconds;
  Duration? _msToDur(int? ms) =>
      (ms == null || ms < 0) ? null : Duration(milliseconds: ms);

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 500), _saveSession);
  }

  Future<void> _saveSession() async {
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();

      await sp.setString('$_kSessionKey.path', _mediaPath ?? '');
      await sp.setBool('$_kSessionKey.isVideo', _isVideo);
      await sp.setDouble('$_kSessionKey.speed', _speed);

      await sp.setInt('$_kSessionKey.aMs', _durToMs(_a));
      await sp.setInt('$_kSessionKey.bMs', _durToMs(_b));
      await sp.setBool('$_kSessionKey.loop', _loopEnabled);
      await sp.setInt(_kPosMsKey, _durToMs(_position));
// Flag pour dire qu'on souhaite reprendre à la relance (pratique si on veut désactiver plus tard)
      await sp.setBool(_kResumeFlagKey, true);
    } catch (_) {}
  }

  Future<void> _restoreSession() async {
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();

      final path = sp.getString('$_kSessionKey.path');
      final isVideo = sp.getBool('$_kSessionKey.isVideo') ?? false;
      final speed = sp.getDouble('$_kSessionKey.speed') ?? 1.0;
      final aMs = sp.getInt('$_kSessionKey.aMs');
      final bMs = sp.getInt('$_kSessionKey.bMs');
      final loop = sp.getBool('$_kSessionKey.loop') ?? false;

      final posMs = sp.getInt(_kPosMsKey);
      final wantResume = sp.getBool(_kResumeFlagKey) ?? true;

      if (path == null || path.isEmpty) return;
      if (!File(path).existsSync()) return;

      // ouvre le média (initialise les players)
      await _openMediaFromPath(path, isVideo: isVideo);

      // applique vitesse + A/B + loop
      setState(() {
        _speed = speed.clamp(0.5, 1.5);
        _a = _msToDur(aMs);
        _b = _msToDur(bMs);
        _loopEnabled = loop && (_a != null && _b != null && _b! > _a!);
      });
      _applySpeedToPlayers();

      // 🔑 attends que la durée réelle soit connue avant de seek
      final realDur = await _waitForNonZeroDuration();
      if (wantResume) {
        final savedPos = _msToDur(posMs) ?? Duration.zero;
        final safeMax = (realDur > const Duration(milliseconds: 300))
            ? realDur - const Duration(milliseconds: 300)
            : Duration.zero;
        final target = _clampDur(savedPos, Duration.zero, safeMax);
        if (target > Duration.zero) {
          await _seek(target);
        }
      }
    } catch (_) {
      // on ignore silencieusement
    }
  }
  // --------- Cycle de vie ----------
  @override
  void initState() {
    super.initState();
    _startTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    // on essaie de sauvegarder une dernière fois (sans bloquer)
    unawaited(_saveSession());
    _ticker?.cancel();
    _video?.dispose();
    _audio.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (!mounted) return;
      final pos = await _currentPosition();
      final dur = await _currentDuration();

      if (pos != _position || dur != _duration) {
        setState(() {
          _position = pos;
          _duration = dur;
          if (pos != _position || dur != _duration) {
            setState(() {
              _position = pos;
              _duration = dur;
            });
            // Sauvegarde légère de la position (toutes les ~500 ms grâce à _scheduleAutosave)
            _scheduleAutosave();
          }
        });
      }

      if (_loopEnabled && _a != null && _b != null && _b! > _a!) {
        if (pos >= _b!) {
          unawaited(_seek(_a!));
        }
      }
    });
  }

  Future<Duration> _currentPosition() async {
    if (_isVideo) {
      final v = _video;
      if (v == null) return Duration.zero;
      return v.value.position;
    } else {
      return _audio.position;
    }
  }

  Future<Duration> _currentDuration() async {
    if (_isVideo) {
      final v = _video;
      if (v == null) return Duration.zero;
      return v.value.duration ?? Duration.zero;
    } else {
      return _audio.duration ?? Duration.zero;
    }
  }

  // --------- Ouverture média ----------
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac',
        'mp4', 'mov', 'mkv', 'webm'
      ],
    );
    if (res == null || res.files.single.path == null) return;
    await _openMediaFromPath(res.files.single.path!);
    _scheduleAutosave();
  }

  Future<void> _openMediaFromPath(String path, {bool? isVideo}) async {
    final ext = p.extension(path).toLowerCase();
    _stop();

    final isVid = isVideo ??
        ['.mp4', '.mov', '.mkv', '.webm'].contains(ext);

    if (isVid) {
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      await controller.setLooping(false);
      await controller.setPlaybackSpeed(_speed);
      setState(() {
        _isVideo = true;
        _mediaPath = path;
        _video = controller;
      });
      _scheduleAutosave(); // << ajoute ici pour vidéo
      await controller.play();
      await controller.play();
    } else {
      await _audio.setFilePath(path);
      await _audio.setLoopMode(LoopMode.off);
      await _audio.setSpeed(_speed);
      setState(() {
        _isVideo = false;
        _mediaPath = path;
      });
      setState(() {
        _isVideo = false;
        _mediaPath = path;
      });
      _scheduleAutosave(); // << ajoute ici pour audio
      await _audio.play();

    }

    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
    });
    _scheduleAutosave(); // << on sauvegarde l’état initial du média ouvert
  }

  void _applySpeedToPlayers() {
    if (_isVideo) {
      _video?.setPlaybackSpeed(_speed);
    } else {
      _audio.setSpeed(_speed);
    }
  }

  Future<void> _seek(Duration d) async {
    d = _clampDur(d, Duration.zero, _duration);
    if (_isVideo) {
      await _video?.seekTo(d);
    } else {
      await _audio.seek(d);
    }
  }

  Future<void> _playPause() async {
    if (_isVideo) {
      final v = _video;
      if (v == null) return;
      if (v.value.isPlaying) {
        await v.pause();
        _scheduleAutosave(); // << sauve la position quand on met pause (vidéo)
      } else {
        await v.play();
      }
      setState(() {});
    } else {
      if (_audio.playing) {
        await _audio.pause();
        _scheduleAutosave(); // << sauve la position quand on met pause (audio)
      } else {
        await _audio.play();
      }
      setState(() {});
    }
  }

  Future<void> _stop() async {
    _loopEnabled = false;
    _a = null;
    _b = null;
    if (_isVideo) {
      await _video?.pause();
      await _video?.dispose();
      _video = null;
    } else {
      await _audio.stop();
    }
    _scheduleAutosave(); // << enregistre l’état et la position
  }

  // --------- Marqueurs A / B ----------
  void _markA() {
    final now = _position;
    setState(() {
      _a = now;
      if (_b != null) {
        if (_b! <= _a!) {
          _b = _clampDur(_a! + _kQuickGap, Duration.zero, _duration);
        }
        _loopEnabled = true;
      }
    });
    _scheduleAutosave();
  }

  void _markBAndAutoLoop() {
    final now = _position;

    if (_a == null) {
      final aCand = now - _kQuickGap;
      final a = _clampDur(aCand, Duration.zero, _duration);
      setState(() {
        _a = a;
        _b = now;
        _loopEnabled = true;
      });
    } else {
      var bFixed = now;
      if (bFixed <= _a!) {
        bFixed = _clampDur(_a! + _kQuickGap, Duration.zero, _duration);
      }
      setState(() {
        _b = bFixed;
        _loopEnabled = true;
      });
    }
    _scheduleAutosave();
  }

  void _clearLoop() {
    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
    });
    _scheduleAutosave();
  }

  void _toggleLoop() {
    if (_a == null || _b == null || !(_b! > _a!)) {
      final half = const Duration(milliseconds: 2000);
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
    _scheduleAutosave();
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v);
    _applySpeedToPlayers();
    _scheduleAutosave();
  }

  // --------- UI ----------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPlaying =
    _isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing;

    final aVal = _a ?? Duration.zero;
    final bVal =
        _b ?? (_duration == Duration.zero ? const Duration(seconds: 1) : _duration);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          _mediaPath == null ? 'Lecteur' : p.basename(_mediaPath!),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Ouvrir un fichier',
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _isVideo && _video != null && _video!.value.isInitialized
                  ? AspectRatio(
                aspectRatio: _video!.value.aspectRatio,
                child: VideoPlayer(_video!),
              )
                  : _mediaPath == null
                  ? Text('Aucun média',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white70))
                  : const Icon(Icons.audiotrack,
                  size: 96, color: Colors.white54),
            ),
          ),
          if (_duration > Duration.zero)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Text(_fmt(_position),
                      style: const TextStyle(color: Colors.white70)),
                  Expanded(
                    child: Slider(
                      value: _position.inMilliseconds
                          .toDouble()
                          .clamp(0.0, _duration.inMilliseconds.toDouble()),
                      min: 0,
                      max: _duration.inMilliseconds.toDouble(),
                      onChanged: (v) =>
                          _seek(Duration(milliseconds: v.round())),
                    ),
                  ),
                  Text(_fmt(_duration),
                      style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          if (_duration > Duration.zero)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor:
                          _a == null ? Colors.grey.shade800 : null,
                        ),
                        onPressed: _markA,
                        child: const Text('A'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor:
                          _b == null ? Colors.grey.shade800 : null,
                        ),
                        onPressed: _markBAndAutoLoop,
                        child: const Text('B'),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        isSelected: _loopEnabled,
                        selectedIcon: const Icon(Icons.repeat_on),
                        icon: const Icon(Icons.repeat),
                        onPressed: _toggleLoop,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Supprimer la boucle',
                        onPressed: _clearLoop,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  RangeSlider(
                    values: RangeValues(
                      aVal.inMilliseconds.toDouble(),
                      bVal.inMilliseconds.toDouble(),
                    ),
                    min: 0,
                    max: _duration.inMilliseconds
                        .toDouble()
                        .clamp(1, double.infinity),
                    onChanged: (rv) {
                      var aMs = rv.start.round();
                      var bMs = rv.end.round();
                      if (bMs <= aMs) bMs = aMs + 1;
                      setState(() {
                        _a = Duration(milliseconds: aMs);
                        _b = Duration(milliseconds: bMs);
                      });
                      _scheduleAutosave();
                    },
                    onChangeEnd: (_) {
                      if (_a != null && _b != null && _b! > _a!) {
                        setState(() => _loopEnabled = true);
                      }
                      _scheduleAutosave();
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('A ${_fmt(aVal)}',
                          style: const TextStyle(color: Colors.white70)),
                      Text('B ${_fmt(bVal)}',
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text('Vitesse ${_speed.toStringAsFixed(2)}x',
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
                Slider(
                  value: _speed,
                  min: 0.5,
                  max: 1.5,
                  onChanged: (v) =>
                      _setSpeed(double.parse(v.toStringAsFixed(2))),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Reculer 5s',
                  onPressed: () => _seek(_position - const Duration(seconds: 5)),
                  icon: const Icon(Icons.replay_5, color: Colors.white),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _playPause,
                  child: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Avancer 5s',
                  onPressed: () => _seek(_position + const Duration(seconds: 5)),
                  icon: const Icon(Icons.forward_5, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}