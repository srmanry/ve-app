import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/export/export_service.dart';
import '../../services/image/image_renderer.dart';
import '../audio/audio_widgets.dart' show OptionHint, OptionLabel, ValueSlider;
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import 'image_save_sheet.dart';
import 'photo_crop_screen.dart';

/// Where the signature will be used.
enum SignatureOutput {
  online('Online form', 300, 80, maxKb: 60),
  large('Large', 600, 200),
  transparent('Transparent PNG', 0, 0);

  const SignatureOutput(this.label, this.width, this.height, {this.maxKb});
  final String label;
  final int width;
  final int height;
  final int? maxKb;

  String get detail => switch (this) {
    online => '300×80 px · JPG · max 60 KB (Teletalk, BCS, job forms)',
    large => '600×200 px · JPG · documents',
    transparent => 'Ink only, no paper - place it on PDFs and documents',
  };
}

enum InkColor {
  black('Black', 0xFF111111),
  blue('Blue', 0xFF1A3A9C),
  original('Original', null);

  const InkColor(this.label, this.color);
  final String label;
  final int? color;
}

/// Colour matrix that turns paper white and ink solid: luminance between
/// [lo] and [hi] (0 … 255) is stretched to 0 … 255, then tinted with [ink].
/// With [transparent] the paper becomes transparent instead of white.
@visibleForTesting
List<double> signatureMatrix(double lo, double hi, InkColor ink, {bool transparent = false}) {
  final k = 255 / math.max(1, hi - lo);
  const lr = 0.299, lg = 0.587, lb = 0.114;
  if (transparent) {
    final c = ink.color ?? 0xFF111111;
    final r = ((c >> 16) & 0xFF).toDouble(), g = ((c >> 8) & 0xFF).toDouble(), b = (c & 0xFF).toDouble();
    return [
      0, 0, 0, 0, r, //
      0, 0, 0, 0, g, //
      0, 0, 0, 0, b, //
      -lr * k, -lg * k, -lb * k, 0, 255 + lo * k, //
    ];
  }
  final c = ink.color;
  if (c == null) {
    // Per-channel levels keep the ink's own colour.
    return [
      k, 0, 0, 0, -lo * k, //
      0, k, 0, 0, -lo * k, //
      0, 0, k, 0, -lo * k, //
      0, 0, 0, 1, 0, //
    ];
  }
  List<double> row(int ch) {
    final inkC = ((c >> ch) & 0xFF).toDouble();
    final f = (255 - inkC) / 255;
    return [lr * k * f, lg * k * f, lb * k * f, 0, -lo * k * f + inkC];
  }

  return [...row(16), ...row(8), ...row(0), 0, 0, 0, 1, 0];
}

/// Bounding box of the ink (pixels darker than [threshold]) as a crop with
/// a small margin, or null if nothing looks like ink.
@visibleForTesting
CropRect? inkBounds(Uint8List rgba, int w, int h, double threshold) {
  var minX = w, minY = h, maxX = -1, maxY = -1;
  final colCount = List<int>.filled(w, 0), rowCount = List<int>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final l = 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
      if (l < threshold) {
        colCount[x]++;
        rowCount[y]++;
      }
    }
  }
  // Ignore specks: a row/column needs a few dark pixels to count.
  final minHits = math.max(2, (math.min(w, h) * 0.004).round());
  for (var x = 0; x < w; x++) {
    if (colCount[x] >= minHits) {
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
    }
  }
  for (var y = 0; y < h; y++) {
    if (rowCount[y] >= minHits) {
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
  }
  if (maxX <= minX || maxY <= minY) return null;
  final mx = (maxX - minX) * 0.06 + 4, my = (maxY - minY) * 0.12 + 4;
  return CropRect(
    math.max(0, minX - mx) / w,
    math.max(0, minY - my) / h,
    math.min(w.toDouble(), maxX + mx) / w,
    math.min(h.toDouble(), maxY + my) / h,
  );
}

/// Signature for online forms: photo of a signature on paper → clean white
/// paper, dark ink, cropped and sized (e.g. 300×80, under 60 KB).
class SignatureScreen extends ConsumerStatefulWidget {
  const SignatureScreen({super.key, required this.media});
  final ImportedMedia media;

  @override
  ConsumerState<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends ConsumerState<SignatureScreen> {
  ui.Image? _preview;
  CropRect _crop = CropRect.full;
  int _turns = 0;

  /// Paper level: lighter than this becomes white (0.4 … 0.95 of 255).
  double _paper = 0.72;
  InkColor _ink = InkColor.black;
  SignatureOutput _output = SignatureOutput.online;

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
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final img = await ImageRenderer.decodeFile(await File(_path).readAsBytes(), maxSide: 1400);
      if (!mounted) return img.dispose();
      setState(() => _preview = img);
      await _autoCrop();
    } catch (e) {
      if (mounted) await showAppError(context, e);
    }
  }

  double get _hi => _paper * 255;
  double get _lo => math.max(0, _hi - 110);

  Future<void> _autoCrop() async {
    final img = _preview;
    if (img == null) return;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return;
    final box = inkBounds(data.buffer.asUint8List(), img.width, img.height, (_lo + _hi) / 2);
    if (!mounted) return;
    if (box == null) {
      showSnack(context, 'No signature found - crop it by hand.');
      return;
    }
    setState(() {
      _turns = 0;
      _crop = box;
    });
  }

  ImageEdit get _geometry => ImageEdit(crop: _crop, quarterTurns: _turns);

  bool get _transparent => _output == SignatureOutput.transparent;

  /// Output size: fixed for forms, the cropped size for transparent PNGs.
  (int, int) get _outSize {
    if (!_transparent) return (_output.width, _output.height);
    final (w, h) = ImageRenderer.outputSize(_geometry, _w, _h);
    final f = math.min(1.0, 1600 / math.max(w, h));
    return (math.max(2, (w * f).round()), math.max(2, (h * f).round()));
  }

  /// Draws the cleaned signature centred in [out] (white paper unless
  /// transparent).
  void _paintSignature(Canvas canvas, Size out, ui.Image photo) {
    if (!_transparent) canvas.drawRect(Offset.zero & out, Paint()..color = Colors.white);
    final (cw, ch) = ImageRenderer.outputSize(_geometry, photo.width, photo.height);
    final pad = _transparent ? 0.0 : math.min(out.width, out.height) * 0.06;
    final avail = Size(out.width - pad * 2, out.height - pad * 2);
    final k = math.min(avail.width / cw, avail.height / ch);
    final size = Size(cw * k, ch * k);
    final rect = Offset((out.width - size.width) / 2, (out.height - size.height) / 2) & size;
    canvas.saveLayer(
      rect,
      Paint()..colorFilter = ColorFilter.matrix(signatureMatrix(_lo, _hi, _ink, transparent: _transparent)),
    );
    canvas.translate(rect.left, rect.top);
    ImageRenderer.paint(canvas, size, ImageLayers(photo: photo), _geometry);
    canvas.restore();
  }

  Future<void> _adjustCrop() async {
    final chosen = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        builder: (_) => PhotoCropScreen(path: _path, width: _w, height: _h, initial: _crop, title: 'Crop signature'),
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        _turns = 0;
        _crop = chosen;
      });
    }
  }

  Future<void> _save() async {
    final List<ExportedMedia> saved;
    try {
      saved = await runWithProgress(context, (status) async {
        final full = await ImageRenderer.decodeFile(await File(_path).readAsBytes());
        final (w, h) = _outSize;
        final String input;
        try {
          final recorder = ui.PictureRecorder();
          _paintSignature(Canvas(recorder), Size(w.toDouble(), h.toDouble()), full);
          final picture = recorder.endRecording();
          final img = await picture.toImage(w, h);
          picture.dispose();
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();
          final f = File(p.join(ref.read(appPathsProvider).temp.path, 'sig_${DateTime.now().microsecondsSinceEpoch}.png'));
          await f.writeAsBytes(data!.buffer.asUint8List(), flush: true);
          input = f.path;
        } finally {
          full.dispose();
        }
        status.value = 'Saving…';
        return ref
            .read(exportServiceProvider)
            .exportImages(
              [
                ImageExportItem(
                  input: input,
                  width: w,
                  height: h,
                  baseName: 'signature',
                  maxBytes: _output.maxKb == null ? null : _output.maxKb! * 1024,
                  deleteInput: true,
                ),
              ],
              format: _transparent ? ImageFormat.png : ImageFormat.jpg,
              quality: 92,
            )
            .result;
      }, initialStatus: 'Preparing…');
    } catch (e) {
      if (mounted) await showAppError(context, e);
      return;
    }
    await ref.read(exportsProvider.notifier).refresh();
    if (mounted) await showImageResults(context, ref, saved);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final (ow, oh) = _outSize;
    return Scaffold(
      appBar: AppBar(title: const Text('Signature')),
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
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: AspectRatio(
                    aspectRatio: ow / oh,
                    child: preview == null
                        ? const Center(child: CircularProgressIndicator())
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: scheme.outlineVariant),
                              color: _transparent ? const Color(0xFFE9E9E9) : Colors.white,
                            ),
                            child: CustomPaint(
                              painter: _FnPainter((c, s) => _paintSignature(c, s, preview)),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$ow × $oh px',
                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600, fontSize: 12.5),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Rotate',
                      onPressed: () => setState(() {
                        _turns = (_turns + 1) % 4;
                        _crop = CropRect.full;
                      }),
                      icon: const Icon(Icons.rotate_right_rounded),
                    ),
                    TextButton.icon(
                      onPressed: preview == null ? null : _autoCrop,
                      icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                      label: const Text('Auto'),
                    ),
                    TextButton.icon(
                      onPressed: preview == null ? null : _adjustCrop,
                      icon: const Icon(Icons.crop_rounded, size: 18),
                      label: const Text('Crop'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const OptionLabel('Use for'),
          ChipRow<SignatureOutput>(
            values: SignatureOutput.values,
            selected: _output,
            label: (o) => o.label,
            onSelected: (o) => setState(() => _output = o),
          ),
          OptionHint(_output.detail),
          const OptionLabel('Clean up'),
          ValueSlider(
            label: 'Paper',
            value: _paper,
            min: 0.4,
            max: 0.95,
            onChanged: (v) => setState(() => _paper = v),
            format: (v) => '${(v * 100).round()}',
          ),
          const OptionHint('Move right until the paper is pure white and shadows are gone.'),
          const OptionLabel('Ink'),
          ChipRow<InkColor>(
            values: InkColor.values,
            selected: _ink,
            label: (i) => i.label,
            onSelected: (i) => setState(() => _ink = i),
          ),
          const OptionHint('Tip: sign with a dark pen on plain white paper, in good light.'),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15),
            ),
            onPressed: preview == null ? null : _save,
            icon: const Icon(Icons.draw_rounded),
            label: const Text('Save signature'),
          ),
        ),
      ),
    );
  }
}

class _FnPainter extends CustomPainter {
  _FnPainter(this.fn);
  final void Function(Canvas, Size) fn;

  @override
  void paint(Canvas canvas, Size size) => fn(canvas, size);

  @override
  bool shouldRepaint(_FnPainter old) => true;
}
