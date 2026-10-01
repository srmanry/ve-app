import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/export/export_service.dart';
import '../audio/audio_widgets.dart' show OptionHint, OptionLabel;
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';
import 'image_save_sheet.dart';
import 'photo_crop_screen.dart';

/// Tools that run on many photos at once.
enum ImageBatchTool {
  compress('Compress photos', 'compressed', Icons.compress_rounded),
  convert('Convert photos', 'converted', Icons.swap_horiz_rounded),
  resize('Resize photos', 'resized', Icons.photo_size_select_large_rounded);

  const ImageBatchTool(this.title, this.suffix, this.icon);
  final String title;
  final String suffix;
  final IconData icon;
}

enum _ResizeMode {
  photoSize('Photo sizes'),
  scale('Scale'),
  custom('Custom');

  const _ResizeMode(this.label);
  final String label;
}

/// File-size goal of the Compress tool (forms often require one).
enum _SizeGoal {
  none('No limit', null),
  kb50('Under 50 KB', 50),
  kb100('Under 100 KB', 100),
  kb200('Under 200 KB', 200),
  kb500('Under 500 KB', 500),
  mb1('Under 1 MB', 1024);

  const _SizeGoal(this.label, this.kb);
  final String label;
  final int? kb;
}

/// Optional size limit of the Compress tool (long side, px).
enum _MaxSide {
  original('Original', null),
  s2048('2048 px', 2048),
  s1600('1600 px', 1600),
  s1080('1080 px', 1080);

  const _MaxSide(this.label, this.px);
  final String label;
  final int? px;
}

class ImageBatchScreen extends ConsumerStatefulWidget {
  const ImageBatchScreen({super.key, required this.tool, required this.initial});
  final ImageBatchTool tool;
  final List<ImportedMedia> initial;

  @override
  ConsumerState<ImageBatchScreen> createState() => _ImageBatchScreenState();
}

/// Size settings of one photo (each photo in Resize can differ).
class _SizeChoice {
  const _SizeChoice({
    this.mode = _ResizeMode.photoSize,
    this.preset = PhotoSizePreset.passport,
    this.scale = ResizePreset.fullHd,
    this.customW = '',
    this.customH = '',
    this.customKb = '',
    this.unit = SizeUnit.px,
    this.fill = true,
  });

  final _ResizeMode mode;
  final PhotoSizePreset preset;
  final ResizePreset scale;
  final String customW;
  final String customH;
  final String customKb;
  final SizeUnit unit;
  final bool fill;

  _SizeChoice copyWith({
    _ResizeMode? mode,
    PhotoSizePreset? preset,
    ResizePreset? scale,
    String? customW,
    String? customH,
    String? customKb,
    SizeUnit? unit,
    bool? fill,
  }) => _SizeChoice(
    mode: mode ?? this.mode,
    preset: preset ?? this.preset,
    scale: scale ?? this.scale,
    customW: customW ?? this.customW,
    customH: customH ?? this.customH,
    customKb: customKb ?? this.customKb,
    unit: unit ?? this.unit,
    fill: fill ?? this.fill,
  );

  /// Custom size from the text fields, or null while incomplete/invalid.
  ResizeTarget? get custom {
    final w = double.tryParse(customW.trim());
    final h = double.tryParse(customH.trim());
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    final pw = toPixels(w, unit), ph = toPixels(h, unit);
    if (pw < 16 || ph < 16 || pw > 8000 || ph > 8000) return null;
    final kb = int.tryParse(customKb.trim());
    return ResizeTarget(
      width: pw,
      height: ph,
      fill: fill,
      dpi: unit == SizeUnit.px ? null : printDpi,
      maxBytes: kb == null || kb <= 0 ? null : kb * 1024,
    );
  }

  /// Short name for the thumbnail badge.
  String get short => switch (mode) {
    _ResizeMode.photoSize => switch (preset) {
      PhotoSizePreset.passport => 'Passport',
      PhotoSizePreset.square2in => '2×2 in',
      PhotoSizePreset.stamp => 'Stamp',
      PhotoSizePreset.jobPhoto => 'Online',
      PhotoSizePreset.signature => 'Signature',
      PhotoSizePreset.print3r => '3R',
      PhotoSizePreset.print4r => '4R',
    },
    _ResizeMode.scale => scale.label,
    _ResizeMode.custom => 'Custom',
  };

  /// Full name for the preview caption.
  String get title => switch (mode) {
    _ResizeMode.photoSize => preset.label,
    _ResizeMode.scale => 'Scale ${scale.label}',
    _ResizeMode.custom => 'Custom size',
  };
}

class _ImageBatchScreenState extends ConsumerState<ImageBatchScreen> {
  late final List<ImportedMedia> _photos = [...widget.initial];
  late ImageFormat _format = widget.tool == ImageBatchTool.convert
      ? ImageFormat.png
      : ImageFormat.jpg;
  late int _quality = widget.tool == ImageBatchTool.compress ? 70 : 90;
  _MaxSide _maxSide = _MaxSide.original;
  _SizeGoal _goal = _SizeGoal.none;

  /// Size per photo (Resize), keyed by photo path.
  final Map<String, _SizeChoice> _choices = {};

  /// Fallback when there are no photos; also the last size picked.
  _SizeChoice _lastChoice = const _SizeChoice();
  int _selected = 0;
  final _customW = TextEditingController();
  final _customH = TextEditingController();
  final _customKb = TextEditingController();

  /// Chosen part per photo, with the frame shape it was made for.
  final Map<String, (CropRect, double?)> _crops = {};
  ImageExportJob? _job;
  double _progress = 0;
  StreamSubscription<ImageExportProgress>? _sub;

  bool get _isResize => widget.tool == ImageBatchTool.resize;

  @override
  void initState() {
    super.initState();
    // Every photo owns its size, so changing one never moves another.
    for (final m in _photos) {
      _choices[m.relativePath] = _lastChoice;
    }
    _loadFields();
  }

  @override
  void dispose() {
    _customW.dispose();
    _customH.dispose();
    _customKb.dispose();
    unawaited(_sub?.cancel());
    _job?.cancel();
    super.dispose();
  }

  String _abs(ImportedMedia m) => ref.read(mediaRepositoryProvider).resolve(m.relativePath);

  _SizeChoice _choiceOf(ImportedMedia m) => _choices[m.relativePath] ?? _lastChoice;

  ImportedMedia? get _current =>
      _photos.isEmpty ? null : _photos[_selected.clamp(0, _photos.length - 1)];

  _SizeChoice get _choice {
    final m = _current;
    return m == null ? _lastChoice : _choiceOf(m);
  }

  /// Changes the selected photo's size.
  void _setChoice(_SizeChoice c) => setState(() {
    final m = _current;
    if (m != null) _choices[m.relativePath] = c;
    _lastChoice = c;
  });

  void _applyToAll() {
    final c = _choice;
    setState(() {
      for (final m in _photos) {
        _choices[m.relativePath] = c;
      }
    });
    showSnack(context, '${c.title} set for all ${_photos.length} photos');
  }

  void _select(int i) {
    setState(() => _selected = i);
    _loadFields();
  }

  /// Fills the custom-size fields from the selected photo.
  void _loadFields() {
    final c = _choice;
    _customW.text = c.customW;
    _customH.text = c.customH;
    _customKb.text = c.customKb;
  }

  /// Target for a source of [w]×[h] pixels.
  ResizeTarget _targetForSize(int w, int h, _SizeChoice c) {
    ResizeTarget plain((int, int) size) =>
        ResizeTarget(width: size.$1, height: size.$2, fill: false);
    switch (widget.tool) {
      case ImageBatchTool.resize:
        return switch (c.mode) {
          _ResizeMode.scale => plain(c.scale.apply(w, h)),
          _ResizeMode.photoSize => c.preset.targetFor(w, h),
          _ResizeMode.custom => c.custom ?? plain((w, h)),
        };
      case ImageBatchTool.compress:
        final px = _maxSide.px;
        final (cw, ch) = px == null ? (w, h) : fitLongSide(w, h, px);
        final kb = _goal.kb;
        return ResizeTarget(width: cw, height: ch, fill: false, maxBytes: kb == null ? null : kb * 1024);
      case ImageBatchTool.convert:
        return plain((w, h));
    }
  }

  /// Shape the crop frame must keep (exact-size targets), or null = free.
  double? _lockRatio(ImportedMedia m) {
    final t = _targetForSize(m.info.width, m.info.height, _choiceOf(m));
    return t.fill ? t.width / t.height : null;
  }

  /// The part the user chose, if it still fits the current target shape.
  CropRect? _cropFor(ImportedMedia m) {
    if (!_isResize) return null;
    final saved = _crops[m.relativePath];
    if (saved == null) return null;
    final lock = _lockRatio(m);
    if (lock != saved.$2 && (lock == null || saved.$2 == null || (lock - saved.$2!).abs() > 1e-3)) {
      return null;
    }
    return saved.$1;
  }

  /// Source size after the chosen crop.
  (int, int) _sourceSize(ImportedMedia m) {
    final c = _cropFor(m);
    final w = m.info.width, h = m.info.height;
    if (c == null) return (w, h);
    return ((w * c.width).round().clamp(1, w), (h * c.height).round().clamp(1, h));
  }

  ResizeTarget _targetFor(ImportedMedia m) {
    final (w, h) = _sourceSize(m);
    return _targetForSize(w, h, _choiceOf(m));
  }

  (int, int) _sizeFor(ImportedMedia m) {
    final (w, h) = _sourceSize(m);
    return _targetFor(m).sizeFor(w, h);
  }

  /// The part of [m] that will be kept: the user's choice, or the same
  /// framing the automatic crop uses for exact sizes.
  CropRect _visibleCrop(ImportedMedia m) {
    final chosen = _cropFor(m);
    if (chosen != null) return chosen;
    final w = m.info.width, h = m.info.height;
    final lock = _lockRatio(m);
    if (lock == null) return CropRect.full;
    final c = CropRect.centered(lock, w.toDouble(), h.toDouble());
    if (c.height >= 1) return c;
    final top = (1 - c.height) * _targetForSize(w, h, _choiceOf(m)).anchorY;
    return CropRect(c.left, top, c.right, top + c.height);
  }

  Future<void> _editCrop(ImportedMedia m) async {
    final w = m.info.width, h = m.info.height;
    final lock = _lockRatio(m);
    final (tw, th) = _sizeFor(m);
    final chosen = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        builder: (_) => PhotoCropScreen(
          path: _abs(m),
          width: w,
          height: h,
          initial: _visibleCrop(m),
          ratio: lock,
          title: _choiceOf(m).title,
          sizeLabel: lock != null ? '$tw×$th px' : null,
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _crops[m.relativePath] = (chosen, lock));
  }

  Future<void> _add() async {
    final more = await importPhotosForEditing(context, ref);
    if (more.isEmpty || !mounted) return;
    final inherit = _choice;
    setState(() {
      for (final m in more) {
        _choices[m.relativePath] = inherit;
      }
      _photos.addAll(more);
    });
    _select(_photos.length - more.length);
  }

  void _remove(int i) {
    setState(() {
      _photos.removeAt(i);
      if (_selected >= _photos.length) _selected = math.max(0, _photos.length - 1);
    });
    _loadFields();
  }

  Future<void> _run() async {
    if (_photos.isEmpty) {
      showSnack(context, 'Add some photos first.');
      return;
    }
    if (_isResize) {
      final bad = _photos.indexWhere((m) {
        final c = _choiceOf(m);
        return c.mode == _ResizeMode.custom && c.custom == null;
      });
      if (bad >= 0) {
        _select(bad);
        showSnack(context, 'Photo ${bad + 1}: enter a width and height (16 - 8000 px).');
        return;
      }
    }
    final items = [
      for (final m in _photos)
        () {
          final t = _targetFor(m);
          final (w, h) = _sizeFor(m);
          final c = _choiceOf(m);
          final suffix = _isResize
              ? (c.mode == _ResizeMode.photoSize
                    ? c.short.toLowerCase().replaceAll(' ', '')
                    : widget.tool.suffix)
              : widget.tool.suffix;
          return ImageExportItem(
            input: _abs(m),
            width: w,
            height: h,
            crop: _cropFor(m),
            fill: t.fill,
            anchorY: t.anchorY,
            dpi: t.dpi,
            maxBytes: t.maxBytes,
            baseName: '${p.basenameWithoutExtension(m.displayName)}_$suffix',
          );
        }(),
    ];
    final job = ref
        .read(exportServiceProvider)
        .exportImages(items, format: _format, quality: _quality);
    setState(() {
      _job = job;
      _progress = 0;
    });
    _sub = job.progress.listen((pr) {
      if (mounted) setState(() => _progress = pr.fraction);
    });
    try {
      final saved = await job.result;
      await ref.read(exportsProvider.notifier).refresh();
      if (!mounted) return;
      setState(() => _job = null);
      final original = _photos.fold<int>(0, (sum, m) => sum + m.info.fileSize);
      await showImageResults(
        context,
        ref,
        saved,
        originalBytes: saved.length == _photos.length && !_isResize ? original : 0,
        failed: _photos.length - saved.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _job = null);
      if (!AppException.from(e).isCancellation) await showAppError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _job != null;
    final originalTotal = _photos.fold<int>(0, (sum, m) => sum + m.info.fileSize);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.tool.title)),
      body: AbsorbPointer(
        absorbing: running,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              '${_photos.length} photo${_photos.length == 1 ? '' : 's'} · ${Formatters.fileSize(originalTotal)}',
              style: TextStyle(color: context.mutedColor, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var i = 0; i < _photos.length; i++) _thumb(i),
                InkWell(
                  onTap: _add,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
                    ),
                    child: Icon(Icons.add_photo_alternate_outlined, color: scheme.primary),
                  ),
                ),
              ],
            ),
            if (_isResize && _current != null) _preview(context, _current!),
            ..._options(context),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: running
              ? Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Saving… ${(_progress * 100).floor()}%',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _progress,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(onPressed: () => _job?.cancel(), child: const Text('Stop')),
                  ],
                )
              : FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    textStyle: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  onPressed: _photos.isEmpty ? null : _run,
                  icon: Icon(widget.tool.icon),
                  label: Text(
                    switch (widget.tool) {
                          ImageBatchTool.compress => 'Compress',
                          ImageBatchTool.convert => 'Convert to ${_format.label}',
                          ImageBatchTool.resize => 'Resize',
                        } +
                        (_photos.length > 1 ? ' ${_photos.length} photos' : ''),
                  ),
                ),
        ),
      ),
    );
  }

  /// Big preview of the selected photo: exactly the part that is kept.
  Widget _preview(BuildContext context, ImportedMedia m) {
    final scheme = Theme.of(context).colorScheme;
    final (w, h) = _sizeFor(m);
    final c = _choiceOf(m);
    final idx = _photos.indexOf(m);
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230, maxWidth: 300),
              child: AspectRatio(
                aspectRatio: w / h,
                child: GestureDetector(
                  onTap: () => _editCrop(m),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _CroppedThumb(
                      path: _abs(m),
                      width: m.info.width,
                      height: m.info.height,
                      crop: _visibleCrop(m),
                      cacheWidth: 900,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _photos.length > 1 ? 'Photo ${idx + 1} · ${c.title}' : c.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                    Text(
                      '$w × $h px',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => _editCrop(m),
                icon: const Icon(Icons.crop_rounded, size: 18),
                label: const Text('Adjust crop'),
              ),
            ],
          ),
          if (_photos.length > 1)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Tap another photo to give it its own size.',
                    style: TextStyle(fontSize: 11.5, color: context.mutedColor),
                  ),
                ),
                TextButton(onPressed: _applyToAll, child: const Text('Apply to all')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _thumb(int i) {
    final m = _photos[i];
    final (w, h) = _sizeFor(m);
    final changed = w != m.info.width || h != m.info.height;
    final selected = _isResize && i == _selected;
    final cropped = _cropFor(m) != null;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: _isResize ? () => _select(i) : null,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: selected ? Border.all(color: scheme.primary, width: 2.5) : null,
            ),
            padding: EdgeInsets.all(selected ? 2 : 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(selected ? 9 : 12),
              child: _isResize
                  ? _CroppedThumb(
                      path: _abs(m),
                      width: m.info.width,
                      height: m.info.height,
                      crop: _visibleCrop(m),
                    )
                  : Image.file(File(_abs(m)), fit: BoxFit.cover, cacheWidth: 220),
            ),
          ),
        ),
        if (_isResize)
          Positioned(
            left: 4,
            top: 4,
            child: GestureDetector(
              onTap: () => _editCrop(m),
              child: CircleAvatar(
                radius: 10,
                backgroundColor: cropped ? scheme.primary : Colors.black54,
                child: const Icon(Icons.crop_rounded, size: 12, color: Colors.white),
              ),
            ),
          ),
        Positioned(
          left: 5,
          right: 5,
          bottom: 5,
          // Taps go through to the photo underneath.
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _isResize
                    ? '${_choiceOf(m).short}\n$w×$h'
                    : (changed ? '$w×$h' : '${m.info.width}×${m.info.height}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 8.5, height: 1.15),
              ),
            ),
          ),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: InkWell(
            onTap: () => _remove(i),
            child: const CircleAvatar(
              radius: 10,
              backgroundColor: Colors.black54,
              child: Icon(Icons.close_rounded, size: 13, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _options(BuildContext context) {
    final formats = ImageFormatOptions(
      format: _format,
      quality: _quality,
      onFormat: (f) => setState(() => _format = f),
      onQuality: (q) => setState(() => _quality = q),
    );
    switch (widget.tool) {
      case ImageBatchTool.compress:
        return [
          const OptionLabel('File size'),
          ChipRow<_SizeGoal>(
            values: _SizeGoal.values,
            selected: _goal,
            label: (g) => g.label,
            onSelected: (g) => setState(() => _goal = g),
          ),
          OptionHint(
            _goal.kb == null
                ? 'Set a limit when a form asks for one, e.g. "photo must be under 100 KB".'
                : 'Quality and, if needed, dimensions are lowered until each photo is ${_goal.label.toLowerCase()}.',
          ),
          const OptionLabel('Format'),
          ChipRow<ImageFormat>(
            values: const [ImageFormat.jpg, ImageFormat.webp],
            selected: _format,
            label: (f) => f.label,
            onSelected: (f) => setState(() => _format = f),
          ),
          OptionHint(
            _format == ImageFormat.webp
                ? 'WebP is about 30% smaller than JPG at the same quality.'
                : 'JPG opens everywhere.',
          ),
          OptionLabel(
            'Quality',
            trailing: Text('$_quality%', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Slider(
            value: _quality.toDouble(),
            min: 10,
            max: 95,
            divisions: 17,
            label: '$_quality%',
            onChanged: (v) => setState(() => _quality = v.round()),
          ),
          const OptionHint('70% looks the same on a phone screen at a fraction of the size.'),
          const OptionLabel('Max size'),
          ChipRow<_MaxSide>(
            values: _MaxSide.values,
            selected: _maxSide,
            label: (m) => m.label,
            onSelected: (m) => setState(() => _maxSide = m),
          ),
          const OptionHint(
            'Smaller dimensions shrink the file even more. Photos are never enlarged.',
          ),
        ];
      case ImageBatchTool.convert:
        return [const SizedBox(height: 18), formats];
      case ImageBatchTool.resize:
        final c = _choice;
        return [
          OptionLabel(_photos.length > 1 ? 'Size for photo ${_selected + 1}' : 'Size'),
          SegmentedButton<_ResizeMode>(
            showSelectedIcon: false,
            segments: [
              for (final m in _ResizeMode.values) ButtonSegment(value: m, label: Text(m.label)),
            ],
            selected: {c.mode},
            onSelectionChanged: (v) => _setChoice(c.copyWith(mode: v.first)),
          ),
          ...switch (c.mode) {
            _ResizeMode.photoSize => [
              const SizedBox(height: 12),
              for (final ps in PhotoSizePreset.values)
                _SizeTile(
                  selected: ps == c.preset,
                  title: ps.label,
                  size: ps.sizeLabel,
                  usage: ps.usage,
                  onTap: () => _setChoice(c.copyWith(preset: ps)),
                ),
              OptionHint(
                c.preset.id
                    ? 'Cropped to the exact shape, keeping the head. For a white background '
                          'use "Remove Photo BG" → White first.'
                    : 'Cropped to the exact shape. Printed at $printDpi DPI.',
              ),
            ],
            _ResizeMode.scale => [
              const SizedBox(height: 12),
              ChipRow<ResizePreset>(
                values: ResizePreset.values,
                selected: c.scale,
                label: (r) => r.label,
                onSelected: (r) => _setChoice(c.copyWith(scale: r)),
              ),
              const OptionHint(
                'Pixel sizes set the longer side; the shape is kept. Photos are never enlarged.',
              ),
            ],
            _ResizeMode.custom => _customFields(context, c),
          },
          const SizedBox(height: 18),
          formats,
        ];
    }
  }

  List<Widget> _customFields(BuildContext context, _SizeChoice c) {
    final custom = c.custom;
    InputDecoration deco(String label, {String? suffix}) => InputDecoration(
      labelText: label,
      suffixText: suffix,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    );
    return [
      const SizedBox(height: 14),
      ChipRow<SizeUnit>(
        values: SizeUnit.values,
        selected: c.unit,
        label: (u) => u.label,
        onSelected: (u) => _setChoice(c.copyWith(unit: u)),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _customW,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: deco('Width', suffix: c.unit.label),
              onChanged: (v) => _setChoice(_choice.copyWith(customW: v)),
            ),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('×')),
          Expanded(
            child: TextField(
              controller: _customH,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: deco('Height', suffix: c.unit.label),
              onChanged: (v) => _setChoice(_choice.copyWith(customH: v)),
            ),
          ),
        ],
      ),
      if (c.unit != SizeUnit.px && custom != null)
        OptionHint('= ${custom.width} × ${custom.height} px at $printDpi DPI'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Crop to exact size', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          c.fill ? 'Fills the size; edges may be trimmed' : 'Fits inside; the shape is kept',
          style: TextStyle(fontSize: 12, color: context.mutedColor),
        ),
        value: c.fill,
        onChanged: (v) => _setChoice(c.copyWith(fill: v)),
      ),
      TextField(
        controller: _customKb,
        keyboardType: TextInputType.number,
        decoration: deco('Max file size (optional)', suffix: 'KB'),
        onChanged: (v) => _setChoice(_choice.copyWith(customKb: v)),
      ),
      const OptionHint('Quality is lowered automatically to stay under the limit (JPG / WebP).'),
    ];
  }
}

/// A selectable photo-size row: name, size and what it's used for.
class _SizeTile extends StatelessWidget {
  const _SizeTile({
    required this.selected,
    required this.title,
    required this.size,
    required this.usage,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String size;
  final String usage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.08) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : context.mutedColor,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              size,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(usage, style: TextStyle(fontSize: 12, color: context.mutedColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows only [crop] of a photo, filling the square (like BoxFit.cover).
class _CroppedThumb extends StatelessWidget {
  const _CroppedThumb({
    required this.path,
    required this.width,
    required this.height,
    required this.crop,
    this.cacheWidth = 400,
  });

  final String path;
  final int width;
  final int height;
  final CropRect crop;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final side = box.biggest;
      final rw = width * crop.width, rh = height * crop.height;
      final k = math.max(side.width / rw, side.height / rh);
      final imgW = width * k, imgH = height * k;
      return ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: -crop.left * imgW + (side.width - rw * k) / 2,
              top: -crop.top * imgH + (side.height - rh * k) / 2,
              width: imgW,
              height: imgH,
              child: Image.file(
                File(path),
                fit: BoxFit.fill,
                cacheWidth: cacheWidth,
                gaplessPlayback: true,
              ),
            ),
          ],
        ),
      );
    },
  );
}
