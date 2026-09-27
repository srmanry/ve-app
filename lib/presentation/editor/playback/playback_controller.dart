import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_timeline.dart';
import '../../../domain/entities/timeline_item.dart';

/// Multi-clip preview engine on top of platform players (`video_player`).
///
/// * Main-track clips share a small LRU pool of players keyed by source
///   file, so split clips of the same file reuse one decoder.
/// * The playhead is driven by the wall clock while playing (the plugin only
///   reports positions every ~500 ms), and re-anchored to the player when
///   they drift apart - smooth timeline scrolling without stutter.
/// * Audio tracks and PIP layers get their own players, kept in sync.
/// * Seeks are coalesced so fast scrubbing never queues up stale seeks.
///
/// Preview is best-effort: effects that can't be shown live are rendered
/// exactly at export time.
class PlaybackController extends ChangeNotifier {
  PlaybackController({required Project project, required this.resolveMedia})
    : _project = project,
      _timeline = ProjectTimeline(project);

  final String Function(String relativePath) resolveMedia;

  /// Current timeline position. High-frequency; listen to this instead of
  /// the controller when only the playhead matters.
  final position = ValueNotifier<Duration>(Duration.zero);

  // Each player holds a hardware decoder and buffers; two is enough for
  // gapless clip switching and keeps low-RAM phones from being killed.
  static const _maxMainPlayers = 2;
  static const _tickInterval = Duration(milliseconds: 33);
  static const _secondarySyncEvery = 8; // ticks

  Project _project;
  ProjectTimeline _timeline;
  bool _playing = false;
  bool _disposed = false;
  Duration? _stopAt;

  final _mainPool = <String, _Player>{};
  final _lru = <String>[];
  String? _activeKey;
  int? _activeIndex;

  final _audioPlayers = <String, _Player>{};
  final _pipPlayers = <String, _Player>{};

  Timer? _ticker;
  int _tickCount = 0;
  DateTime _anchorTime = DateTime.now();
  Duration _anchorPosition = Duration.zero;
  bool _switching = false;

  bool _syncing = false;
  bool _syncPending = false;

  bool get isPlaying => _playing;
  Duration get duration => _timeline.duration;
  ProjectTimeline get timeline => _timeline;

  /// Player for the clip currently shown, when ready.
  VideoPlayerController? get activeController {
    final p = _mainPool[_activeKey];
    return p != null && p.ready ? p.controller : null;
  }

  bool get activeFailed => _mainPool[_activeKey]?.failed ?? false;

  int? get activeIndex => _activeIndex;

  VideoPlayerController? pipController(String id) {
    final p = _pipPlayers[id];
    return p != null && p.ready ? p.controller : null;
  }

  // ----------------------------------------------------------- project sync

  void updateProject(Project project) {
    if (identical(project, _project)) return;
    _project = project;
    _timeline = ProjectTimeline(project);
    if (position.value > _timeline.duration) position.value = _timeline.duration;

    _disposeRemoved(_audioPlayers, project.audioTracks.map((a) => a.id).toSet());
    _disposeRemoved(_pipPlayers, project.pipLayers.map((l) => l.id).toSet());

    if (!_playing) {
      _requestFrameSync();
    } else {
      // Speed/volume may have changed for the active clip.
      unawaited(_applyActiveClipSettings());
    }
    notifyListeners();
  }

  void _disposeRemoved(Map<String, _Player> players, Set<String> keep) {
    for (final id in players.keys.where((k) => !keep.contains(k)).toList()) {
      unawaited(players.remove(id)!.dispose());
    }
  }

  // ------------------------------------------------------------- transport

  /// Moves the playhead. Pauses playback when [fromUser] (scrubbing).
  void seek(Duration t, {bool fromUser = true}) {
    if (fromUser && _playing) pause();
    position.value = _clamp(t);
    _requestFrameSync();
  }

  Future<void> togglePlay() => _playing ? Future.sync(pause) : play();

  /// Plays from the playhead; with [until], pauses automatically there
  /// (used by "preview selection").
  Future<void> play({Duration? until}) async {
    if (_project.clips.isEmpty || _disposed) return;
    if (position.value >= _timeline.duration - const Duration(milliseconds: 50)) {
      position.value = Duration.zero;
    }
    _stopAt = until;
    _playing = true;
    notifyListeners();

    await _syncFrame();
    if (!_playing || _disposed) return;
    await _applyActiveClipSettings();
    await activeController?.play();
    _anchor(position.value);
    _syncSecondary(force: true);

    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (_) => _tick());
  }

  Future<void> playRange(Duration from, Duration to) async {
    seek(from);
    await play(until: to);
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _stopAt = null;
    _ticker?.cancel();
    _ticker = null;
    for (final p in [..._mainPool.values, ..._audioPlayers.values, ..._pipPlayers.values]) {
      if (p.ready) unawaited(p.controller.pause());
    }
    notifyListeners();
    // Land the frame exactly on the playhead.
    _requestFrameSync();
  }

  void _anchor(Duration at) {
    _anchorTime = DateTime.now();
    _anchorPosition = at;
  }

  void _tick() {
    if (!_playing || _switching || _disposed) return;
    var next = _anchorPosition + DateTime.now().difference(_anchorTime);

    if (_stopAt != null && next >= _stopAt!) {
      position.value = _clamp(_stopAt!);
      pause();
      return;
    }
    if (next >= _timeline.duration) {
      position.value = _timeline.duration;
      pause();
      return;
    }

    final loc = _timeline.locate(next);
    if (loc == null) return;
    if (loc.index != _activeIndex) {
      unawaited(_switchClip(next));
      return;
    }

    // Re-anchor on large drift (e.g. the player stalled on a slow seek).
    final controller = activeController;
    if (controller != null && controller.value.isInitialized) {
      if (controller.value.isBuffering) {
        _anchor(position.value);
        return;
      }
      final playerTimeline = loc.clipStart + loc.clip.sourceToLocal(controller.value.position);
      if ((playerTimeline - next).abs() > const Duration(milliseconds: 1000)) {
        next = playerTimeline;
        _anchor(next);
      }
    }

    position.value = next;
    if (++_tickCount % _secondarySyncEvery == 0) _syncSecondary();
  }

  Future<void> _switchClip(Duration at) async {
    _switching = true;
    try {
      final previous = activeController;
      final loc = _timeline.locate(at)!;
      final key = resolveMedia(loc.clip.sourcePath);
      if (key != _activeKey) await previous?.pause();
      position.value = at;
      await _syncFrame();
      if (!_playing) return;
      await _applyActiveClipSettings();
      await activeController?.play();
      _anchor(at);
    } finally {
      _switching = false;
    }
  }

  // ------------------------------------------------------------ frame sync

  void _requestFrameSync() {
    if (_syncing) {
      _syncPending = true;
      return;
    }
    unawaited(_runFrameSync());
  }

  Future<void> _runFrameSync() async {
    _syncing = true;
    try {
      do {
        _syncPending = false;
        await _syncFrame();
      } while (_syncPending && !_disposed);
    } finally {
      _syncing = false;
    }
  }

  /// Makes the active player show the frame at [position].
  Future<void> _syncFrame() async {
    if (_disposed) return;
    final t = position.value;
    final loc = _timeline.locate(t);
    if (loc == null) {
      _activeKey = null;
      _activeIndex = null;
      notifyListeners();
      return;
    }
    final key = resolveMedia(loc.clip.sourcePath);
    if (loc.clip.isStill) {
      // Photos need no player: the preview draws the image and the wall
      // clock drives the playhead.
      final changed = key != _activeKey || loc.index != _activeIndex;
      _activeKey = key;
      _activeIndex = loc.index;
      if (changed) notifyListeners();
      if (!_playing) _syncPipFrames(t);
      _preloadNext(loc.index);
      return;
    }
    final player = await _obtainMain(key);
    if (_disposed) return;
    final changed = key != _activeKey || loc.index != _activeIndex;
    _activeKey = key;
    _activeIndex = loc.index;
    if (changed) notifyListeners();
    if (player.ready) {
      final target = loc.sourcePosition;
      if ((player.controller.value.position - target).abs() > const Duration(milliseconds: 40) ||
          !_playing) {
        await player.controller.seekTo(target);
      }
    }
    if (!_playing) _syncPipFrames(t);
    _preloadNext(loc.index);
  }

  Future<void> _applyActiveClipSettings() async {
    final index = _activeIndex;
    final c = activeController;
    if (index == null || c == null || index >= _project.clips.length) return;
    final clip = _project.clips[index];
    await c.setVolume(clip.muted ? 0 : clip.volume.clamp(0.0, 1.0));
    if (c.value.playbackSpeed != clip.speed) await c.setPlaybackSpeed(clip.speed);
  }

  void _preloadNext(int index) {
    if (index + 1 >= _project.clips.length) return;
    final next = _project.clips[index + 1];
    if (next.isStill) return;
    final key = resolveMedia(next.sourcePath);
    if (key == _activeKey) return;
    unawaited(
      _obtainMain(key).then((p) {
        if (p.ready && key != _activeKey) return p.controller.seekTo(next.trimStart);
      }),
    );
  }

  Future<_Player> _obtainMain(String key) async {
    var player = _mainPool[key];
    if (player == null) {
      player = _Player(key);
      _mainPool[key] = player;
      _evictMain(keep: key);
    }
    _lru
      ..remove(key)
      ..add(key);
    await player.initialized;
    return player;
  }

  void _evictMain({required String keep}) {
    while (_mainPool.length > _maxMainPlayers) {
      final victim = _lru.firstWhere((k) => k != keep && k != _activeKey, orElse: () => '');
      if (victim.isEmpty) break;
      _lru.remove(victim);
      unawaited(_mainPool.remove(victim)?.dispose());
    }
  }

  // ----------------------------------------------------- audio + PIP sync

  void _syncSecondary({bool force = false}) {
    final t = position.value;
    for (final track in _project.audioTracks) {
      final active = !track.muted && track.isActiveAt(t);
      final player = _audioPlayers.putIfAbsent(
        track.id,
        () => _Player(resolveMedia(track.sourcePath)),
      );
      final expected = track.trimStart + (t - track.start);
      unawaited(
        _syncPlayer(player, active, expected, volume: track.volume.clamp(0.0, 1.0), force: force),
      );
    }
    for (final pip in _project.pipLayers) {
      final active = pip.isActiveAt(t);
      final player = _pipPlayers.putIfAbsent(pip.id, () => _Player(resolveMedia(pip.sourcePath)));
      final expected = pip.trimStart + (t - pip.start);
      unawaited(
        _syncPlayer(
          player,
          active,
          expected,
          volume: pip.muted ? 0 : pip.volume.clamp(0.0, 1.0),
          force: force,
        ),
      );
    }
  }

  Future<void> _syncPlayer(
    _Player player,
    bool active,
    Duration expected, {
    required double volume,
    bool force = false,
  }) async {
    await player.initialized;
    if (!player.ready || _disposed) return;
    final c = player.controller;
    if (!active || !_playing) {
      if (c.value.isPlaying) await c.pause();
      return;
    }
    if (c.value.volume != volume) await c.setVolume(volume);
    final drift = (c.value.position - expected).abs();
    if (force || !c.value.isPlaying || drift > const Duration(milliseconds: 350)) {
      await c.seekTo(expected);
    }
    if (!c.value.isPlaying) await c.play();
  }

  void _syncPipFrames(Duration t) {
    var changed = false;
    for (final pip in _project.pipLayers) {
      if (!pip.isActiveAt(t)) continue;
      final player = _pipPlayers.putIfAbsent(pip.id, () {
        changed = true;
        return _Player(resolveMedia(pip.sourcePath));
      });
      unawaited(
        player.initialized.then((_) {
          if (player.ready && !_disposed) {
            if (changed) notifyListeners();
            return player.controller.seekTo(pip.trimStart + (t - pip.start));
          }
        }),
      );
    }
  }

  Duration _clamp(Duration t) {
    if (t < Duration.zero) return Duration.zero;
    if (t > _timeline.duration) return _timeline.duration;
    return t;
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    for (final p in [..._mainPool.values, ..._audioPlayers.values, ..._pipPlayers.values]) {
      unawaited(p.dispose());
    }
    _mainPool.clear();
    _audioPlayers.clear();
    _pipPlayers.clear();
    position.dispose();
    super.dispose();
  }
}

/// One platform player plus its initialisation state.
class _Player {
  _Player(String path)
    : controller = VideoPlayerController.file(
        File(path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      ) {
    initialized = controller
        .initialize()
        .then((_) {
          ready = true;
        })
        .catchError((Object e) {
          failed = true;
          debugPrint('Preview player failed for $path: $e');
        });
  }

  final VideoPlayerController controller;
  late final Future<void> initialized;
  bool ready = false;
  bool failed = false;

  Future<void> dispose() async {
    try {
      await initialized;
    } finally {
      await controller.dispose();
    }
  }
}
