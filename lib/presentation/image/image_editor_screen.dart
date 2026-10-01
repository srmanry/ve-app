import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/ai/photo_cutout.dart';
import '../../services/image/image_renderer.dart';
import '../../services/video/color_matrix.dart';
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/logo_picker.dart';
import 'crop_frame.dart';
import 'image_save_sheet.dart';

enum PhotoTool {
  crop('Crop', Icons.crop_rotate_rounded),
  filters('Filters', Icons.filter_vintage_outlined),
  adjust('Adjust', Icons.tune_rounded),
  retouch('Retouch', Icons.healing_rounded),
  text('Text', Icons.text_fields_rounded),
  cutout('Background', Icons.person_remove_outlined),
  logo('Logo', Icons.branding_watermark_outlined);

  const PhotoTool(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Photo editor: crop & rotate, filters, adjustments, retouch brushes
/// (heal, smooth, dodge/burn, whiten, blur), text, background removal
/// (people, on device) and logo/watermark. Saves at full quality.
class ImageEditorScreen extends ConsumerStatefulWidget {
  const ImageEditorScreen({super.key, required this.media, this.initialTool = PhotoTool.crop});
  final ImportedMedia media;
  final PhotoTool initialTool;

  @override
  ConsumerState<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends ConsumerState<ImageEditorScreen> {
  static const _previewSide = 1600;

  late PhotoTool _tool = widget.initialTool;
  ImageEdit _edit = const ImageEdit();

  /// Downsized photo as loaded, and the same with heal spots applied.
  ui.Image? _base;
  ui.Image? _preview;
  int _healGen = 0;

  // Retouch.
  RetouchTool _brush = RetouchTool.heal;
  double _brushSize = 0.025;
  double _strength = 0.6;
  final List<RetouchStroke> _redo = [];
  List<(double, double)>? _live;
  Offset? _cursor;
  bool _comparing = false;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  double _zoomStart = 1;
  bool _pinching = false;

  // Text.
  String? _textId;
  final _textField = TextEditingController();
  ui.Image? _logo;
  String? _logoRelative;
  ui.Image? _mask;
  double? _maskProgress;
  Object? _loadError;

  late final String _path = ref.read(mediaRepositoryProvider).resolve(widget.media.relativePath);
  int get _w => widget.media.info.width;
  int get _h => widget.media.info.height;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await File(_path).readAsBytes();
      final img = await ImageRenderer.decodeFile(bytes, maxSide: _previewSide);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _base = img;
        _preview = img;
      });
      if (widget.initialTool == PhotoTool.cutout) unawaited(_removeBackground());
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  @override
  void dispose() {
    if (_preview != _base) _preview?.dispose();
    _base?.dispose();
    _textField.dispose();
    _logo?.dispose();
    _mask?.dispose();
    super.dispose();
  }

  void _set(ImageEdit e) {
    final healsChanged = e.heals.length != _edit.heals.length;
    setState(() => _edit = e);
    if (healsChanged) unawaited(_reheal());
  }

  /// Re-applies heal spots to the preview (in a background isolate).
  Future<void> _reheal() async {
    final base = _base;
    if (base == null) return;
    final gen = ++_healGen;
    final healed = await ImageRenderer.applyHeals(base, _edit);
    if (!mounted || gen != _healGen) {
      if (healed != base) healed.dispose();
      return;
    }
    setState(() {
      if (_preview != _base) _preview?.dispose();
      _preview = healed;
    });
  }

  // ---------------------------------------------------------------- retouch

  void _addStroke(RetouchStroke s) {
    _redo.clear();
    _set(_edit.copyWith(retouch: [..._edit.retouch, s]));
  }

  void _undo() {
    if (_edit.retouch.isEmpty) return;
    _redo.add(_edit.retouch.last);
    _set(_edit.copyWith(retouch: _edit.retouch.sublist(0, _edit.retouch.length - 1)));
  }

  void _redoStroke() {
    if (_redo.isEmpty) return;
    final s = _redo.removeLast();
    _set(_edit.copyWith(retouch: [..._edit.retouch, s]));
  }

  /// Source-photo point under [local] (viewport coordinates), or null when
  /// outside the photo.
  (double, double)? _sourceAt(Offset local, Size size) {
    final content = (local - _pan) / _zoom;
    final u = content.dx / size.width, v = content.dy / size.height;
    if (u < 0 || v < 0 || u > 1 || v > 1) return null;
    return _edit.sourceFromOutput(u, v);
  }

  /// Brush radius on screen, in pixels.
  double _screenRadius(Size size) {
    final oriented = ImageRenderer.orientedSize(_edit, _w, _h);
    final perSource = size.width / (oriented.width * _edit.crop.width);
    return _brushSize * math.max(_w, _h) * perSource * _zoom;
  }

  RetouchStroke _strokeOf(List<(double, double)> points) =>
      RetouchStroke(tool: _brush, points: points, radius: _brushSize, strength: _strength);

  void _clampPan(Size size) {
    final minX = size.width - size.width * _zoom, minY = size.height - size.height * _zoom;
    _pan = Offset(_pan.dx.clamp(minX, 0.0), _pan.dy.clamp(minY, 0.0));
  }

  // ------------------------------------------------------------------- text

  PhotoText? get _selectedText {
    for (final t in _edit.texts) {
      if (t.id == _textId) return t;
    }
    return null;
  }

  void _addText() {
    final t = PhotoText(id: '${DateTime.now().microsecondsSinceEpoch}', text: 'Your text');
    _textField.text = t.text;
    _textField.selection = TextSelection(baseOffset: 0, extentOffset: t.text.length);
    _textId = t.id;
    _set(_edit.copyWith(texts: [..._edit.texts, t]));
  }

  void _updateText(PhotoText t) =>
      _set(_edit.copyWith(texts: [for (final x in _edit.texts) x.id == t.id ? t : x]));

  void _selectText(PhotoText? t) {
    setState(() => _textId = t?.id);
    if (t != null) _textField.text = t.text;
  }

  // ----------------------------------------------------------- background

  Future<void> _removeBackground() async {
    if (_maskProgress != null) return;
    setState(() => _maskProgress = 0);
    try {
      final mask = (await PhotoCutout(ref.read(appPathsProvider)).personMask(_path, _w, _h)).image;
      if (!mounted) {
        mask.dispose();
        return;
      }
      setState(() {
        _mask = mask;
        _maskProgress = null;
        _edit = _edit.copyWith(cutout: true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _maskProgress = null);
      await showAppError(context, e);
    }
  }

  // ------------------------------------------------------------------ logo

  Future<void> _setLogo(String relative) async {
    final abs = ref.read(mediaRepositoryProvider).resolve(relative);
    try {
      final img = await ImageRenderer.decodeFile(await File(abs).readAsBytes(), maxSide: 1024);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _logo?.dispose();
        _logo = img;
        _logoRelative = relative;
        _edit = _edit.copyWith(logo: (_edit.logo ?? ImageLogo(path: abs)).copyWithPath(abs));
      });
    } catch (e) {
      if (mounted) await showAppError(context, e);
    }
  }

  // ------------------------------------------------------------------- save

  Future<void> _save() async {
    await showImageSaveSheet(
      context,
      ref,
      baseName: '${p.basenameWithoutExtension(widget.media.displayName)}_edited',
      transparent: _edit.hasTransparency,
      outputSize: ImageRenderer.outputSize(_edit, _w, _h),
      originalBytes: widget.media.info.fileSize,
      render: () async {
        // Full-size decode only while saving, to keep memory low.
        final full = await ImageRenderer.decodeFile(await File(_path).readAsBytes());
        final healed = await ImageRenderer.applyHeals(full, _edit);
        try {
          final bytes = await ImageRenderer.renderPng(
            ImageLayers(photo: healed, logo: _logo, mask: _mask),
            _edit,
          );
          final tmp = File(
            p.join(ref.read(appPathsProvider).temp.path, 'photo_${DateTime.now().microsecondsSinceEpoch}.png'),
          );
          await tmp.writeAsBytes(bytes, flush: true);
          return tmp.path;
        } finally {
          if (healed != full) healed.dispose();
          full.dispose();
        }
      },
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return StudioTheme(
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xFF0E0F13),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E0F13),
            title: const Text('Edit photo', style: TextStyle(fontSize: 16)),
            actions: [
              IconButton(
                tooltip: 'Reset all',
                onPressed: () => setState(() => _edit = ImageEdit(logo: _edit.logo)),
                icon: const Icon(Icons.restart_alt_rounded),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FilledButton(
                  onPressed: _preview == null ? null : _save,
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _buildPreview(context)),
              _buildPanel(context),
              _buildToolBar(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final preview = _preview;
    if (_loadError != null) {
      return const Center(child: Text('This photo couldn\'t be opened.'));
    }
    if (preview == null) return const Center(child: CircularProgressIndicator());
    final cropping = _tool == PhotoTool.crop;
    // "Before": the original photo in the same frame.
    final before = ImageEdit(
      quarterTurns: _edit.quarterTurns,
      flipX: _edit.flipX,
      flipY: _edit.flipY,
      crop: _edit.crop,
    );
    final layers = _comparing
        ? ImageLayers(photo: _base!)
        : ImageLayers(photo: preview, logo: _logo, mask: _mask);
    var shown = _comparing ? before : _edit;
    final live = _live;
    if (!_comparing && live != null && live.isNotEmpty && _brush != RetouchTool.heal) {
      shown = shown.copyWith(retouch: [...shown.retouch, _strokeOf(live)]);
    }
    final oriented = ImageRenderer.orientedSize(_edit, _w, _h);
    final aspect = cropping
        ? oriented.width / oriented.height
        : (oriented.width * _edit.crop.width) / (oriented.height * _edit.crop.height);

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.biggest;
              Widget view = CustomPaint(
                size: size,
                painter: _PhotoPainter(layers, shown, ignoreCrop: cropping),
              );
              if (shown.hasTransparency && !cropping) {
                view = Stack(children: [const Positioned.fill(child: _Checkerboard()), view]);
              }
              if (cropping) {
                return CropFrame(
                  crop: _edit.crop,
                  ratio: _edit.aspect == CropAspect.original
                      ? oriented.width / oriented.height
                      : _edit.aspect.ratio,
                  photoAspect: oriented.width / oriented.height,
                  onChanged: (c) => _set(_edit.copyWith(crop: c)),
                  child: view,
                );
              }
              if (_tool == PhotoTool.retouch) return _retouchView(view, size);
              if (_tool == PhotoTool.text) return _textView(view, size);
              if (_tool == PhotoTool.logo && _edit.logo != null && _logo != null) {
                return GestureDetector(
                  onPanUpdate: (d) {
                    final l = _edit.logo!;
                    _set(_edit.copyWith(
                      logo: l.copyWith(
                        x: (l.x + d.delta.dx / size.width).clamp(0.0, 1.0),
                        y: (l.y + d.delta.dy / size.height).clamp(0.0, 1.0),
                      ),
                    ));
                  },
                  child: Stack(
                    children: [
                      view,
                      Positioned.fromRect(
                        rect: ImageRenderer.logoRect(_edit.logo!, size, _logo!.width / _logo!.height).inflate(4),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white70, width: 1.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return view;
            },
          ),
        ),
      ),
    );
  }

  /// Retouch: one finger paints (or taps a spot to heal), two fingers zoom.
  Widget _retouchView(Widget view, Size size) {
    final scheme = Theme.of(context).colorScheme;
    final cursor = _cursor;
    return ClipRect(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final pt = _sourceAt(d.localPosition, size);
          if (pt != null) _addStroke(_strokeOf([pt]));
        },
        onScaleStart: (d) {
          _pinching = d.pointerCount > 1;
          _zoomStart = _zoom;
          if (!_pinching) {
            final pt = _sourceAt(d.localFocalPoint, size);
            setState(() {
              _live = [?pt];
              _cursor = d.localFocalPoint;
            });
          }
        },
        onScaleUpdate: (d) {
          if (d.pointerCount > 1 || _pinching) {
            if (!_pinching) {
              // A second finger joined: drop the stroke, start zooming.
              _pinching = true;
              _zoomStart = _zoom;
              _live = null;
            }
            setState(() {
              final next = (_zoomStart * d.scale).clamp(1.0, 6.0);
              // Zoom around the fingers, then follow them.
              final focal = d.localFocalPoint;
              _pan = focal - (focal - _pan) * (next / _zoom) + d.focalPointDelta;
              _zoom = next;
              _clampPan(size);
              _cursor = null;
            });
            return;
          }
          final pt = _sourceAt(d.localFocalPoint, size);
          setState(() {
            _cursor = d.localFocalPoint;
            if (pt == null) return;
            final pts = _live ??= [];
            // Heal places separate spots about one radius apart.
            if (_brush == RetouchTool.heal && pts.isNotEmpty) {
              final (lx, ly) = pts.last;
              final dx = (pt.$1 - lx) * _w, dy = (pt.$2 - ly) * _h;
              if (math.sqrt(dx * dx + dy * dy) < _brushSize * math.max(_w, _h) * 1.2) return;
            }
            pts.add(pt);
          });
        },
        onScaleEnd: (_) {
          final pts = _live;
          setState(() {
            _live = null;
            _cursor = null;
          });
          if (!_pinching && pts != null && pts.isNotEmpty) _addStroke(_strokeOf(pts));
          _pinching = false;
        },
        child: Stack(
          children: [
            Transform(
              transform: Matrix4.identity()
                ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                ..scaleByDouble(_zoom, _zoom, 1, 1),
              child: view,
            ),
            if (_live != null && _brush == RetouchTool.heal)
              for (final (x, y) in _live!)
                if (_outputAt(x, y, size) case final o?)
                  Positioned(
                    left: o.dx - _screenRadius(size),
                    top: o.dy - _screenRadius(size),
                    child: IgnorePointer(child: _BrushRing(radius: _screenRadius(size), color: scheme.primary)),
                  ),
            if (cursor != null)
              Positioned(
                left: cursor.dx - _screenRadius(size),
                top: cursor.dy - _screenRadius(size),
                child: IgnorePointer(child: _BrushRing(radius: _screenRadius(size), color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  /// Viewport position of a source point (for drawing heal spots).
  Offset? _outputAt(double sx, double sy, Size size) {
    // sourceFromOutput is affine, so it is inverted from three corners.
    final o00 = _edit.sourceFromOutput(0, 0);
    final o10 = _edit.sourceFromOutput(1, 0);
    final o01 = _edit.sourceFromOutput(0, 1);
    final ax = o10.$1 - o00.$1, ay = o10.$2 - o00.$2;
    final bx = o01.$1 - o00.$1, by = o01.$2 - o00.$2;
    final det = ax * by - ay * bx;
    if (det.abs() < 1e-9) return null;
    final px = sx - o00.$1, py = sy - o00.$2;
    final u = (px * by - py * bx) / det;
    final v = (ax * py - ay * px) / det;
    return Offset(u * size.width, v * size.height) * _zoom + _pan;
  }

  /// Text: tap a label to select it, drag to move it.
  Widget _textView(Widget view, Size size) {
    final selected = _selectedText;
    PhotoText? hit(Offset p) {
      for (final t in _edit.texts.reversed) {
        if (ImageRenderer.textRect(t, size).inflate(8).contains(p)) return t;
      }
      return null;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _selectText(hit(d.localPosition)),
      onPanStart: (d) {
        final t = hit(d.localPosition);
        if (t != null && t.id != _textId) _selectText(t);
      },
      onPanUpdate: (d) {
        final t = _selectedText;
        if (t == null) return;
        _updateText(t.copyWith(
          x: (t.x + d.delta.dx / size.width).clamp(0.0, 1.0),
          y: (t.y + d.delta.dy / size.height).clamp(0.0, 1.0),
        ));
      },
      child: Stack(
        children: [
          view,
          if (selected != null)
            Positioned.fromRect(
              rect: ImageRenderer.textRect(selected, size).inflate(6),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 1.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildToolBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        height: 64,
        color: const Color(0xFF16171C),
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final t in PhotoTool.values)
              SizedBox(
                width: 70,
                child: InkWell(
                  onTap: () => setState(() => _tool = t),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(t.icon, size: 22, color: _tool == t ? scheme.primary : Colors.white70),
                      const SizedBox(height: 3),
                      Text(
                        t.label,
                        style: TextStyle(fontSize: 10.5, color: _tool == t ? scheme.primary : Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final child = switch (_tool) {
      PhotoTool.crop => _cropPanel(),
      PhotoTool.filters => _filterPanel(),
      PhotoTool.adjust => _adjustPanel(),
      PhotoTool.retouch => _retouchPanel(context),
      PhotoTool.text => _textPanel(context),
      PhotoTool.cutout => _cutoutPanel(context),
      PhotoTool.logo => _logoPanel(),
    };
    return Container(
      width: double.infinity,
      color: const Color(0xFF16171C),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 250),
      child: SingleChildScrollView(child: child),
    );
  }

  Widget _cropPanel() {
    final oriented = ImageRenderer.orientedSize(_edit, _w, _h);
    CropRect cropFor(CropAspect a, Size o) => switch (a) {
      CropAspect.free || CropAspect.original => CropRect.full,
      _ => CropRect.centered(a.ratio!, o.width, o.height),
    };
    void rotate(int by) {
      final turns = (_edit.quarterTurns + by) % 4;
      final next = _edit.copyWith(quarterTurns: turns);
      _set(next.copyWith(crop: cropFor(next.aspect, ImageRenderer.orientedSize(next, _w, _h))));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChipRow<CropAspect>(
          values: CropAspect.values,
          selected: _edit.aspect,
          label: (a) => a.label,
          onSelected: (a) => _set(_edit.copyWith(aspect: a, crop: cropFor(a, oriented))),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            PanelAction(icon: Icons.rotate_left_rounded, label: 'Left', onTap: () => rotate(3)),
            PanelAction(icon: Icons.rotate_right_rounded, label: 'Right', onTap: () => rotate(1)),
            PanelAction(icon: Icons.flip_rounded, label: 'Flip', onTap: () => _set(_edit.copyWith(flipX: !_edit.flipX))),
            PanelAction(
              icon: Icons.swap_vert_rounded,
              label: 'Flip up',
              onTap: () => _set(_edit.copyWith(flipY: !_edit.flipY)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _filterPanel() {
    final preview = _preview;
    return Column(
      children: [
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in FilterPreset.values)
                GestureDetector(
                  onTap: () => _set(_edit.copyWith(filter: f, filterStrength: 1)),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Column(
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _edit.filter == f ? Theme.of(context).colorScheme.primary : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: preview == null
                              ? null
                              : ColorFiltered(
                                  colorFilter: ColorFilter.matrix(
                                    ColorMatrix.build(f, 1, ColorAdjustments.neutral),
                                  ),
                                  child: RawImage(image: preview, fit: BoxFit.cover),
                                ),
                        ),
                        const SizedBox(height: 4),
                        Text(f.label, style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_edit.filter != FilterPreset.original)
          LabeledSlider(
            label: 'Strength',
            value: _edit.filterStrength,
            min: 0,
            max: 1,
            onChangeStart: (_) {},
            onChanged: (v) => _set(_edit.copyWith(filterStrength: v)),
            format: (v) => '${(v * 100).round()}%',
          ),
      ],
    );
  }

  Widget _adjustPanel() {
    final a = _edit.adjustments;
    Widget slider(String label, double value, ColorAdjustments Function(double) apply) => LabeledSlider(
      label: label,
      value: value,
      min: -1,
      max: 1,
      onChangeStart: (_) {},
      onChanged: (v) => _set(_edit.copyWith(adjustments: apply(v))),
      format: (v) => '${(v * 100).round()}',
    );
    return Column(
      children: [
        slider('Brightness', a.brightness, (v) => a.copyWith(brightness: v)),
        slider('Contrast', a.contrast, (v) => a.copyWith(contrast: v)),
        slider('Saturation', a.saturation, (v) => a.copyWith(saturation: v)),
        slider('Exposure', a.exposure, (v) => a.copyWith(exposure: v)),
        slider('Warmth', a.temperature, (v) => a.copyWith(temperature: v)),
        slider('Highlights', a.highlights, (v) => a.copyWith(highlights: v)),
        slider('Shadows', a.shadows, (v) => a.copyWith(shadows: v)),
        LabeledSlider(
          label: 'Vignette',
          value: _edit.vignette,
          min: 0,
          max: 1,
          onChangeStart: (_) {},
          onChanged: (v) => _set(_edit.copyWith(vignette: v)),
          format: (v) => '${(v * 100).round()}',
        ),
      ],
    );
  }

  Widget _retouchPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 64,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final t in RetouchTool.values)
                GestureDetector(
                  onTap: () => setState(() => _brush = t),
                  child: Container(
                    width: 66,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _brush == t ? scheme.primary.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _brush == t ? scheme.primary : Colors.transparent),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          switch (t) {
                            RetouchTool.heal => Icons.healing_rounded,
                            RetouchTool.smooth => Icons.face_retouching_natural_rounded,
                            RetouchTool.brighten => Icons.wb_sunny_outlined,
                            RetouchTool.darken => Icons.nightlight_outlined,
                            RetouchTool.whiten => Icons.auto_awesome_outlined,
                            RetouchTool.blur => Icons.blur_on_rounded,
                          },
                          size: 21,
                          color: _brush == t ? scheme.primary : Colors.white70,
                        ),
                        const SizedBox(height: 3),
                        Text(t.label, style: TextStyle(fontSize: 10.5, color: _brush == t ? scheme.primary : Colors.white70)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${_brush.hint}. Pinch with two fingers to zoom.',
          style: TextStyle(fontSize: 11.5, color: context.mutedColor),
        ),
        LabeledSlider(
          label: 'Size',
          value: _brushSize,
          min: 0.005,
          max: 0.12,
          onChangeStart: (_) {},
          onChanged: (v) => setState(() => _brushSize = v),
          format: (v) => '${(v * 1000).round()}',
        ),
        if (_brush.hasStrength)
          LabeledSlider(
            label: 'Strength',
            value: _strength,
            min: 0.1,
            max: 1,
            onChangeStart: (_) {},
            onChanged: (v) => setState(() => _strength = v),
            format: (v) => '${(v * 100).round()}%',
          ),
        Row(
          children: [
            IconButton(
              tooltip: 'Undo',
              onPressed: _edit.retouch.isEmpty ? null : _undo,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: _redo.isEmpty ? null : _redoStroke,
              icon: const Icon(Icons.redo_rounded),
            ),
            if (_zoom > 1)
              TextButton.icon(
                onPressed: () => setState(() {
                  _zoom = 1;
                  _pan = Offset.zero;
                }),
                icon: const Icon(Icons.zoom_out_map_rounded, size: 18),
                label: const Text('Fit'),
              ),
            const Spacer(),
            GestureDetector(
              onTapDown: (_) => setState(() => _comparing = true),
              onTapUp: (_) => setState(() => _comparing = false),
              onTapCancel: () => setState(() => _comparing = false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: _comparing ? 0.2 : 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.compare_rounded, size: 18),
                    SizedBox(width: 6),
                    Text('Hold to compare', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _textPanel(BuildContext context) {
    final t = _selectedText;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: t == null
                  ? Text(
                      _edit.texts.isEmpty ? 'Add text to your photo.' : 'Tap a text on the photo to edit it.',
                      style: TextStyle(fontSize: 12.5, color: context.mutedColor),
                    )
                  : TextField(
                      controller: _textField,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(isDense: true, hintText: 'Type your text'),
                      onChanged: (v) => _updateText(t.copyWith(text: v)),
                    ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _addText,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (t != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final font in photoFonts)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      showCheckmark: false,
                      label: Text('Aa', style: TextStyle(fontFamily: font, fontSize: 15)),
                      selected: t.font == font,
                      onSelected: (_) => _updateText(t.copyWith(font: font)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ColorSwatchRow(selected: t.color, onSelected: (c) => _updateText(t.copyWith(color: c ?? 0xFFFFFFFF))),
          LabeledSlider(
            label: 'Size',
            value: t.size,
            min: 0.03,
            max: 0.25,
            onChangeStart: (_) {},
            onChanged: (v) => _updateText(t.copyWith(size: v)),
            format: (v) => '${(v * 100).round()}',
          ),
          Wrap(
            spacing: 6,
            children: [
              FilterChip(label: const Text('Bold'), selected: t.bold, onSelected: (v) => _updateText(t.copyWith(bold: v))),
              FilterChip(label: const Text('Shadow'), selected: t.shadow, onSelected: (v) => _updateText(t.copyWith(shadow: v))),
              FilterChip(
                label: const Text('Background'),
                selected: t.background,
                onSelected: (v) => _updateText(t.copyWith(background: v)),
              ),
              ActionChip(
                avatar: Icon(Icons.delete_outline_rounded, size: 18, color: scheme.error),
                label: const Text('Delete'),
                onPressed: () {
                  _set(_edit.copyWith(texts: _edit.texts.where((x) => x.id != t.id).toList()));
                  _selectText(null);
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _cutoutPanel(BuildContext context) {
    if (_maskProgress != null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            LinearProgressIndicator(),
            SizedBox(height: 10),
            Text('Finding the person… (on your phone)'),
          ],
        ),
      );
    }
    if (_mask == null) {
      return PanelHint(
        'Removes the background behind people. Runs on your phone; nothing is uploaded.',
        action: FilledButton.icon(
          onPressed: _removeBackground,
          icon: const Icon(Icons.auto_fix_high_rounded),
          label: const Text('Remove background'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Background removed'),
          value: _edit.cutout,
          onChanged: (v) => _set(_edit.copyWith(cutout: v)),
        ),
        if (_edit.cutout) ...[
          ChipRow<CutoutBackground>(
            values: CutoutBackground.values,
            selected: _edit.background,
            label: (b) => switch (b) {
              CutoutBackground.transparent => 'Transparent',
              CutoutBackground.white => 'White',
              CutoutBackground.color => 'Color',
              CutoutBackground.blur => 'Blur',
            },
            onSelected: (b) => _set(_edit.copyWith(background: b)),
          ),
          if (_edit.background == CutoutBackground.color) ...[
            const SizedBox(height: 10),
            ColorSwatchRow(
              selected: _edit.backgroundColor,
              onSelected: (c) => _set(_edit.copyWith(backgroundColor: c ?? 0xFFFFFFFF)),
            ),
          ],
          if (_edit.background == CutoutBackground.transparent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Save as PNG or WebP to keep transparency.',
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
            ),
        ],
      ],
    );
  }

  Widget _logoPanel() {
    final logo = _edit.logo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LogoPicker(selected: _logoRelative, onSelected: _setLogo),
        if (logo != null) ...[
          const SizedBox(height: 6),
          LabeledSlider(
            label: 'Size',
            value: logo.size,
            min: 0.05,
            max: 0.8,
            onChangeStart: (_) {},
            onChanged: (v) => _set(_edit.copyWith(logo: logo.copyWith(size: v))),
            format: (v) => '${(v * 100).round()}%',
          ),
          LabeledSlider(
            label: 'Opacity',
            value: logo.opacity,
            min: 0.1,
            max: 1,
            onChangeStart: (_) {},
            onChanged: (v) => _set(_edit.copyWith(logo: logo.copyWith(opacity: v))),
            format: (v) => '${(v * 100).round()}%',
          ),
          Row(
            children: [
              Expanded(
                child: Text('Drag the logo on the photo to move it.',
                    style: TextStyle(fontSize: 12, color: context.mutedColor)),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _edit = _edit.copyWith(clearLogo: true);
                  _logoRelative = null;
                }),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Remove'),
              ),
            ],
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Pick a logo or add a new one (PNG keeps transparency).',
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ),
      ],
    );
  }
}

extension on ImageLogo {
  ImageLogo copyWithPath(String path) => ImageLogo(path: path, x: x, y: y, size: size, opacity: opacity);
}

class _PhotoPainter extends CustomPainter {
  _PhotoPainter(this.layers, this.edit, {required this.ignoreCrop});
  final ImageLayers layers;
  final ImageEdit edit;
  final bool ignoreCrop;

  @override
  void paint(Canvas canvas, Size size) =>
      ImageRenderer.paint(canvas, size, layers, edit, ignoreCrop: ignoreCrop);

  @override
  bool shouldRepaint(_PhotoPainter old) =>
      old.edit != edit ||
      old.ignoreCrop != ignoreCrop ||
      old.layers.photo != layers.photo ||
      old.layers.logo != layers.logo ||
      old.layers.mask != layers.mask;
}

/// Grey/white squares shown behind transparent areas.
class _Checkerboard extends StatelessWidget {
  const _Checkerboard();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _CheckerPainter());
}

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final a = Paint()..color = const Color(0xFFDDDDDD);
    final b = Paint()..color = const Color(0xFFFFFFFF);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), (x + y).isEven ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}

/// Brush outline shown while painting.
class _BrushRing extends StatelessWidget {
  const _BrushRing({required this.radius, required this.color});
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: radius * 2,
    height: radius * 2,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1.5),
      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2)],
    ),
  );
}
