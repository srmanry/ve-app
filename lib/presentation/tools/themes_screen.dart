import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/video_effect.dart';
import '../../domain/entities/video_theme.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/usecases/build_themed_project.dart';
import '../../services/video/color_matrix.dart';
import '../editor/editor_screen.dart';
import '../editor/panels/panel_common.dart';
import '../editor/preview/effect_preview.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';

/// Themes: the user's own photos and/or videos + a one-tap style + title +
/// music → a finished-looking video, opened in the editor for tweaks.
class ThemesScreen extends ConsumerStatefulWidget {
  /// Opens on the theme gallery; media can be added afterwards.
  const ThemesScreen({super.key, this.media = const []});
  final List<ImportedMedia> media;

  @override
  ConsumerState<ThemesScreen> createState() => _ThemesScreenState();
}

class _ThemesScreenState extends ConsumerState<ThemesScreen> {
  static const _aspects = [
    AspectRatioPreset.portrait9x16,
    AspectRatioPreset.square1x1,
    AspectRatioPreset.portrait4x5,
    AspectRatioPreset.landscape16x9,
    AspectRatioPreset.original,
  ];

  late final List<ImportedMedia> _media = [...widget.media];
  VideoTheme _theme = VideoTheme.classic;
  final _title = TextEditingController();
  final _ending = TextEditingController();
  ImportedMedia? _music;
  bool _fitToMusic = false;
  double _originalSound = 1.0;
  CanvasSettings _canvas = const CanvasSettings(
    aspectRatio: AspectRatioPreset.portrait9x16,
    fit: CanvasFit.fill,
  );
  bool _creating = false;

  bool get _hasPhotos => _media.any((m) => m.info.isStillImage);
  bool get _hasVideoSound => _media.any((m) => !m.info.isStillImage && m.info.hasAudio);

  @override
  void dispose() {
    _title.dispose();
    _ending.dispose();
    super.dispose();
  }

  BuildThemedProject get _builder => const BuildThemedProject();

  Duration get _length => _media.isEmpty
      ? Duration.zero
      : ProjectTimeline(
          _builder(
            media: _media,
            theme: _theme,
            canvas: _canvas,
            exportSettings: ref.read(settingsProvider).defaultExport,
            music: _music,
            fitPhotosToMusic: _fitToMusic,
          ),
        ).duration;

  Future<void> _addMore() async {
    final more = await importVideos(context, ref, allowPhotos: true);
    if (more.isNotEmpty) setState(() => _media.addAll(more));
  }

  Future<void> _pickMusic() async {
    final audio = await importAudio(context, ref);
    if (audio.isEmpty) return;
    setState(() {
      _music = audio.first;
      // Music usually replaces the camera sound; keep a little of it.
      if (_hasVideoSound && _originalSound == 1.0) _originalSound = 0.3;
    });
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final project = _builder(
        media: _media,
        theme: _theme,
        canvas: _canvas,
        exportSettings: ref.read(settingsProvider).defaultExport,
        title: _title.text,
        ending: _ending.text,
        music: _music,
        fitPhotosToMusic: _fitToMusic,
        originalSoundVolume: _hasVideoSound ? _originalSound : 1.0,
      );
      await ref.read(projectRepositoryProvider).save(project);
      await ref.read(projectsProvider.notifier).refresh();
      if (!mounted) return;
      await Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      await showAppError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = _media.isEmpty ? null : _media.first;
    final music = _music;
    return Scaffold(
      appBar: AppBar(title: const Text('Themes')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Large preview of the chosen theme on the user's media.
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: AspectRatio(
                        aspectRatio: _canvas.aspectRatio.ratio ?? first?.info.aspectRatio ?? 9 / 16,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: _ThemedFrame(
                            media: first,
                            theme: _theme,
                            fill: _canvas.fit == CanvasFit.fill,
                            title: _title.text.trim().isEmpty ? _theme.label : _title.text.trim(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (first == null)
                    Text(
                      'See how each theme looks, pick one, then add your own photos or videos.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.mutedColor),
                    )
                  else
                    Row(
                      children: [
                        Text(
                          '${_media.length} item${_media.length == 1 ? '' : 's'} · '
                          '${Formatters.duration(_length)}',
                          style: TextStyle(color: context.mutedColor),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _addMore,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Add more'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  const _Label('Choose a theme'),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 130,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: VideoTheme.values.length,
                    itemBuilder: (context, i) {
                      final theme = VideoTheme.values[i];
                      final selected = theme == _theme;
                      return GestureDetector(
                        onTap: () => setState(() => _theme = theme),
                        child: Column(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: selected
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(9),
                                  child: _ThemedFrame(
                                    media: first,
                                    theme: theme,
                                    fill: true,
                                    title: 'Aa',
                                    thumbnail: true,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              theme.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  const _Label('Title (optional)'),
                  TextField(
                    controller: _title,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Summer in Cox\'s Bazar',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ending,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Ending text (optional), e.g. Thanks for watching',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _Label('Music'),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        music == null ? Icons.library_music_outlined : Icons.music_note,
                        color: AppColors.audioTrack,
                      ),
                      title: Text(
                        music == null
                            ? 'Add your music'
                            : p.basenameWithoutExtension(music.displayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        music == null
                            ? 'MP3, M4A, WAV or AAC from your phone'
                            : Formatters.duration(music.info.duration),
                      ),
                      trailing: music == null
                          ? const Icon(Icons.chevron_right)
                          : IconButton(
                              tooltip: 'Remove music',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _music = null;
                                _fitToMusic = false;
                                _originalSound = 1.0;
                              }),
                            ),
                      onTap: _pickMusic,
                    ),
                  ),
                  if (music != null && _hasPhotos)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fit photos to the song'),
                      subtitle: const Text('The video ends when the music ends'),
                      value: _fitToMusic,
                      onChanged: (v) => setState(() => _fitToMusic = v),
                    ),
                  if (_hasVideoSound)
                    LabeledSlider(
                      label: 'Video sound',
                      value: _originalSound,
                      min: 0,
                      max: 1,
                      format: (v) => '${(v * 100).round()}%',
                      onChangeStart: (_) {},
                      onChanged: (v) => setState(() => _originalSound = v),
                    ),
                  const SizedBox(height: 12),
                  const _Label('Shape'),
                  ChipRow<AspectRatioPreset>(
                    values: _aspects,
                    selected: _canvas.aspectRatio,
                    label: (a) => a.label,
                    onSelected: (a) => setState(() => _canvas = _canvas.copyWith(aspectRatio: a)),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<CanvasFit>(
                    segments: const [
                      ButtonSegment(value: CanvasFit.fill, label: Text('Fill frame')),
                      ButtonSegment(value: CanvasFit.fit, label: Text('Show all')),
                    ],
                    selected: {_canvas.fit},
                    onSelectionChanged: (v) =>
                        setState(() => _canvas = _canvas.copyWith(fit: v.first)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _creating ? null : (first == null ? _addMore : _create),
                  icon: _creating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          first == null ? Icons.add_photo_alternate_outlined : Icons.auto_awesome,
                        ),
                  label: Text(
                    first == null ? 'Add photos or videos' : 'Create ${_theme.label} video',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}

/// The user's first photo/video frame with a theme's look and title font.
class _ThemedFrame extends ConsumerWidget {
  const _ThemedFrame({
    required this.media,
    required this.theme,
    required this.fill,
    required this.title,
    this.thumbnail = false,
  });

  /// Null before the user has added anything: a built-in sample is shown.
  final ImportedMedia? media;
  final VideoTheme theme;
  final bool fill;
  final String title;
  final bool thumbnail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = this.media;
    final path = media == null ? '' : ref.read(mediaRepositoryProvider).resolve(media.relativePath);
    final Widget picture = media == null
        ? const CustomPaint(painter: _SampleScenePainter())
        : media.info.isStillImage
        ? Image.file(
            File(path),
            fit: fill ? BoxFit.cover : BoxFit.contain,
            cacheWidth: thumbnail ? 260 : 720,
            gaplessPlayback: true,
          )
        : FutureBuilder<File?>(
            future: ref
                .read(thumbnailServiceProvider)
                .frame(path, const Duration(milliseconds: 500), width: thumbnail ? 240 : 480),
            builder: (_, snap) => snap.data == null
                ? const ColoredBox(color: Color(0xFF232838))
                : Image.file(snap.data!, fit: fill ? BoxFit.cover : BoxFit.contain),
          );

    Widget look = ColorFiltered(
      colorFilter: ColorFilter.matrix(
        ColorMatrix.build(theme.filter, theme.filterStrength, ColorAdjustments.neutral),
      ),
      child: SizedBox.expand(child: picture),
    );
    if (theme.effect != VideoEffect.none) {
      look = EffectPreview(
        effect: theme.effect,
        intensity: theme.effectIntensity,
        outputWidth: 1080,
        time: Duration.zero,
        child: look,
      );
    }
    return LayoutBuilder(
      builder: (context, box) => ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            look,
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: theme.titleFont,
                    color: Color(theme.titleColor),
                    fontSize: box.maxHeight * theme.titleSize * (thumbnail ? 1.8 : 1),
                    height: 1.1,
                    shadows: const [
                      Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 2)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offline sample picture (sky, sun, hills, water) used to preview themes
/// before the user adds media. Colourful on purpose, so filters show.
class _SampleScenePainter extends CustomPainter {
  const _SampleScenePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final sky = Rect.fromLTWH(0, 0, w, h * 0.62);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3A7BD5), Color(0xFFF7B267), Color(0xFFF4845F)],
        ).createShader(sky),
    );
    canvas.drawCircle(
      Offset(w * 0.68, h * 0.42),
      w * 0.13,
      Paint()..color = const Color(0xFFFFE29A),
    );
    final far = Path()
      ..moveTo(0, h * 0.58)
      ..quadraticBezierTo(w * 0.25, h * 0.38, w * 0.5, h * 0.55)
      ..quadraticBezierTo(w * 0.75, h * 0.34, w, h * 0.52)
      ..lineTo(w, h * 0.66)
      ..lineTo(0, h * 0.66)
      ..close();
    canvas.drawPath(far, Paint()..color = const Color(0xFF6B4E8C));
    final near = Path()
      ..moveTo(0, h * 0.7)
      ..quadraticBezierTo(w * 0.35, h * 0.52, w * 0.7, h * 0.66)
      ..quadraticBezierTo(w * 0.88, h * 0.72, w, h * 0.62)
      ..lineTo(w, h * 0.78)
      ..lineTo(0, h * 0.78)
      ..close();
    canvas.drawPath(near, Paint()..color = const Color(0xFF2E8B57));
    final water = Rect.fromLTWH(0, h * 0.76, w, h * 0.24);
    canvas.drawRect(
      water,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1FA2C4), Color(0xFF0B4F6C)],
        ).createShader(water),
    );
    final glint = Paint()..color = const Color(0x88FFE29A);
    for (var i = 0; i < 5; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(w * 0.68, h * (0.8 + i * 0.04)),
            width: w * (0.22 - i * 0.03),
            height: h * 0.008,
          ),
          const Radius.circular(4),
        ),
        glint,
      );
    }
  }

  @override
  bool shouldRepaint(_SampleScenePainter oldDelegate) => false;
}
