import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/export/export_service.dart';
import '../../services/image/document_scan.dart';
import '../audio/audio_widgets.dart' show OptionHint, OptionLabel;
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';
import 'image_save_sheet.dart';
import 'scan_render.dart';

/// Scan to PDF: photos of documents → pages straightened by their corners,
/// cleaned up (paper white, text sharp) → one PDF or images.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, required this.initial});
  final List<ImportedMedia> initial;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final List<ScanPage> _pages = [];
  ScanEnhance _mode = ScanEnhance.auto;
  int _thumbGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_addMedia(widget.initial));
  }

  @override
  void dispose() {
    for (final pg in _pages) {
      pg.thumb?.dispose();
    }
    super.dispose();
  }

  Future<void> _addMedia(List<ImportedMedia> media) async {
    final repo = ref.read(mediaRepositoryProvider);
    final added = [
      for (final m in media) ScanPage(path: repo.resolve(m.relativePath), width: m.info.width, height: m.info.height),
    ];
    setState(() => _pages.addAll(added));
    for (final pg in added) {
      try {
        final quad = await ScanRenderer.detect(pg.path);
        if (quad != null) pg.quad = quad;
      } catch (_) {
        // Keep the default corners; the user can drag them.
      }
      await _refreshThumb(pg);
    }
  }

  Future<void> _refreshThumb(ScanPage pg) async {
    final gen = _thumbGen;
    try {
      final img = await ScanRenderer.render(pg, _mode, maxSide: 700);
      if (!mounted || !_pages.contains(pg) || gen != _thumbGen) {
        img.dispose();
        return;
      }
      setState(() {
        pg.thumb?.dispose();
        pg.thumb = img;
      });
    } catch (e) {
      debugPrint('Scan preview failed: $e');
    }
  }

  Future<void> _setMode(ScanEnhance m) async {
    setState(() => _mode = m);
    _thumbGen++;
    for (final pg in [..._pages]) {
      await _refreshThumb(pg);
    }
  }

  Future<void> _addPages() async {
    final more = await importPhotosForEditing(context, ref, allowCamera: true);
    if (more.isNotEmpty && mounted) await _addMedia(more);
  }

  Future<void> _editCorners(ScanPage pg) async {
    final quad = await Navigator.of(context).push<Quad>(
      MaterialPageRoute(builder: (_) => ScanCornersScreen(page: pg)),
    );
    if (quad == null || !mounted) return;
    pg.quad = quad;
    await _refreshThumb(pg);
  }

  /// Full-quality pages as temporary PNGs.
  Future<List<ImageExportItem>> _renderAll(ValueNotifier<String> status) async {
    final items = <ImageExportItem>[];
    final temp = ref.read(appPathsProvider).temp.path;
    for (var i = 0; i < _pages.length; i++) {
      status.value = 'Preparing page ${i + 1} of ${_pages.length}…';
      final img = await ScanRenderer.render(_pages[i], _mode, maxSide: 2200);
      try {
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        final f = File(p.join(temp, 'scan_${DateTime.now().microsecondsSinceEpoch}_$i.png'));
        await f.writeAsBytes(data!.buffer.asUint8List(), flush: true);
        items.add(
          ImageExportItem(
            input: f.path,
            width: img.width,
            height: img.height,
            baseName: 'scan_page_${i + 1}',
            deleteInput: true,
          ),
        );
      } finally {
        img.dispose();
      }
    }
    return items;
  }

  Future<void> _save({required bool pdf}) async {
    if (_pages.isEmpty) return;
    final List<ExportedMedia> saved;
    try {
      saved = await runWithProgress(context, (status) async {
        final items = await _renderAll(status);
        status.value = pdf ? 'Creating PDF…' : 'Saving…';
        final export = ref.read(exportServiceProvider);
        return pdf
            ? export.exportPdf(items, baseName: 'scan').result
            : export.exportImages(items, format: ImageFormat.jpg, quality: 88).result;
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
    return Scaffold(
      appBar: AppBar(title: const Text('Scan to PDF')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            '${_pages.length} page${_pages.length == 1 ? '' : 's'} · tap a page to fix its corners',
            style: TextStyle(color: context.mutedColor, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
            children: [
              for (var i = 0; i < _pages.length; i++) _pageTile(i),
              InkWell(
                onTap: _addPages,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo_outlined, color: scheme.primary, size: 30),
                      const SizedBox(height: 6),
                      Text('Add page', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const OptionLabel('Look'),
          ChipRow<ScanEnhance>(
            values: ScanEnhance.values,
            selected: _mode,
            label: (m) => m.label,
            onSelected: _setMode,
          ),
          OptionHint(switch (_mode) {
            ScanEnhance.auto => 'White paper, clear text, colours kept (stamps, photos).',
            ScanEnhance.original => 'Just straightened, no colour changes.',
            ScanEnhance.gray => 'Grayscale with white paper.',
            ScanEnhance.bw => 'Black text on white - smallest, best for printing.',
          }),
          const OptionHint('Tip: put the paper on a dark table and take the photo from straight above.'),
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
                  onPressed: _pages.isEmpty ? null : () => _save(pdf: false),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('JPG'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                  ),
                  onPressed: _pages.isEmpty ? null : () => _save(pdf: true),
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: const Text('Save PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageTile(int i) {
    final pg = _pages[i];
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _editCorners(pg),
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: const Color(0xFFF1F1F1),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                child: pg.thumb == null
                    ? const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                    : RawImage(image: pg.thumb, fit: BoxFit.contain),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                Expanded(child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
                _iconButton(Icons.chevron_left_rounded, 'Move earlier', i == 0 ? null : () => setState(() {
                  _pages.insert(i - 1, _pages.removeAt(i));
                })),
                _iconButton(Icons.chevron_right_rounded, 'Move later', i == _pages.length - 1 ? null : () => setState(() {
                  _pages.insert(i + 1, _pages.removeAt(i));
                })),
                _iconButton(Icons.rotate_right_rounded, 'Rotate', () {
                  pg.turns = (pg.turns + 1) % 4;
                  unawaited(_refreshThumb(pg));
                }),
                _iconButton(Icons.delete_outline_rounded, 'Remove', () => setState(() {
                  _pages.removeAt(i);
                  pg.thumb?.dispose();
                  pg.thumb = null;
                })),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String tip, VoidCallback? onTap) => IconButton(
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
    iconSize: 18,
    onPressed: onTap,
    icon: Icon(icon),
  );
}

/// Drag the four corners onto the edges of the paper.
class ScanCornersScreen extends StatefulWidget {
  const ScanCornersScreen({super.key, required this.page});
  final ScanPage page;

  @override
  State<ScanCornersScreen> createState() => _ScanCornersScreenState();
}

class _ScanCornersScreenState extends State<ScanCornersScreen> {
  late Quad _quad = [...widget.page.quad];
  int? _drag;
  bool _detecting = false;

  Future<void> _auto() async {
    setState(() => _detecting = true);
    final q = await ScanRenderer.detect(widget.page.path);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (q != null) _quad = q;
    });
    if (q == null) showSnack(context, 'No page edges found - drag the corners by hand.');
  }

  @override
  Widget build(BuildContext context) {
    final pg = widget.page;
    final scheme = Theme.of(context).colorScheme;
    return StudioTheme(
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0F13),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0E0F13),
          title: const Text('Page corners', style: TextStyle(fontSize: 16)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                style: FilledButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
                onPressed: () => Navigator.pop(context, _quad),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: pg.width / pg.height,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final size = box.biggest;
                        Offset at(int i) => Offset(_quad[i].$1 * size.width, _quad[i].$2 * size.height);
                        return GestureDetector(
                          onPanStart: (d) {
                            var best = 0;
                            for (var i = 1; i < 4; i++) {
                              if ((at(i) - d.localPosition).distance < (at(best) - d.localPosition).distance) best = i;
                            }
                            _drag = (at(best) - d.localPosition).distance < 60 ? best : null;
                          },
                          onPanUpdate: (d) {
                            final i = _drag;
                            if (i == null) return;
                            setState(() {
                              _quad = [..._quad];
                              _quad[i] = (
                                (d.localPosition.dx / size.width).clamp(0.0, 1.0),
                                (d.localPosition.dy / size.height).clamp(0.0, 1.0),
                              );
                            });
                          },
                          onPanEnd: (_) => _drag = null,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(child: Image.file(File(pg.path), fit: BoxFit.fill, cacheWidth: 1400)),
                              Positioned.fill(
                                child: CustomPaint(painter: _QuadPainter([for (var i = 0; i < 4; i++) at(i)], scheme.primary)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Drag each corner onto a corner of the paper.',
                        style: TextStyle(fontSize: 12.5, color: context.mutedColor),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _detecting ? null : _auto,
                      icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                      label: const Text('Auto'),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => _quad = [(0, 0), (1, 0), (1, 1), (0, 1)]),
                      icon: const Icon(Icons.fullscreen_rounded, size: 18),
                      label: const Text('Whole'),
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
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.points, this.color);
  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), path),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final pt in points) {
      canvas.drawCircle(pt, 14, Paint()..color = color.withValues(alpha: 0.35));
      canvas.drawCircle(pt, 7, Paint()..color = Colors.white);
      canvas.drawCircle(
        pt,
        7,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) => true;
}
