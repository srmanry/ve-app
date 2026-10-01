import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/entities/image_edit.dart';
import 'crop_frame.dart';

/// Pick the part of a photo to keep. With [ratio] (w/h) the frame keeps
/// that shape, e.g. a passport photo. Returns the chosen [CropRect].
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({
    super.key,
    required this.path,
    required this.width,
    required this.height,
    required this.initial,
    this.ratio,
    this.title = 'Choose the part',
    this.sizeLabel,
  });

  final String path;
  final int width;
  final int height;
  final CropRect initial;
  final double? ratio;
  final String title;

  /// Shown under the photo, e.g. "531×650 px".
  final String? sizeLabel;

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  late CropRect _crop = widget.initial;

  CropRect get _reset {
    final r = widget.ratio;
    return r == null
        ? CropRect.full
        : CropRect.centered(r, widget.width.toDouble(), widget.height.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.width / widget.height;
    final scheme = Theme.of(context).colorScheme;
    return StudioTheme(
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0F13),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0E0F13),
          title: Text(widget.title, style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: 'Reset',
              onPressed: () => setState(() => _crop = _reset),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop(context, _crop),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: CropFrame(
                      crop: _crop,
                      ratio: widget.ratio,
                      photoAspect: aspect,
                      onChanged: (c) => setState(() => _crop = c),
                      child: Image.file(
                        File(widget.path),
                        fit: BoxFit.fill,
                        cacheWidth: 1400,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  children: [
                    if (widget.sizeLabel != null)
                      Text(
                        widget.sizeLabel!,
                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Drag the frame to move it, drag a corner to resize. '
                      'Only the part inside is kept.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: context.mutedColor),
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
