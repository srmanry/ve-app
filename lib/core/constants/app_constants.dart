/// App-wide constants. Values that the user can pick from live next to the
/// entity that uses them (see `domain/entities`), not here.
abstract final class AppConstants {
  static const appName = 'CutLocal';
  static const appTagline = 'Offline video editor';

  /// Store listing used by "Share app" / "Rate app". Replace before release.
  static const androidPackageId = 'com.example.video_editor_app';
  static const iosAppStoreId = '0000000000';

  static const privacyStatement =
      'Your videos are processed locally on your device and are not '
      'uploaded to a server.';

  /// Maximum number of undo steps kept in memory.
  static const maxUndoSteps = 60;

  /// Supported import extensions (lower-case, without dot).
  static const videoExtensions = ['mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', '3gp'];
  static const audioExtensions = ['mp3', 'm4a', 'wav', 'aac'];

  /// Minimum length of a clip or layer after trimming/splitting.
  static const minClipDuration = Duration(milliseconds: 200);

  /// Extra free space we require beyond the estimated output size.
  static const exportStorageSafetyMargin = 150 * 1024 * 1024;

  /// Source files above these limits trigger a "large video" notice.
  static const largeFileBytes = 2 * 1024 * 1024 * 1024;
  static const largeVideoPixels = 3840 * 2160;
}
