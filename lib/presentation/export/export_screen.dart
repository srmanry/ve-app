import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/logo_placement.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../services/export/export_service.dart';
import '../editor/panels/panel_common.dart';
import '../exports/export_actions.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/logo_picker.dart';

enum ExportMode { project, compress }

/// Export options → progress → result, all on one screen.
///
/// Also used by the Compress tool ([ExportMode.compress]), which adds
/// compression presets and a comparison with the source size.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({
    super.key,
    required this.project,
    this.onSettingsChanged,
    this.mode = ExportMode.project,
  });

  final Project project;
  final ValueChanged<ExportSettings>? onSettingsChanged;
  final ExportMode mode;

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  late ExportSettings _settings;
  CompressionPreset _preset = CompressionPreset.medium;

  /// The project as it will be rendered: same edits, but with this export's
  /// frame shape/fit (e.g. 9:16 for TikTok). The saved project is untouched.
  /// Optional logo for this export only (the project is not changed).
  CameraLogo? _logo;

  Project get _exportProject {
    final shaped = widget.project.copyWith(canvas: _settings.canvasFor(widget.project.canvas));
    final logo = _logo;
    if (logo == null) return shaped;
    final timeline = ProjectTimeline(shaped);
    return shaped.copyWith(
      stickerLayers: [
        ...shaped.stickerLayers,
        LogoPlacement.layer(
          id: 'export-logo',
          logoPath: logo.path,
          duration: timeline.duration,
          canvasAspect: timeline.canvasAspectRatio,
          position: logo.position,
          scale: logo.scale,
          opacity: logo.opacity,
        ),
      ],
    );
  }

  ProjectTimeline get _timeline => ProjectTimeline(_exportProject);

  ExportJob? _job;
  ExportProgress? _progress;
  StreamSubscription<ExportProgress>? _sub;
  ExportedMedia? _result;

  bool get _running => _job != null && _result == null;

  @override
  void initState() {
    super.initState();
    _settings = widget.mode == ExportMode.compress
        ? _preset.settings
        : widget.project.exportSettings;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    // Leaving the screen cancels a running export (temp files are cleaned).
    if (_running) unawaited(_job!.cancel());
    super.dispose();
  }

  void _setSettings(ExportSettings s) {
    setState(() => _settings = s);
    widget.onSettingsChanged?.call(s);
  }

  Future<void> _start() async {
    // Includes this export's logo; the shape override is idempotent in the service.
    final job = ref.read(exportServiceProvider).exportProject(_exportProject, _settings);
    setState(() {
      _job = job;
      _progress = const ExportProgress(ExportStage.preparing, 0);
    });
    _sub = job.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    try {
      final result = await job.result;
      await ref.read(exportsProvider.notifier).refresh();
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _job = null;
        _progress = null;
      });
      final error = AppException.from(e);
      if (error.isCancellation) {
        showSnack(context, 'Export cancelled');
      } else {
        await showAppError(context, error);
      }
    }
  }

  Future<void> _cancel() async {
    final ok = await confirm(
      context,
      title: 'Cancel export?',
      message: 'Progress will be lost.',
      confirmLabel: 'Cancel export',
    );
    if (ok) await _job?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return StudioTheme(
      child: PopScope(
        canPop: !_running,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_cancel());
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.mode == ExportMode.compress ? 'Compress video' : 'Export'),
            automaticallyImplyLeading: !_running,
          ),
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _result != null
                  ? _ResultView(media: _result!, key: const ValueKey('result'))
                  : _running
                  ? _ProgressView(
                      key: const ValueKey('progress'),
                      progress: _progress,
                      onCancel: _cancel,
                    )
                  : _optionsView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _optionsView() {
    final timeline = _timeline;
    final size = timeline.outputSize(_settings);
    final estimate = timeline.estimateOutputBytes(_settings);
    final sourceSize = widget.project.clips.fold<int>(0, (s, c) => s + c.media.fileSize);
    final isCompress = widget.mode == ExportMode.compress;

    return ListView(
      key: const ValueKey('options'),
      padding: const EdgeInsets.all(16),
      children: [
        _CanvasPreview(project: _exportProject, aspect: timeline.canvasAspectRatio),
        const SizedBox(height: 16),
        if (!isCompress) ...[
          const _Label('Export for'),
          _PlatformPicker(
            selected: _settings.target,
            projectAspect: widget.project.canvas.aspectRatio,
            onSelected: (t) => _setSettings(_settings.withTarget(t)),
          ),
          const SizedBox(height: 16),
          if (_settings.target == ExportTarget.custom) ...[
            const _Label('Shape'),
            ChipRow<AspectRatioPreset>(
              values: AspectRatioPreset.values,
              selected: _settings.aspectRatio ?? widget.project.canvas.aspectRatio,
              label: (a) => a.label == 'Original' ? 'Full (original)' : a.label,
              onSelected: (a) => _setSettings(_settings.copyWith(aspectRatio: a)),
            ),
            const SizedBox(height: 16),
          ],
          if (_settings.aspectRatio != null &&
              _settings.aspectRatio != widget.project.canvas.aspectRatio) ...[
            const _Label('Frame'),
            SegmentedButton<CanvasFit>(
              segments: const [
                ButtonSegment(
                  value: CanvasFit.fit,
                  icon: Icon(Icons.fit_screen_outlined),
                  label: Text('Show all'),
                ),
                ButtonSegment(
                  value: CanvasFit.fill,
                  icon: Icon(Icons.crop),
                  label: Text('Fill (crop edges)'),
                ),
              ],
              selected: {_settings.fit ?? widget.project.canvas.fit},
              onSelectionChanged: (v) => _setSettings(_settings.copyWith(fit: v.first)),
            ),
            const SizedBox(height: 16),
          ],
        ],
        if (isCompress) ...[
          const _Label('Preset'),
          ChipRow<CompressionPreset>(
            values: CompressionPreset.values,
            selected: _preset,
            label: (p) => p.label,
            onSelected: (p) {
              _preset = p;
              _setSettings(p.settings);
            },
          ),
          const SizedBox(height: 16),
        ],
        const _Label('Logo / watermark'),
        LogoPicker(
          selected: _logo?.path,
          onSelected: (path) => setState(
            () => _logo = _logo == null
                ? CameraLogo(path: path, position: LogoPosition.bottomRight)
                : CameraLogo(
                    path: path,
                    position: _logo!.position,
                    scale: _logo!.scale,
                    opacity: _logo!.opacity,
                  ),
          ),
        ),
        if (_logo != null) ...[
          const SizedBox(height: 8),
          LogoPositionChips(
            selected: _logo!.position,
            onSelected: (p) => setState(() => _logo = _logo!.copyWith(position: p)),
          ),
          LabeledSlider(
            label: 'Logo size',
            value: _logo!.scale,
            min: 0.3,
            max: 2.5,
            format: (v) => '${(v * 100).round()}%',
            onChangeStart: (_) {},
            onChanged: (v) => setState(() => _logo = _logo!.copyWith(scale: v)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('No logo'),
              onPressed: () => setState(() => _logo = null),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (!isCompress || _preset == CompressionPreset.custom) ...[
          const _Label('Resolution'),
          ChipRow<ExportResolution>(
            values: ExportResolution.values,
            selected: _settings.resolution,
            label: (r) => r.label,
            onSelected: (r) => _setSettings(_settings.copyWith(resolution: r)),
          ),
          const SizedBox(height: 16),
          const _Label('Frame rate'),
          ChipRow<int>(
            values: ExportSettings.frameRates,
            selected: _settings.frameRate,
            label: (f) => '$f fps',
            onSelected: (f) => _setSettings(_settings.copyWith(frameRate: f)),
          ),
          const SizedBox(height: 16),
          if (!isCompress) ...[
            const _Label('Quality'),
            ChipRow<ExportQuality>(
              values: ExportQuality.values,
              selected: _settings.quality,
              label: (q) => q.label,
              onSelected: (q) => _setSettings(
                _settings.copyWith(
                  quality: q,
                  customBitrateKbps: q == ExportQuality.custom
                      ? _settings.videoBitrateKbps(size.width, size.height)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_settings.quality == ExportQuality.custom)
            LabeledSlider(
              label: 'Bitrate',
              value: _settings.customBitrateKbps.toDouble(),
              min: 500,
              max: 30000,
              divisions: 59,
              format: (v) => '${(v / 1000).toStringAsFixed(1)}M',
              onChangeStart: (_) {},
              onChanged: (v) => _setSettings(_settings.copyWith(customBitrateKbps: v.round())),
            ),
          const _Label('Format'),
          const Text('MP4 (H.264 + AAC)', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 16),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _InfoRow('Output', '${size.width}×${size.height} · ${_settings.frameRate} fps'),
                _InfoRow('Duration', Formatters.duration(timeline.duration)),
                _InfoRow('Estimated size', '~${Formatters.fileSize(estimate)}'),
                if (isCompress && sourceSize > 0)
                  _InfoRow(
                    'Original size',
                    '${Formatters.fileSize(sourceSize)}'
                        '${estimate < sourceSize ? '  (−${(100 - estimate * 100 / sourceSize).round()}%)' : ''}',
                  ),
              ],
            ),
          ),
        ),
        if (timeline.duration > const Duration(minutes: 10))
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Long video: exporting may take a while. Keep the app open until it finishes.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.file_upload_outlined),
          label: Text(isCompress ? 'Compress' : 'Export video'),
        ),
      ],
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

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.white60)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// Static preview of the canvas shape with the first frame.
class _CanvasPreview extends ConsumerWidget {
  const _CanvasPreview({required this.project, required this.aspect});
  final Project project;
  final double aspect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clip = project.clips.first;
    final thumbs = ref.read(thumbnailServiceProvider);
    final path = ref.read(mediaRepositoryProvider).resolve(clip.sourcePath);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Container(
            decoration: BoxDecoration(
              color: Color(project.canvas.backgroundColor),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            clipBehavior: Clip.antiAlias,
            child: FutureBuilder<File?>(
              future: thumbs.frame(path, clip.isStill ? Duration.zero : clip.trimStart, width: 480),
              builder: (context, snap) => snap.data == null
                  ? const SizedBox.shrink()
                  : Image.file(
                      snap.data!,
                      fit: project.canvas.fit == CanvasFit.fill ? BoxFit.cover : BoxFit.contain,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid of destination presets.
class _PlatformPicker extends StatelessWidget {
  const _PlatformPicker({
    required this.selected,
    required this.projectAspect,
    required this.onSelected,
  });

  final ExportTarget selected;
  final AspectRatioPreset projectAspect;
  final ValueChanged<ExportTarget> onSelected;

  static IconData _icon(ExportTarget t) => switch (t) {
    ExportTarget.original => Icons.crop_free,
    ExportTarget.youtube => Icons.smart_display_outlined,
    ExportTarget.youtubeShorts => Icons.slow_motion_video,
    ExportTarget.facebook => Icons.facebook,
    ExportTarget.facebookReels => Icons.video_collection_outlined,
    ExportTarget.instagramReels => Icons.movie_filter_outlined,
    ExportTarget.instagramPost => Icons.camera_alt_outlined,
    ExportTarget.tiktok => Icons.music_video_outlined,
    ExportTarget.whatsappStatus => Icons.chat_outlined,
    ExportTarget.twitter => Icons.alternate_email,
    ExportTarget.custom => Icons.tune,
  };

  String _subtitle(ExportTarget t) {
    if (t == ExportTarget.custom) return 'Your choice';
    final shape = t.aspectRatio;
    if (shape == null) {
      return projectAspect == AspectRatioPreset.original ? 'Full frame' : projectAspect.label;
    }
    return '${shape.label} · ${t.resolution.label}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        const spacing = 8.0;
        final perRow = box.maxWidth > 500 ? 4 : 3;
        final width = (box.maxWidth - spacing * (perRow - 1)) / perRow;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final t in ExportTarget.values)
              SizedBox(
                width: width,
                child: Material(
                  color: t == selected
                      ? scheme.primary.withValues(alpha: 0.18)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onSelected(t),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: t == selected ? scheme.primary : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(_icon(t), size: 22, color: t == selected ? scheme.primary : null),
                          const SizedBox(height: 4),
                          Text(
                            t == ExportTarget.original ? 'Original (full)' : t.label,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _subtitle(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({super.key, required this.progress, required this.onCancel});
  final ExportProgress? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final fraction = p?.fraction ?? 0;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(value: fraction, strokeWidth: 8),
                Center(
                  child: Text(
                    '${(fraction * 100).floor()}%',
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(p?.stage.label ?? 'Preparing…', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            p?.remaining == null
                ? 'Estimating time…'
                : 'About ${Formatters.duration(p!.remaining!)} remaining',
            style: const TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 8),
          const Text(
            'Processing happens on your device. Keep the app open.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.white38),
          ),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: onCancel,
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends ConsumerWidget {
  const _ResultView({super.key, required this.media});
  final ExportedMedia media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExportActions(ref);
    final paths = ref.read(appPathsProvider);
    final thumb = media.thumbnailPath == null ? null : File(paths.toAbsolute(media.thumbnailPath!));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.check_circle, color: Colors.greenAccent, size: 56),
        const SizedBox(height: 12),
        Text(
          'Export complete',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 20),
        if (thumb != null && thumb.existsSync())
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Image.file(thumb, fit: BoxFit.contain),
            ),
          ),
        const SizedBox(height: 12),
        Text(media.fileName, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
        Text(
          '${media.width}×${media.height} · ${Formatters.duration(media.duration)} · '
          '${Formatters.fileSize(media.sizeBytes)}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            PanelAction(
              icon: Icons.play_arrow,
              label: 'Play',
              onTap: () => actions.play(context, media),
            ),
            Builder(
              builder: (context) => PanelAction(
                icon: Icons.ios_share,
                label: 'Share',
                onTap: () => actions.share(context, media),
              ),
            ),
            PanelAction(
              icon: Icons.download_outlined,
              label: 'Save',
              onTap: () => actions.saveToGallery(context, media),
            ),
            PanelAction(
              icon: Icons.folder_open_outlined,
              label: 'Location',
              onTap: () => actions.openLocation(context, media),
            ),
            PanelAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              color: Theme.of(context).colorScheme.error,
              onTap: () async {
                if (await actions.delete(context, media) && context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
