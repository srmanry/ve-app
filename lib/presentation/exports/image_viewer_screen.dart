import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Full-screen photo with pinch-zoom (exported image-tool results).
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.path, required this.title});
  final String path;
  final String title;

  @override
  Widget build(BuildContext context) => StudioTheme(
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(path),
            errorBuilder: (_, _, _) => const Text('This photo can\'t be shown.'),
          ),
        ),
      ),
    ),
  );
}
