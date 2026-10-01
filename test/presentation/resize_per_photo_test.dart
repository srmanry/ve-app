import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/app/providers.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/repositories/media_repository.dart';
import 'package:video_editor_app/presentation/image/image_batch_screen.dart';

class _Repo implements MediaRepository {
  _Repo(this.path);
  final String path;
  @override
  String resolve(String r) => path;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

ImportedMedia _photo(String id) => ImportedMedia(
  relativePath: id,
  displayName: '$id.jpg',
  info: MediaInfo.stillImage(width: 1200, height: 1600, fileSize: 1000),
);

void main() {
  testWidgets('each photo keeps its own size', (tester) async {
    // Any real image file works; the test only checks the size labels.
    final dir = Directory.systemTemp.createTempSync('resize_ui');
    final png = File('${dir.path}/p.png')
      ..writeAsBytesSync(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1,
        0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 13, 0x49, 0x44, 0x41, 0x54, 0x78,
        0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, 0x1F, 0, 0x05, 0, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0, 0,
        0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);
    tester.view.physicalSize = const Size(1170, 4800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [mediaRepositoryProvider.overrideWithValue(_Repo(png.path))],
      child: MaterialApp(
        home: ImageBatchScreen(tool: ImageBatchTool.resize, initial: [_photo('a'), _photo('b')]),
      ),
    ));
    await tester.pump();

    // Photo 1 → Stamp.
    await tester.tap(find.text('Stamp size'));
    await tester.pump();
    // Photo 2 → Online form photo.
    await tester.tapAt(tester.getCenter(find.text('Passport\n531×650')));
    await tester.pump();
    expect(find.text('Size for photo 2'), findsOneWidget);
    await tester.tap(find.text('Online form photo'));
    await tester.pump();

    expect(find.text('Stamp\n236×295'), findsOneWidget);
    expect(find.text('Online\n300×300'), findsOneWidget);
    expect(find.text('Resize 2 photos'), findsOneWidget);

    // Apply to all copies the selected photo's size.
    await tester.tap(find.text('Apply to all'));
    await tester.pump();
    expect(find.text('Online\n300×300'), findsNWidgets(2));
    dir.deleteSync(recursive: true);
  });
}
