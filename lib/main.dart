import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/storage/app_paths.dart';
import 'core/storage/device_storage.dart';
import 'domain/usecases/project_usecases.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerFontLicenses();

  final paths = await AppPaths.resolve();
  final prefs = await SharedPreferences.getInstance();

  final lowMemory = await const DeviceStorage().isLowMemoryDevice();

  final container = ProviderContainer(
    overrides: [
      lowMemoryDeviceProvider.overrideWithValue(lowMemory),
      appPathsProvider.overrideWithValue(paths),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
  );

  // Decoded thumbnails/photos are re-creatable; keep the cache modest so
  // video decoding and the camera have memory on low-RAM phones.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  runApp(UncontrolledProviderScope(container: container, child: const VideoEditorApp()));

  // Startup housekeeping, after the first frame. No editor is open yet, so
  // it's safe to drop leftovers from interrupted exports and orphaned media.
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () async {
      try {
        await container.read(storageServiceProvider).clearTemporaryFiles(includeThumbnails: false);
        await CollectUnusedMedia(
          container.read(projectRepositoryProvider),
          container.read(mediaRepositoryProvider),
        )();
      } catch (e) {
        debugPrint('Startup cleanup failed: $e');
      }
    }),
  );
}

void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks([
      'Bebas Neue',
      'Pacifico',
      'Lobster',
      'Roboto Mono',
      'Playfair Display',
      'Oswald',
    ], ofl);
    final apache = await rootBundle.loadString('assets/fonts/LICENSE-Apache.txt');
    yield LicenseEntryWithLineBreaks(['Permanent Marker'], apache);
  });
}

/// When Android/iOS report memory pressure, drop decoded images first, so
/// the system doesn't have to kill the app.
class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    final cache = PaintingBinding.instance.imageCache;
    cache
      ..clear()
      ..clearLiveImages();
    debugPrint('Memory pressure: image cache cleared');
  }
}
