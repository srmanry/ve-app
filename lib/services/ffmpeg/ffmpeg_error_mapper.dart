import '../../core/errors/app_exception.dart';

/// Converts FFmpeg log output into a user-facing [AppException].
///
/// Raw logs are attached as `debugDetails` for diagnostics but are never
/// shown to the user.
abstract final class FfmpegErrorMapper {
  static AppException map(
    String? logs, {
    required AppErrorKind fallbackKind,
    required String fallbackMessage,
  }) {
    final text = (logs ?? '').toLowerCase();

    AppException ex(AppErrorKind kind, String message) =>
        AppException(kind, message, debugDetails: logs);

    if (text.contains('no space left on device') || text.contains('enospc')) {
      return ex(
        AppErrorKind.insufficientStorage,
        'Your device ran out of storage while processing. Free up some space and try again.',
      );
    }
    if (text.contains('no such file or directory')) {
      return ex(
        AppErrorKind.missingSourceFile,
        'One of the files used by this project could not be found.',
      );
    }
    if (text.contains('permission denied')) {
      return ex(
        AppErrorKind.permissionDenied,
        'The app was not allowed to read or write a file it needs.',
      );
    }
    if (text.contains('moov atom not found') ||
        text.contains('invalid data found when processing input') ||
        text.contains('error while decoding') ||
        text.contains('corrupt')) {
      return ex(
        AppErrorKind.corruptedFile,
        'This file appears to be damaged or incomplete and can\'t be processed.',
      );
    }
    if (text.contains('decoder not found') ||
        text.contains('unknown decoder') ||
        text.contains('codec not currently supported') ||
        text.contains('could not find codec parameters') ||
        text.contains('unsupported codec')) {
      return ex(
        AppErrorKind.unsupportedCodec,
        'This file uses a format or codec that isn\'t supported.',
      );
    }
    if (text.contains('cannot allocate memory') || text.contains('out of memory')) {
      return ex(
        AppErrorKind.processingFailed,
        'The device ran out of memory. Try a lower export resolution.',
      );
    }
    return ex(fallbackKind, fallbackMessage);
  }
}
