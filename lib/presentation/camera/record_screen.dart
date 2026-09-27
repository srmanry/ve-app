import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/storage/device_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/logo_placement.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/entities/video_effect.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/video/color_matrix.dart';
import '../editor/preview/effect_preview.dart';
import '../../services/overlay/overlay_painter.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/logo_picker.dart';

/// A take recorded in this session, with the look chosen while recording.
/// The look is applied non-destructively (as clip settings), so it can
/// still be changed in the editor.
class _Take {
  _Take(
    this.path,
    this.length,
    this.filter,
    this.filterStrength,
    this.effect,
    this.effectIntensity,
    this.speed,
  );
  final String path;
  final Duration length;
  final FilterPreset filter;
  final double filterStrength;
  final VideoEffect effect;
  final double effectIntensity;
  final double speed;
}

/// What the camera hands back: the takes as clips, plus the logo (if any)
/// to lay over them.
class RecordResult {
  const RecordResult(this.clips, this.logo);
  final List<VideoClip> clips;
  final CameraLogo? logo;
}

enum _Quality {
  hd('720p', ResolutionPreset.high),
  fullHd('1080p', ResolutionPreset.veryHigh),
  uhd('4K', ResolutionPreset.ultraHigh);

  const _Quality(this.label, this.preset);
  final String label;
  final ResolutionPreset preset;
}

/// In-app camera: record one or more takes with live filters/effects,
/// flash, zoom, focus/exposure, timer, grid and speed, then hand them to the
/// editor as ready-made clips.
///
/// Pops with a [RecordResult] (media already imported), or null if the user
/// leaves without recording.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  CameraController? _camera;
  String? _error;

  // Settings.
  _Quality _quality = _Quality.fullHd;

  /// Phones under ~6 GB RAM can't sustain 4K recording: the encoder falls
  /// behind and Android's low-memory killer closes the app. 4K is offered
  /// only when the device has the memory for it.
  bool _lowMemory = true;

  /// Recording clock for the on-screen timer; updating only this avoids
  /// rebuilding the whole camera screen several times a second.
  final _clock = ValueNotifier<Duration>(Duration.zero);
  bool _audio = true;
  FlashMode _flash = FlashMode.off;
  int _timerSeconds = 0;
  bool _grid = false;
  FilterPreset _filter = FilterPreset.original;
  double _filterStrength = 1.0;
  VideoEffect _effect = VideoEffect.none;
  double _effectIntensity = 0.6;
  CameraLogo? _logo;
  double _speed = 1.0;

  // Zoom / exposure.
  double _zoom = 1, _minZoom = 1, _maxZoom = 1, _zoomAtGestureStart = 1;
  double _exposure = 0, _minExposure = 0, _maxExposure = 0;
  Offset? _focusPoint;
  Timer? _focusHide;

  // Recording.
  bool _recording = false;
  bool _paused = false;
  int? _countdown;
  final _elapsed = Stopwatch();
  Timer? _ticker;
  final List<_Take> _takes = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _focusHide?.cancel();
    _clock.dispose();
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    // Release the camera in the background (other apps may need it).
    if (state == AppLifecycleState.inactive && camera != null) {
      if (_recording) unawaited(_stop());
      _camera = null;
      unawaited(camera.dispose());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _camera == null && _cameras.isNotEmpty) {
      unawaited(_open());
    }
  }

  Future<void> _start() async {
    final storage = const DeviceStorage();
    final total = await storage.totalMemory();
    _lowMemory = await storage.isLowMemoryDevice();
    // Very small devices start at 720p.
    if (total != null && total < 3.5 * 1024 * 1024 * 1024 && _quality == _Quality.fullHd) {
      _quality = _Quality.hd;
    }
    if (_lowMemory && _quality == _Quality.uhd) _quality = _Quality.fullHd;
    try {
      _cameras = await availableCameras().timeout(_startTimeout);
    } catch (e) {
      debugPrint('availableCameras failed: $e');
      if (mounted) setState(() => _error = _describe(e));
      return;
    }
    if (_cameras.isEmpty) {
      setState(() => _error = 'No camera was found on this device.');
      return;
    }
    _cameraIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
    if (_cameraIndex < 0) _cameraIndex = 0;
    await _open();
  }

  /// (Re)creates the controller for the current camera/quality/audio.
  Future<void> _open() async {
    final old = _camera;
    _camera = null;
    setState(() => _error = null);
    await old?.dispose();
    final controller = CameraController(
      _cameras[_cameraIndex],
      _quality.preset,
      enableAudio: _audio,
    );
    try {
      await controller.initialize().timeout(_startTimeout);
      await controller.prepareForVideoRecording();
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _minZoom;
      try {
        _minExposure = await controller.getMinExposureOffset();
        _maxExposure = await controller.getMaxExposureOffset();
      } on CameraException {
        _minExposure = _maxExposure = 0;
      }
      _exposure = 0;
      await controller.setFlashMode(_flash == FlashMode.torch ? FlashMode.torch : FlashMode.off);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      // Any failure (permission, busy camera, missing plugin, timeout) must
      // end in a clear message, never an endless spinner.
      debugPrint('Camera start failed: $e');
      await controller.dispose().catchError((Object _) {});
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  static const _startTimeout = Duration(seconds: 15);

  String _describe(Object e) {
    if (e is TimeoutException) {
      return 'The camera didn\'t respond. Close other apps that use the camera and try again.';
    }
    if (e is MissingPluginException) {
      return 'The camera isn\'t installed in this build. Fully restart the app (stop and run '
          'it again, not hot reload).';
    }
    final code = e is CameraException ? e.code.toLowerCase() : '';
    if (code.contains('access') || code.contains('permission')) {
      return 'Camera access is off. Allow Camera (and Microphone for sound) for this app '
          'in your phone\'s Settings › Apps › Permissions, then come back.';
    }
    return 'The camera couldn\'t be started. Close other apps using the camera and try again.';
  }

  // ------------------------------------------------------------ controls

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _recording) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _open();
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;
    final next = _flash == FlashMode.torch ? FlashMode.off : FlashMode.torch;
    try {
      await camera.setFlashMode(next);
      setState(() => _flash = next);
    } on CameraException {
      if (mounted) showSnack(context, 'This camera has no flash.');
    }
  }

  Future<void> _setZoom(double z) async {
    final camera = _camera;
    if (camera == null) return;
    final clamped = z.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = clamped);
    await camera.setZoomLevel(clamped);
  }

  Future<void> _focusAt(Offset local, Size size) async {
    final camera = _camera;
    if (camera == null) return;
    final point = Offset(local.dx / size.width, local.dy / size.height);
    setState(() => _focusPoint = local);
    _focusHide?.cancel();
    _focusHide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    try {
      await camera.setFocusPoint(point);
      await camera.setExposurePoint(point);
    } on CameraException {
      // Not all cameras support metering points.
    }
  }

  Future<void> _setExposure(double v) async {
    setState(() => _exposure = v);
    try {
      await _camera?.setExposureOffset(v);
    } on CameraException {
      // Ignore unsupported values.
    }
  }

  // ----------------------------------------------------------- recording

  Future<void> _onRecordPressed() async {
    if (_recording) {
      await _stop();
      return;
    }
    if (_countdown != null) {
      setState(() => _countdown = null); // cancel countdown
      return;
    }
    if (_timerSeconds > 0) {
      setState(() => _countdown = _timerSeconds);
      while (_countdown != null && _countdown! > 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || _countdown == null) return;
        setState(() => _countdown = _countdown! - 1);
      }
      if (_countdown == null) return;
      setState(() => _countdown = null);
    }
    await _begin();
  }

  Future<void> _begin() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    try {
      await camera.startVideoRecording();
      await HapticFeedback.mediumImpact();
      _elapsed
        ..reset()
        ..start();
      _clock.value = Duration.zero;
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        _clock.value = _elapsed.elapsed;
      });
      setState(() {
        _recording = true;
        _paused = false;
      });
    } on CameraException catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  Future<void> _togglePause() async {
    final camera = _camera;
    if (camera == null || !_recording) return;
    try {
      if (_paused) {
        await camera.resumeVideoRecording();
        _elapsed.start();
      } else {
        await camera.pauseVideoRecording();
        _elapsed.stop();
      }
      setState(() => _paused = !_paused);
    } on CameraException {
      if (mounted) showSnack(context, 'Pausing isn\'t supported on this device.');
    }
  }

  Future<void> _stop() async {
    final camera = _camera;
    _ticker?.cancel();
    _elapsed.stop();
    if (camera == null || !_recording) return;
    setState(() => _recording = false);
    try {
      final file = await camera.stopVideoRecording();
      await HapticFeedback.lightImpact();
      setState(
        () => _takes.add(
          _Take(
            file.path,
            _elapsed.elapsed,
            _filter,
            _filterStrength,
            _effect,
            _effectIntensity,
            _speed,
          ),
        ),
      );
    } on CameraException catch (e) {
      if (mounted) showSnack(context, 'The recording couldn\'t be saved (${e.code}).');
    }
  }

  void _discardLastTake() {
    if (_takes.isEmpty) return;
    setState(() => _takes.removeLast());
  }

  /// Imports every take and returns them as clips carrying their look.
  Future<void> _done() async {
    if (_recording) await _stop();
    if (_takes.isEmpty || !mounted) return;
    // Release the camera, encoder and microphone before the heavy work of
    // saving + opening the editor, so low-RAM phones aren't pushed over the
    // edge (Android would kill the app otherwise).
    final camera = _camera;
    setState(() {
      _saving = true;
      _camera = null;
    });
    await camera?.dispose();
    if (!mounted) return;
    final repo = ref.read(mediaRepositoryProvider);
    final clips = <VideoClip>[];
    try {
      await runWithProgress(context, (status) async {
        for (var i = 0; i < _takes.length; i++) {
          final take = _takes[i];
          status.value = 'Saving take ${i + 1} of ${_takes.length}…';
          final media = await repo.import(
            PickedMedia(name: 'Take ${i + 1}.mp4', path: take.path, deleteAfterImport: true),
            MediaKind.video,
          );
          clips.add(
            VideoClip.fromMedia(
              id: newId(),
              sourcePath: media.relativePath,
              media: media.info,
            ).copyWith(
              filter: take.filter,
              filterStrength: take.filterStrength,
              effect: take.effect,
              effectIntensity: take.effectIntensity,
              speed: take.speed,
            ),
          );
        }
      }, initialStatus: 'Saving…');
      if (mounted) Navigator.of(context).pop(RecordResult(clips, _logo));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      unawaited(_open()); // back to recording
      await showAppError(
        context,
        AppException.from(e, fallbackMessage: 'The recording couldn\'t be saved.'),
      );
    }
  }

  Future<bool> _confirmLeave() async {
    if (_takes.isEmpty && !_recording) return true;
    return confirm(
      context,
      title: 'Discard recordings?',
      message: '${_takes.length} take(s) will be lost.',
      confirmLabel: 'Discard',
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return StudioTheme(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: _error != null
                ? _ErrorView(message: _error!, onRetry: _start)
                : Column(
                    children: [
                      _topBar(),
                      Expanded(child: _preview()),
                      _lookBar(),
                      _bottomBar(),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final busy = _recording || _countdown != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            onPressed: () async {
              if (await _confirmLeave() && mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.close),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Flash',
            onPressed: _toggleFlash,
            icon: Icon(_flash == FlashMode.torch ? Icons.flash_on : Icons.flash_off),
          ),
          IconButton(
            tooltip: 'Timer',
            onPressed: busy
                ? null
                : () => setState(
                    () => _timerSeconds = switch (_timerSeconds) {
                      0 => 3,
                      3 => 10,
                      _ => 0,
                    },
                  ),
            icon: Badge(
              isLabelVisible: _timerSeconds > 0,
              label: Text('$_timerSeconds'),
              child: const Icon(Icons.timer_outlined),
            ),
          ),
          IconButton(
            tooltip: 'Logo',
            onPressed: _openLogoSheet,
            icon: Icon(
              Icons.branding_watermark_outlined,
              color: _logo != null ? AppColors.selection : null,
            ),
          ),
          IconButton(
            tooltip: 'Grid',
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(_grid ? Icons.grid_on : Icons.grid_off),
          ),
          IconButton(
            tooltip: _audio ? 'Sound on' : 'Sound off',
            onPressed: busy
                ? null
                : () {
                    setState(() => _audio = !_audio);
                    unawaited(_open());
                  },
            icon: Icon(_audio ? Icons.mic : Icons.mic_off),
          ),
          PopupMenuButton<_Quality>(
            enabled: !busy,
            tooltip: 'Quality',
            initialValue: _quality,
            onSelected: (q) {
              setState(() => _quality = q);
              unawaited(_open());
            },
            itemBuilder: (_) => [
              for (final q in _Quality.values)
                PopupMenuItem(
                  value: q,
                  enabled: !(q == _Quality.uhd && _lowMemory),
                  child: Text(
                    q == _Quality.uhd && _lowMemory
                        ? '4K (needs a phone with more memory)'
                        : q.label,
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(_quality.label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    // Camera preview is reported in landscape; show it upright.
    final ratio = 1 / camera.value.aspectRatio;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            Widget view = CameraPreview(camera);
            final matrix = ColorMatrix.build(_filter, _filterStrength, ColorAdjustments.neutral);
            if (!ColorMatrix.isIdentity(matrix)) {
              view = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: view);
            }
            if (_effect != VideoEffect.none) {
              view = EffectPreview(
                effect: _effect,
                intensity: _effectIntensity,
                outputWidth: 1080,
                time: _clock.value,
                child: view,
              );
            }
            return GestureDetector(
              onTapUp: (d) => _focusAt(d.localPosition, size),
              onScaleStart: (_) => _zoomAtGestureStart = _zoom,
              onScaleUpdate: (d) {
                if (d.pointerCount >= 2) unawaited(_setZoom(_zoomAtGestureStart * d.scale));
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(borderRadius: BorderRadius.circular(12), child: view),
                  if (_grid) const IgnorePointer(child: CustomPaint(painter: _GridPainter())),
                  if (_logo != null) _logoOverlay(_logo!, size),
                  if (_focusPoint != null) ...[
                    Positioned(
                      left: _focusPoint!.dx - 32,
                      top: _focusPoint!.dy - 32,
                      child: IgnorePointer(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            border: Border.all(color: AppColors.selection, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    if (_maxExposure > _minExposure)
                      Positioned(
                        right: 4,
                        top: 40,
                        bottom: 40,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            value: _exposure.clamp(_minExposure, _maxExposure),
                            min: _minExposure,
                            max: _maxExposure,
                            onChanged: (v) {
                              _focusHide?.cancel();
                              unawaited(_setExposure(v));
                            },
                          ),
                        ),
                      ),
                  ],
                  if (_recording)
                    Positioned(
                      top: 10,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _paused ? Colors.black54 : AppColors.danger,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: _clock,
                            builder: (_, elapsed, _) => Text(
                              '${_paused ? 'Paused ' : ''}${Formatters.duration(elapsed)}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_countdown != null)
                    Center(
                      child: Text(
                        '${_countdown!}',
                        style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w800),
                      ),
                    ),
                  // Zoom shortcuts.
                  Positioned(
                    bottom: 10,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final z in [1.0, 2.0, 5.0])
                          if (z <= _maxZoom)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(
                                  (_zoom - z).abs() < 0.05
                                      ? '${_zoom.toStringAsFixed(1)}x'
                                      : '${z.toInt()}x',
                                ),
                                selected: (_zoom - z).abs() < 0.5,
                                onSelected: (_) => _setZoom(z),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _lookBar() {
    final hasEffect = _effect != VideoEffect.none;
    final hasFilter = _filter != FilterPreset.original;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasEffect || hasFilter)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    hasEffect ? '${_effect.label} strength' : '${_filter.label} strength',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: hasEffect ? _effectIntensity : _filterStrength,
                    min: 0.05,
                    onChanged: (v) => setState(() {
                      if (hasEffect) {
                        _effectIntensity = v;
                      } else {
                        _filterStrength = v;
                      }
                    }),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${((hasEffect ? _effectIntensity : _filterStrength) * 100).round()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        _lookChips(),
      ],
    );
  }

  Widget _lookChips() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final s in const [0.5, 1.0, 2.0, 3.0])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text('${s == 0.5 ? '0.5' : s.toInt()}x'),
                selected: _speed == s,
                onSelected: (_) => setState(() => _speed = s),
              ),
            ),
          const VerticalDivider(width: 12),
          for (final f in FilterPreset.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(f.label),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
          const VerticalDivider(width: 12),
          for (final e in VideoEffect.values.where((e) => e.livePreview))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                avatar: e == VideoEffect.none ? null : const Icon(Icons.auto_fix_high, size: 16),
                label: Text(e == VideoEffect.none ? 'No effect' : e.label),
                selected: _effect == e,
                onSelected: (_) => setState(() => _effect = e),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final total = _takes.fold<Duration>(Duration.zero, (s, t) => s + t.length);
    // Three equal-width zones so nothing overflows on narrow phones.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: _takes.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_takes.length} take${_takes.length == 1 ? '' : 's'} · ${Formatters.duration(total)}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _recording ? null : _discardLastTake,
                        child: const Text('Undo take'),
                      ),
                    ],
                  ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                child: _recording
                    ? IconButton.filledTonal(
                        tooltip: _paused ? 'Resume' : 'Pause',
                        onPressed: _togglePause,
                        icon: Icon(_paused ? Icons.fiber_manual_record : Icons.pause),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _camera == null || _saving ? null : _onRecordPressed,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  padding: EdgeInsets.all(_recording ? 19 : 5),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(_recording ? 6 : 40),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 44,
                child: IconButton.filledTonal(
                  tooltip: 'Switch camera',
                  onPressed: _cameras.length < 2 || _recording ? null : _switchCamera,
                  icon: const Icon(Icons.cameraswitch_outlined),
                ),
              ),
            ],
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: _takes.isEmpty || _recording || _saving ? null : _done,
                child: const Text('Next'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Logo drawn exactly like the editor/export will (same box and spot).
  Widget _logoOverlay(CameraLogo logo, Size size) {
    final t = LogoPlacement.transformFor(logo.position, logo.scale, size.width / size.height);
    final side = OverlayPainter.stickerBaseSize(size).width * t.scale;
    return Positioned(
      left: t.x * size.width - side / 2,
      top: t.y * size.height - side / 2,
      width: side,
      height: side,
      child: IgnorePointer(
        child: Opacity(
          opacity: logo.opacity,
          child: Image.file(
            File(ref.read(mediaRepositoryProvider).resolve(logo.path)),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  Future<void> _openLogoSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) {
          void update(CameraLogo? logo) {
            setState(() => _logo = logo);
            setSheet(() {});
          }

          final logo = _logo;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Logo', style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (logo != null)
                        TextButton(onPressed: () => update(null), child: const Text('No logo')),
                    ],
                  ),
                  const Text(
                    'Shown on your recordings and added as a logo layer you can still move in the editor.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  LogoPicker(
                    selected: logo?.path,
                    onSelected: (path) => update(
                      logo == null
                          ? CameraLogo(path: path)
                          : CameraLogo(
                              path: path,
                              position: logo.position,
                              scale: logo.scale,
                              opacity: logo.opacity,
                            ),
                    ),
                  ),
                  if (logo != null) ...[
                    const SizedBox(height: 12),
                    LogoPositionChips(
                      selected: logo.position,
                      onSelected: (p) => update(logo.copyWith(position: p)),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 70, child: Text('Size')),
                        Expanded(
                          child: Slider(
                            value: logo.scale,
                            min: 0.3,
                            max: 2.5,
                            onChanged: (v) => update(logo.copyWith(scale: v)),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 70, child: Text('Opacity')),
                        Expanded(
                          child: Slider(
                            value: logo.opacity,
                            min: 0.1,
                            onChanged: (v) => update(logo.copyWith(opacity: v)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3, y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined, size: 56),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    ),
  );
}
