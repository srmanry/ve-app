# CutLocal — offline video editor (Flutter)

A privacy-first mobile video editor for Android and iOS. Everything runs on the
device: no backend, no account, no network access, no uploads. Video
processing uses FFmpeg (via FFmpegKit) running natively off the UI thread.

## Features

| Area | What works |
|---|---|
| Import | Gallery (system Photo Picker/PHPicker) and Files; MP4, MOV, M4V, MKV, AVI, WebM, 3GP. Files are copied (streamed, never loaded into RAM) into app storage, probed (duration, size, rotation, fps, codecs) and — when the platform player can't preview them (e.g. MKV/WebM/AVI on iOS) — converted once to H.264 MP4. |
| Editor | Preview, multi-track timeline (thumbnails, centre playhead, pinch/± zoom, tap-ruler seek), undo/redo, save, rename. |
| Clip tools | Trim (handles + range slider + preview selection), split at playhead, delete/duplicate, long-press reorder, crop (free, 16:9, 9:16, 1:1, 4:5, 4:3), rotate ±90°, flip H/V, speed 0.25×–4× (pitch-preserving), volume 0–200 %, mute, extract audio to a track. |
| Look | 10 filter presets with strength, 7 adjustment sliders, "apply to all". |
| Layers | Text (8 bundled fonts, size, bold/italic, colour, background, alignment, opacity, shadow, outline, move/pinch/rotate), stickers (emoji + 16 vector shapes, all local), picture-in-picture (position, scale, rotation, trim, volume, mute), music/audio tracks (MP3/M4A/WAV/AAC, trim, volume, mute, move). All are timeline layers you can move and resize. |
| Photos | Photo clips (JPEG, PNG, HEIC, WebP) mixed with videos anywhere on the timeline; decoded by the platform (upright via EXIF), stored ≤ 2160 px. **Photo Slideshow** tool: pick many photos at once, reorder, per-photo duration, transition, shape (9:16, 1:1, 4:5, 16:9), fill/fit, and music — optionally stretching the slideshow to the song length. Opens in the editor for text, stickers, filters, export. |
| Transitions | None, fade, dissolve, slide, zoom; 0.5–2 s. |
| Canvas | Original, 16:9, 9:16, 1:1, 4:5, 4:3; fit (with background colour) or fill. |
| Export | **Export for** a platform: Original (full frame), YouTube, YouTube Shorts, Facebook, Facebook Reels, Instagram Reels/Post, TikTok, WhatsApp Status, X, or Custom shape — sets frame shape, resolution, fps and quality for that export only (the project keeps its own canvas), with Show all / Fill framing. 480p/720p/1080p/Original, 24/30/60 fps, Low/Medium/High/Custom bitrate, MP4 (H.264 + AAC). Size estimate, staged progress with %, ETA, cancel. Result: play, share, save to gallery, file location, delete. |
| Tools | Merge (reorder, remove, preview sequence, mixed sizes normalised onto one canvas), Compress (presets + custom), Video → Audio (M4A or WAV). |
| Projects | Auto-created drafts, continue editing, rename, duplicate, delete. Only metadata + relative media paths are stored. |
| Settings | Export defaults, theme, storage breakdown, clear temporary files, privacy, about/licences, rate/share app. |

## Architecture

```
lib/
  app/            DI (Riverpod providers), MaterialApp
  core/           constants, errors (AppException), theme, utils,
                  permissions (gallery save only), storage (paths, free-space channel)
  domain/         entities (Project, VideoClip, layers, ProjectTimeline, …),
                  repository interfaces, use cases
  data/           JSON models, file datasource, repository implementations
  services/
    video/        VideoProcessingService (engine-agnostic contract), ColorMatrix,
                  PlaybackCompatibility (per-platform)
    ffmpeg/       FfmpegCommandBuilder (pure Dart), FFmpegKit implementation,
                  ffprobe parser, error mapper
    overlay/      OverlayPainter (text/sticker drawing shared by preview + export)
    thumbnail/    lazy, cached, LIFO frame extraction
    export/       ExportService (validate → rasterise overlays → encode → finalise)
    storage/      usage + cleanup
    picker/       system picker wrapper
  presentation/   home, projects, exports, settings, onboarding, tools, editor/
                  (state/, playback/, preview/, timeline/, panels/)
```

Key design decisions:

* **One timeline model, three consumers.** `ProjectTimeline` computes clip
  positions (including transition overlaps). The preview, the timeline UI and
  the FFmpeg command builder all use it, so they always agree.
* **WYSIWYG colour.** Filters and adjustments compose into one 4×5 colour
  matrix: `ColorFilter.matrix` in the preview, `colorchannelmixer` on RGBA in
  export (the offset column rides on the constant alpha channel).
* **WYSIWYG overlays.** Text and stickers are drawn by `OverlayPainter` in the
  preview and rasterised by the same code to canvas-sized PNGs for export,
  which FFmpeg composites with timed `overlay` filters. No font files are
  needed by FFmpeg and emoji render correctly.
* **Replaceable engine.** Everything goes through `VideoProcessingService`.
  Swap `videoProcessingProvider` in `lib/app/providers.dart` to change engine.
* **Immutable project + snapshot undo.** Each edit produces a new `Project`;
  continuous gestures record one undo step (`beginChange` + `updateLive`).
* **Scoped editor state.** `editorProvider` is overridden per editor screen;
  the high-frequency playhead lives in `PlaybackController.position` so
  playback only rebuilds the playhead/timestamp, not the editor.
* **Stable media references.** Paths are stored relative to app storage (iOS
  changes the container path on every update). Unreferenced imported media is
  garbage-collected on startup, project delete and "Clear temporary files".
* **Platform code is isolated:** `DeviceStoragePlugin` (Kotlin, in
  `MainActivity.kt`'s package) and `DeviceStoragePlugin` (Swift, in
  `AppDelegate.swift`) report free space; `PlaybackCompatibility` holds the
  per-platform preview rules.

## Build & run

Requires Flutter 3.47+ (Dart 3.13), Android SDK (minSdk 24), Xcode 26 (iOS 15+).

```sh
flutter pub get
flutter run                       # debug on a connected device/simulator
flutter build appbundle           # Play Store (per-ABI splits keep downloads small)
flutter build ipa                 # App Store
```

The universal APK is large (~140 MB) because FFmpeg ships for every ABI; use an
app bundle, or `flutter build apk --split-per-abi` for sideloading.

## Tests

```sh
flutter test                                   # unit tests (timeline, editor ops, undo/redo,
                                               # JSON, colour matrix, command builder, parser)

# Run generated FFmpeg commands against a real ffmpeg binary (desktop):
FFMPEG_BIN=… FFPROBE_BIN=… TEST_MEDIA_DIR=… flutter test test/services/ffmpeg_render_integration_test.dart

# On-device end-to-end (real FFmpegKit, import, export, cancel, UI):
flutter test integration_test/app_e2e_test.dart -d <device>
# Android alternative when device storage is tight (smaller profile build):
flutter drive --profile --driver=test_driver/integration_test.dart \
  --target=integration_test/app_e2e_test.dart -d <device>
```

`TEST_MEDIA_DIR` needs `a.mp4` (1080p30 + audio), `b_rot.mov` (rotation
metadata + audio), `c.mkv` (no audio), `music.m4a`, `overlay.png`; the test
file header shows how to create them with ffmpeg's `lavfi` sources.

## Permissions

* **Android:** `WRITE_EXTERNAL_STORAGE` only on Android ≤ 9 (saving to the
  gallery). Plugin-declared `READ_MEDIA_*`/`READ_EXTERNAL_STORAGE` are removed
  in the manifest because imports use the system pickers. The release build has
  **no `INTERNET` permission**. ExoPlayer contributes the normal
  `ACCESS_NETWORK_STATE`/`WAKE_LOCK` permissions.
* **iOS:** photo-library *add* permission is requested only when saving to the
  gallery; PHPicker imports need no permission. Exports are visible in the
  Files app (`UIFileSharingEnabled`).

## Before release

* **Licensing:** `ffmpeg_kit_flutter_new` bundles libx264 (GPL). A
  closed-source app must either comply with the GPL or switch to the LGPL
  `ffmpeg_kit_flutter_new_min` package and a hardware encoder
  (`h264_mediacodec` / `h264_videotoolbox`) in `FfmpegCommandBuilder._videoEncoderArgs`.
* Change the application id / bundle id (`com.example.video_editor_app`) and set
  `AppConstants.androidPackageId` / `iosAppStoreId` for Rate/Share.
* Add a launcher icon and signing configuration.
* Localisation is English-only; the Language setting states this.

## Known limitations

* Transitions are approximated in the live preview (fade/slide/zoom effects on
  the active clip); the export renders exact FFmpeg `xfade` transitions.
* Highlights/shadows are linear approximations (black/white-point moves) so
  they can share the preview/export colour matrix.
* Preview volume is capped at 100 % (export honours up to 200 %).
* Exports run while the app is in the foreground (the screen is kept awake);
  backgrounding on iOS may suspend a long export.
* On-device testing so far: iOS simulator (full E2E). Android builds and its
  manifest were verified, but the E2E run on the local emulator was blocked by
  the emulator's full storage.

## Future modules

The layering keeps these additive: AI captions/background removal as new
`VideoProcessingService` capabilities or separate services; cloud backup as an
additional `ProjectRepository` implementation; templates as `Project`
factories; online music as another audio source feeding `AudioTrack`; accounts
and subscriptions as new `app/` providers gating features. None are included.
