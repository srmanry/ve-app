import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';

/// Shows a friendly error. Technical details only go to the debug log.
Future<void> showAppError(BuildContext context, Object error) async {
  final e = AppException.from(error);
  if (e.isCancellation) return;
  if (e.debugDetails != null) debugPrint('${e.kind}: ${e.debugDetails}');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(_iconFor(e.kind), color: Theme.of(context).colorScheme.error),
      title: Text(e.title),
      content: Text(e.message),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}

IconData _iconFor(AppErrorKind kind) => switch (kind) {
  AppErrorKind.insufficientStorage => Icons.sd_storage_outlined,
  AppErrorKind.permissionDenied => Icons.lock_outline,
  AppErrorKind.missingSourceFile => Icons.find_in_page_outlined,
  AppErrorKind.unsupportedVideo || AppErrorKind.unsupportedCodec => Icons.videocam_off_outlined,
  AppErrorKind.corruptedFile => Icons.broken_image_outlined,
  _ => Icons.error_outline,
};

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
  int maxLines = 1,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: maxLines,
        minLines: 1,
        decoration: InputDecoration(hintText: hint),
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: maxLines == 1 ? (v) => Navigator.pop(context, v) : null,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(action)),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Modal progress dialog driven by a [ValueListenable] status message.
Future<T> runWithProgress<T>(
  BuildContext context,
  Future<T> Function(ValueNotifier<String> status) task, {
  String initialStatus = 'Working…',
}) async {
  final status = ValueNotifier(initialStatus);
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, s, _) => Text(s),
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() => dialogOpen = false),
  );
  try {
    return await task(status);
  } finally {
    if (dialogOpen) navigator.pop();
    status.dispose();
  }
}
