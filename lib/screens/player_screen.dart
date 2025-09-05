import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  // ---------- état média ----------
  String? _mediaPath;
  bool get _isVideo => _mediaPath != null && _video != null;

  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // ---------- A/B & boucle ----------
  Duration? _a;
  Duration? _b;
  bool _loopEnabled = false;
  static const int _quickGapMs = 4000; // A = B-4s quand B d’abord

  // ---------- vitesse ----------
  double _speed = 1.0;

  // ---------- prefs ----------
  SharedPreferences? _prefs;
  static const _kPrefPath = 'last.media';
  static const _kPrefSpeed = 'last.speed';
  static const _kPrefA = 'last.a';
  static const _kPrefB = 'last.b';
  static const _kPrefLoop = 'last.loop';

  // ---------- lifecycle ----------
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _audio.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _save();
  }

  // =========================================================
  //                     UI HELPERS
  // =========================================================

  // Couleurs sobres
  Color get _accent => const Color(0xFFFF9500); // orange discret
  Color get _muted => Colors.white.withOpacity(0.6);

  // =========================================================
  //                  CHARGEMENT / SAUVEGARDE
  // =========================================================

  Future<void> _restore() async {
    _prefs ??= await SharedPreferences.getInstance();
    final path = _prefs!.getString(_kPrefPath);
    _speed = _prefs!.getDouble(_kPrefSpeed) ?? 1.0;
    _loopEnabled = _prefs!.getBool(_kPrefLoop) ?? false;

    final aMs = _prefs!.getInt(_kPrefA);
    final bMs = _prefs!.getInt(_kPrefB);
    _a = aMs != null ? Duration(milliseconds: aMs) : null;
    _b = bMs != null ? Duration(milliseconds: bMs) : null;

    if (path != null && File(path).existsSync()) {
      await _openPath(path, autostart: false);
    } else {
      setState(() {}); // juste pour peindre l’écran vide
    }
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_mediaPath != null) _prefs!.setString(_kPrefPath, _mediaPath!);
    _prefs!.setDouble(_kPrefSpeed, _speed);
    _prefs!.setBool(_kPrefLoop, _loopEnabled);
    _prefs!.setInt(_kPrefA, _a?.inMilliseconds ?? -1);
    _prefs!.setInt(_kPrefB, _b?.inMilliseconds ?? -1);
  }

  // =========================================================
  //                         MEDIA
  // =========================================================

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4','mov','m4v','mp3','wav','aac','m4a'
      ],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await _openPath(path);
  }

  Future<void> _openPath(String path, {bool autostart = true}) async {
    // stop & clean
    _posSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();

    _mediaPath = path;
    final ext = p.extension(path).toLowerCase();

    if (<String>{'.mp4','.mov','.m4v'}.contains(ext)) {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      _video = c;
      _duration = c.value.duration;
      _position = Duration.zero;

      // position stream (via timer “simulateur”)
      // Abonnement "ticker" vidéo : émet bien des Duration
      _posSub = Stream<Duration>
          .periodic(const Duration(milliseconds: 200), (_) {
        // On renvoie une Duration pour typage strict
        return _video?.value.position ?? Duration.zero;
      })
          .listen((pos) {
        _onTick(pos); // ta fonction qui réagit à la position
      });
      if (autostart) {
        await c.play();
        await c.setPlaybackSpeed(_speed);
      }
    } else {
      // audio
      await _audio.setFilePath(path);
      await _audio.setSpeed(_speed);
      _duration = _audio.duration ?? Duration.zero;
      _position = Duration.zero;
      _posSub = _audio.positionStream.listen(_onTick);
      if (autostart) await _audio.play();
    }

    // clamp A/B dans la nouvelle durée
    if (_duration == Duration.zero) {
      _a = null; _b = null; _loopEnabled = false;
    } else {
      if (_a != null) _a = _clampDur(_a!, Duration.zero, _duration);
      if (_b != null) _b = _clampDur(_b!, Duration.zero, _duration);
      if (_a != null && _b != null && !(_a! < _b!)) _loopEnabled = false;
    }

    setState(() {});
    _save();
  }

  // tick: applique la logique de boucle
  void _onTick(Duration pos) {
    if (!mounted) return;
    if (_duration == Duration.zero) return;

    // boucle A/B
    if (_loopEnabled && _a != null && _b != null && _a! < _b!) {
      if (pos >= _b!) {
        _seek(_a!);
        return;
      }
    }
    setState(() => _position = pos);
  }

  Future<void> _playPause() async {
    if (_mediaPath == null) {
      await _pickFile();
      return;
    }
    if (_video != null) {
      if (_video!.value.isPlaying) {
        await _video!.pause();
      } else {
        await _video!.play();
      }
      return;
    }
    if (_audio.playing) {
      await _audio.pause();
    } else {
      await _audio.play();
    }
  }

  Future<void> _seek(Duration d) async {
    d = _clampDur(d, Duration.zero, _duration);
    if (_video != null) {
      await _video!.seekTo(d);
    } else {
      await _audio.seek(d);
    }
    setState(() => _position = d);
  }

  // =========================================================
  //                        A / B  LOGIC
  // =========================================================

  Duration _clampDur(Duration d, Duration min, Duration max) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }

  // Bouton A : peut être posé en premier
  void _markA() {
    if (_duration == Duration.zero) return;
    final now = _position;
    if (_b == null) {
      // A en premier -> juste positionner A pour l’instant
      setState(() {
        _a = now;
        _loopEnabled = false; // pas de boucle tant que B absent
      });
    } else {
      // B existe déjà -> activer si A < B
      setState(() {
        _a = now;
        _loopEnabled = (_a! < _b!);
      });
    }
    _save();
  }

  // Bouton B : si A absent -> A = B - 4s borné à 0
  void _markB() {
    if (_duration == Duration.zero) return;
    final now = _position;

    if (_a == null) {
      final candA = now - Duration(milliseconds: _quickGapMs);
      final a = _clampDur(candA, Duration.zero, _duration);
      setState(() {
        _a = a;
        _b = now;
        _loopEnabled = (_a! < _b!);
      });
    } else {
      setState(() {
        _b = now;
        _loopEnabled = (_a! < _b!);
      });
    }
    _save();
  }

  void _clearLoop() {
    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
    });
    _save();
  }

  void _toggleLoopEnabled() {
    // Si A/B invalides, on fabrique une petite fenêtre autour du curseur
    if (_a == null || _b == null || !(_a! < _b!)) {
      final half = Duration(milliseconds: (_quickGapMs / 2).round());
      var a = _clampDur(_position - half, Duration.zero, _duration);
      var b = _clampDur(_position + half, Duration.zero, _duration);
      if (b <= a) b = _clampDur(a + const Duration(milliseconds: 200), Duration.zero, _duration);
      setState(() {
        _a = a;
        _b = b;
        _loopEnabled = true;
      });
    } else {
      setState(() => _loopEnabled = !_loopEnabled);
    }
    _save();
  }

  // =========================================================
  //                         VITESSE
  // =========================================================

  Future<void> _applySpeed(double v) async {
    v = v.clamp(0.25, 2.0);
    setState(() => _speed = double.parse(v.toStringAsFixed(2)));
    if (_video != null) {
      await _video!.setPlaybackSpeed(_speed);
    } else {
      await _audio.setSpeed(_speed);
    }
    _save();
  }

  // =========================================================
  //                            UI
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final title = _mediaPath == null ? 'Aucun fichier' : p.basename(_mediaPath!);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ---------- top bar ----------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ouvrir…',
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                  ),
                ],
              ),
            ),

            // ---------- media area ----------
            Expanded(
              child: GestureDetector(
                onTap: _playPause,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _video?.value.aspectRatio ?? (9 / 16),
                    child: _video != null
                        ? Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoPlayer(_video!),
                        _PlayOverlay(isPlaying: _video!.value.isPlaying),
                      ],
                    )
                        : _audioArea(),
                  ),
                ),
              ),
            ),

            // ---------- controls minimal ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // A
                  _LoopBtn(
                    label: 'A',
                    onTap: _markA,
                    active: _a != null,
                    accent: _accent,
                  ),
                  // B
                  _LoopBtn(
                    label: 'B',
                    onTap: _markB,
                    active: _b != null,
                    accent: _accent,
                  ),
                  // loop toggle
                  IconButton(
                    tooltip: _loopEnabled ? 'Boucle activée' : 'Boucle désactivée',
                    onPressed: _toggleLoopEnabled,
                    icon: Icon(
                      Icons.loop,
                      color: _loopEnabled ? _accent : _muted,
                    ),
                  ),
                  // effacer
                  IconButton(
                    tooltip: 'Effacer A/B',
                    onPressed: _clearLoop,
                    icon: Icon(Icons.close, color: _muted),
                  ),
                  // vitesse stepper simple
                  Row(
                    children: [
                      _MiniIcon(onTap: () => _applySpeed(_speed - 0.1), icon: Icons.remove),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text('${_speed.toStringAsFixed(2)}x', style: TextStyle(color: _muted, fontSize: 16)),
                      ),
                      _MiniIcon(onTap: () => _applySpeed(_speed + 0.1), icon: Icons.add),
                    ],
                  ),
                  // play/pause
                  IconButton(
                    onPressed: _playPause,
                    icon: Icon(
                      (_video?.value.isPlaying ?? _audio.playing) ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ),

            // ---------- single progress bar (position) + A/B thumbs superposées ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
              child: _timeline(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _audioArea() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Icon(
          (_audio.playing) ? Icons.graphic_eq : Icons.audiotrack,
          size: 72,
          color: _muted,
        ),
      ),
    );
  }

  Widget _timeline() {
    final dur = _duration.inMilliseconds.toDouble();
    final pos = _position.inMilliseconds.toDouble().clamp(0.0, dur.isFinite && dur > 0 ? dur : 0.0);

    // valeurs A/B normalisées 0..1
    double aNorm = (_a?.inMilliseconds ?? 0).toDouble();
    double bNorm = (_b?.inMilliseconds ?? (_a != null ? (_a!.inMilliseconds + 1000) : 1000)).toDouble();
    if (dur <= 0) {
      aNorm = 0;
      bNorm = 1000;
    }
    aNorm = (dur <= 0) ? 0 : (aNorm / dur).clamp(0.0, 1.0);
    bNorm = (dur <= 0) ? 0 : (bNorm / dur).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // time labels
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_fmt(_position), style: TextStyle(color: _muted, fontSize: 12)),
            Text(_fmt(_duration), style: TextStyle(color: _muted, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),

        // stack = slider position + “poignées” A/B
        SizedBox(
          height: 42,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // progress (scrubbable)
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: _accent,
                  inactiveTrackColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value: dur > 0 ? pos : 0,
                  min: 0,
                  max: dur > 0 ? dur : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _position = Duration(milliseconds: v.round())) : null,
                  onChangeEnd: dur > 0 ? (v) => _seek(Duration(milliseconds: v.round())) : null,
                ),
              ),

              // A/B handles (RangeSlider “translucide”)
// A/B handles (RangeSlider translucide, mais clics passés au Slider dessous)
              IgnorePointer(
                ignoring: false, // 👈 permet toujours au Slider de recevoir les gestes
                child: SizedBox(
                  height: 42,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 0, // pas de piste visible
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                      thumbShape: _DiamondThumb(color: _accent),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: RangeSlider(
                      values: RangeValues(aNorm, bNorm),
                      min: 0,
                      max: 1,
                      onChanged: (rng) {
                        final newA = Duration(milliseconds: (rng.start * dur).round());
                        final newB = Duration(milliseconds: (rng.end * dur).round());
                        setState(() {
                          _a = newA;
                          _b = newB;
                        });
                      },
                      onChangeEnd: (_) => _save(),
                    ),
                  ),
                ),
              ),

              // petites marques A / B au-dessus
              if (_a != null && dur > 0)
                Positioned(
                  left: (aNorm * MediaQuery.of(context).size.width).clamp(0, MediaQuery.of(context).size.width - 20),
                  top: 0,
                  child: _markerLabel('A'),
                ),
              if (_b != null && dur > 0)
                Positioned(
                  left: (bNorm * MediaQuery.of(context).size.width).clamp(0, MediaQuery.of(context).size.width - 20),
                  top: 0,
                  child: _markerLabel('B'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _markerLabel(String s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.6),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: _accent, width: 1),
    ),
    child: Text(s, style: TextStyle(color: _accent, fontWeight: FontWeight.w700, fontSize: 11)),
  );

  String _fmt(Duration d) {
    final t = d.inMilliseconds < 0 ? Duration.zero : d;
    final h = t.inHours;
    final m = t.inMinutes.remainder(60);
    final s = t.inSeconds.remainder(60);
    final ms = (t.inMilliseconds.remainder(1000) / 10).round();
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ===================== widgets discrets =====================

class _PlayOverlay extends StatelessWidget {
  final bool isPlaying;
  const _PlayOverlay({required this.isPlaying});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: isPlaying ? 0.0 : 0.9,
          child: Icon(Icons.play_circle_fill, size: 84, color: Colors.white70),
        ),
      ),
    );
  }
}

class _LoopBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color accent;
  const _LoopBtn({required this.label, required this.onTap, required this.active, required this.accent});

  @override
  Widget build(BuildContext context) {
    final off = Colors.white.withOpacity(0.35);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? accent : off,
        side: BorderSide(color: active ? accent : off, width: 1.4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(40, 36),
      ),
      onPressed: onTap,
      child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: active ? accent : off)),
    );
  }
}

class _MiniIcon extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  const _MiniIcon({required this.onTap, required this.icon});
  @override
  Widget build(BuildContext context) {
    return InkResponse(
      radius: 18,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Icon(icon, size: 18, color: Colors.white70),
      ),
    );
  }
}

// Petit losange pour les “poignées” A/B
class _DiamondThumb extends SliderComponentShape {
  final double size;
  final Color color;
  const _DiamondThumb({this.size = 12, required this.color});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.square(size);

  @override
  void paint(
      PaintingContext context,
      Offset center, {
        required Animation<double> activationAnimation,
        required Animation<double> enableAnimation,
        required bool isDiscrete,
        required TextPainter labelPainter,
        required RenderBox parentBox,
        required SliderThemeData sliderTheme,
        required TextDirection textDirection,
        required double value,
        required double textScaleFactor,
        required Size sizeWithOverflow,
      }) {
    final canvas = context.canvas;
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(center.dx, center.dy - size / 2)
      ..lineTo(center.dx + size / 2, center.dy)
      ..lineTo(center.dx, center.dy + size / 2)
      ..lineTo(center.dx - size / 2, center.dy)
      ..close();
    canvas.drawPath(path, paint);
    // petit contour
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.black.withOpacity(0.6);
    canvas.drawPath(path, border);
  }
}