/// Categories of failures the user can meaningfully act on.
enum AppErrorKind {
  unsupportedVideo,
  corruptedFile,
  missingSourceFile,
  permissionDenied,
  insufficientStorage,
  exportFailed,
  processingFailed,
  cancelled,
  unsupportedCodec,
  importFailed,
  unknown,
}

/// A failure with a human-readable [message]. Raw technical details (FFmpeg
/// logs, stack traces) are kept in [debugDetails] and never shown in the UI.
class AppException implements Exception {
  const AppException(this.kind, this.message, {this.debugDetails});

  final AppErrorKind kind;
  final String message;
  final String? debugDetails;

  factory AppException.cancelled() =>
      const AppException(AppErrorKind.cancelled, 'The operation was cancelled.');

  factory AppException.missingSource(String name) => AppException(
    AppErrorKind.missingSourceFile,
    '"$name" is no longer available on this device. '
    'It may have been moved or deleted.',
  );

  factory AppException.insufficientStorage({int? requiredBytes}) => const AppException(
    AppErrorKind.insufficientStorage,
    'Not enough free storage space. Free up some space and try again.',
  );

  factory AppException.permissionDenied(String what) => AppException(
    AppErrorKind.permissionDenied,
    'Permission to $what was denied. You can allow it in system Settings.',
  );

  bool get isCancellation => kind == AppErrorKind.cancelled;

  /// Short title for dialogs.
  String get title => switch (kind) {
    AppErrorKind.unsupportedVideo => 'Unsupported video',
    AppErrorKind.corruptedFile => 'File can\'t be read',
    AppErrorKind.missingSourceFile => 'File not found',
    AppErrorKind.permissionDenied => 'Permission needed',
    AppErrorKind.insufficientStorage => 'Storage full',
    AppErrorKind.exportFailed => 'Export failed',
    AppErrorKind.processingFailed => 'Processing failed',
    AppErrorKind.cancelled => 'Cancelled',
    AppErrorKind.unsupportedCodec => 'Unsupported format',
    AppErrorKind.importFailed => 'Import failed',
    AppErrorKind.unknown => 'Something went wrong',
  };

  /// Wraps any error into an [AppException] with a generic message.
  static AppException from(Object error, {String? fallbackMessage}) {
    if (error is AppException) return error;
    return AppException(
      AppErrorKind.unknown,
      fallbackMessage ?? 'An unexpected error occurred. Please try again.',
      debugDetails: error.toString(),
    );
  }

  @override
  String toString() =>
      'AppException($kind): $message'
      '${debugDetails == null ? '' : '\n$debugDetails'}';
}
