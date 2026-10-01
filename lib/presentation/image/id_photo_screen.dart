import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/id_photo.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/ai/photo_cutout.dart';
import '../../services/export/export_service.dart';
import '../../services/image/image_renderer.dart';
import '../audio/audio_widgets.dart' show OptionHint, OptionLabel, ValueSlider;
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import 'image_save_sheet.dart';
import 'photo_crop_screen.dart';

/// Passport / ID photos at home: the background is replaced (on device),
/// the head and shoulders are framed automatically, and a 4R print sheet
/// with several copies is ready for any photo lab.
class IdPhotoScreen extends ConsumerStatefulWidget {
  const IdPhotoScreen({super.key, required this.media});
  final ImportedMedia media;

  @override
  ConsumerState<IdPhotoScreen> createState() => _IdPhotoScreenState();
}

class _IdPhotoScreenState extends ConsumerState<IdPhotoScreen> {
  ui.Image? _preview;
  PersonMask? _mask;
  bool _finding = true;
  String? _maskNote;

  IdPhotoSize _size = IdPhotoSize.passport;
  IdBackground _bg = IdBackground.white;
  double _brightness = 0;
  bool _stamps = true;

  /// Crops the user adjusted, per photo size.
  final Map<IdPhotoSize, CropRect> _crops = {};

  late final String _path = ref.read(mediaRepositoryProvider).resolve(widget.media.relativePath);
  int get _w => widget.media.info.width;
  int get _h => widget.media.info.height;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _preview?.dispose();
    _mask?.image.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final img = await ImageRenderer.decodeFile(await File(_path).readAsBytes(), maxSide: 1400);
      if (!mounted) return img.dispose();
      setState(() => _preview = img);
    } catch (e) {
      if (mounted) await showAppError(context, e);
      return;
    }
    try {
      final mask = await PhotoCutout(ref.read(appPathsProvider)).personMask(_path, _w, _h);
      if (!mounted) return mask.image.dispose();
      setState(() {
        _mask = mask;
        _finding = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finding = false;
        _bg = IdBackground.original;
        _maskNote = AppException.from(e).message;
      });
    }
  }

  CropRect get _crop {
    final chosen = _crops[_size];
    if (chosen != null) return chosen;
    final m = _mask;
    if (m != null) {
      final auto = idPhotoCrop(m.gray, m.width, m.height, _w, _h, _size.ratio);
      if (auto != null) return auto;
    }
    final c = CropRect.centered(_size.ratio, _w.toDouble(), _h.toDouble());
    if (c.height >= 1) return c;
    final top = (1 - c.height) * 0.25;
    return CropRect(c.left, top, c.right, top + c.height);
  }

  ImageEdit get _edit {
    final color = _bg.color;
    return ImageEdit(
      crop: _crop,
      cutout: color != null && _mask != null,
      background: CutoutBackground.color,
      backgroundColor: color ?? 0xFFFFFFFF,
      adjustments: ColorAdjustments(brightness: _brightness),
    );
  }

  (int, int)? get _stampSize =>
      _size == IdPhotoSize.passport && _stamps ? (IdPhotoSize.stamp.widthPx, IdPhotoSize.stamp.heightPx) : null;

  PrintSheet get _sheet => PrintSheet.plan(_size.widthPx, _size.heightPx, stamps: _stampSize);

  Future<void> _adjustCrop() async {
    final chosen = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        builder: (_) => PhotoCropScreen(
          path: _path,
          width: _w,
          height: _h,
          initial: _crop,
          ratio: _size.ratio,
          title: _size.label,
          sizeLabel: '${_size.widthPx}×${_size.heightPx} px',
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _crops[_size] = chosen);
  }

  // ------------------------------------------------------------------ save

  /// The ID photo at full quality (crop size), as a decoded image.
  Future<ui.Image> _renderFull() async {
    final full = await ImageRenderer.decodeFile(await File(_path).readAsBytes());
    try {
      final png = await ImageRenderer.renderPng(ImageLayers(photo: full, mask: _mask?.image), _edit);
      return await ImageRenderer.decodeFile(png);
    } finally {
      full.dispose();
    }
  }

  Future<String> _writeTemp(List<int> bytes) async {
    final f = File(
      p.join(ref.read(appPathsProvider).temp.path, 'id_${DateTime.now().microsecondsSinceEpoch}.png'),
    );
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<void> _savePhoto() => _export(() async {
    final img = await _renderFull();
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return ImageExportItem(
        input: await _writeTemp(data!.buffer.asUint8List()),
        width: _size.widthPx,
        height: _size.heightPx,
        fill: true,
        dpi: _size.printable ? printDpi : null,
        maxBytes: _size.maxKb == null ? null : _size.maxKb! * 1024,
        baseName: 'photo_${_size.name}',
        deleteInput: true,
      );
    } finally {
      img.dispose();
    }
  });

  Future<void> _saveSheet() => _export(() async {
    final img = await _renderFull();
    try {
      final sheet = _sheet;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, sheet.width.toDouble(), sheet.height.toDouble()),
        Paint()..color = Colors.white,
      );
      paintSheet(canvas, sheet, img);
      final picture = recorder.endRecording();
      final out = await picture.toImage(sheet.width, sheet.height);
      picture.dispose();
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      return ImageExportItem(
        input: await _writeTemp(data!.buffer.asUint8List()),
        width: sheet.width,
        height: sheet.height,
        dpi: printDpi,
        baseName: 'print_4R_${_size.name}',
        deleteInput: true,
      );
    } finally {
      img.dispose();
    }
  });

  Future<void> _export(Future<ImageExportItem> Function() build) async {
    final List<ExportedMedia> saved;
    try {
      saved = await runWithProgress(context, (status) async {
        status.value = 'Preparing…';
        final item = await build();
        status.value = 'Saving…';
        return ref.read(exportServiceProvider).exportImages([item], format: ImageFormat.jpg, quality: 95).result;
      }, initialStatus: 'Preparing…');
    } catch (e) {
      if (mounted) await showAppError(context, e);
      return;
    }
    await ref.read(exportsProvider.notifier).refresh();
    if (mounted) await showImageResults(context, ref, saved);
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final sheet = _sheet;
    return Scaffold(
      appBar: AppBar(title: const Text('Passport photo')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Column(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280, maxWidth: 260),
                    child: AspectRatio(
                      aspectRatio: _size.ratio,
                      child: preview == null
                          ? const Center(child: CircularProgressIndicator())
                          : GestureDetector(
                              onTap: _adjustCrop,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(color: scheme.outlineVariant),
                                ),
                                child: CustomPaint(
                                  painter: _IdPainter(ImageLayers(photo: preview, mask: _mask?.image), _edit),
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
                          Text(_size.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            _size.detail,
                            style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: preview == null ? null : _adjustCrop,
                      icon: const Icon(Icons.crop_rounded, size: 18),
                      label: const Text('Adjust'),
                    ),
                  ],
                ),
                if (_finding)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('Finding the person to change the background…', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  )
                else if (_maskNote != null)
                  OptionHint('Background can\'t be changed: $_maskNote'),
              ],
            ),
          ),
          const OptionLabel('Size'),
          ChipRow<IdPhotoSize>(
            values: IdPhotoSize.values,
            selected: _size,
            label: (s) => s.label,
            onSelected: (s) => setState(() => _size = s),
          ),
          const OptionLabel('Background'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in IdBackground.values)
                ChoiceChip(
                  avatar: b.color == null
                      ? const Icon(Icons.image_outlined, size: 18)
                      : CircleAvatar(
                          backgroundColor: Color(b.color!),
                          radius: 9,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black26),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                  label: Text(b.label),
                  selected: _bg == b,
                  onSelected: b.color != null && _mask == null ? null : (_) => setState(() => _bg = b),
                ),
            ],
          ),
          const OptionHint('Most passport and visa forms ask for a plain white or light background.'),
          const OptionLabel('Light'),
          ValueSlider(
            label: 'Brightness',
            value: _brightness,
            min: -0.4,
            max: 0.4,
            onChanged: (v) => setState(() => _brightness = v),
            format: (v) => '${(v * 100).round()}',
          ),
          if (_size.printable) ...[
            const OptionLabel('Print sheet (4R · 4×6 inch)'),
            if (_size == IdPhotoSize.passport)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Add stamp-size copies', style: TextStyle(fontSize: 14)),
                value: _stamps,
                onChanged: (v) => setState(() => _stamps = v),
              ),
            if (preview != null)
              Center(
                child: SizedBox(
                  height: 220,
                  child: AspectRatio(
                    aspectRatio: sheet.width / sheet.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: CustomPaint(painter: _SheetPainter(sheet, preview, _mask?.image, _edit)),
                    ),
                  ),
                ),
              ),
            OptionHint(
              '${sheet.main.length} × ${_size.label}'
              '${sheet.extra.isEmpty ? '' : ' + ${sheet.extra.length} × Stamp'}'
              ' on one 4R print. Any photo lab can print it; cut along the grey lines.',
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                  ),
                  onPressed: preview == null || _finding ? null : _savePhoto,
                  icon: const Icon(Icons.person_rounded),
                  label: const Text('Save photo'),
                ),
              ),
              if (_size.printable) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                    ),
                    onPressed: preview == null || _finding ? null : _saveSheet,
                    icon: const Icon(Icons.print_rounded),
                    label: const Text('Print sheet'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the ID photo into each slot of [sheet] (cover-fit), with thin cut
/// guides. Used for the saved sheet and its on-screen preview.
void paintSheet(Canvas canvas, PrintSheet sheet, ui.Image photo, {double scale = 1}) {
  final guide = Paint()
    ..color = const Color(0xFFBDBDBD)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5 * scale;
  final paint = Paint()..filterQuality = FilterQuality.high;
  for (final (x, y, w, h) in [...sheet.main, ...sheet.extra]) {
    final dst = Rect.fromLTWH(x * scale, y * scale, w * scale, h * scale);
    // Centre-crop the photo to the slot's shape (stamps are a bit narrower).
    final pr = photo.width / photo.height, sr = w / h;
    final src = pr > sr
        ? Rect.fromCenter(
            center: Offset(photo.width / 2, photo.height / 2),
            width: photo.height * sr,
            height: photo.height.toDouble(),
          )
        : Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.width / sr);
    canvas.drawImageRect(photo, src, dst, paint);
    canvas.drawRect(dst, guide);
  }
}

class _IdPainter extends CustomPainter {
  _IdPainter(this.layers, this.edit);
  final ImageLayers layers;
  final ImageEdit edit;

  @override
  void paint(Canvas canvas, Size size) => ImageRenderer.paint(canvas, size, layers, edit);

  @override
  bool shouldRepaint(_IdPainter old) => true;
}

/// Miniature of the print sheet using the live preview.
class _SheetPainter extends CustomPainter {
  _SheetPainter(this.sheet, this.photo, this.mask, this.edit);
  final PrintSheet sheet;
  final ui.Image photo;
  final ui.Image? mask;
  final ImageEdit edit;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / sheet.width;
    // Paint the ID photo once at slot size, then place it in every slot.
    final (_, _, w, h) = sheet.main.first;
    final recorder = ui.PictureRecorder();
    ImageRenderer.paint(
      Canvas(recorder),
      Size(w * k * 2, h * k * 2),
      ImageLayers(photo: photo, mask: mask),
      edit,
    );
    final picture = recorder.endRecording();
    final guide = Paint()
      ..color = const Color(0xFFBDBDBD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    for (final (x, y, sw, sh) in [...sheet.main, ...sheet.extra]) {
      final dst = Rect.fromLTWH(x * k, y * k, sw * k, sh * k);
      canvas.save();
      canvas.clipRect(dst);
      canvas.translate(dst.left, dst.top);
      // Cover-fit the slot.
      final s = (dst.width / (w * k * 2)) > (dst.height / (h * k * 2))
          ? dst.width / (w * k * 2)
          : dst.height / (h * k * 2);
      canvas.translate((dst.width - w * k * 2 * s) / 2, 0);
      canvas.scale(s);
      canvas.drawPicture(picture);
      canvas.restore();
      canvas.drawRect(dst, guide);
    }
    picture.dispose();
  }

  @override
  bool shouldRepaint(_SheetPainter old) => true;
}
