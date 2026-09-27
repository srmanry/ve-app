import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Reads/writes small JSON documents atomically (write temp file, then
/// rename), so a crash mid-save never leaves a truncated project behind.
class JsonFileStore {
  const JsonFileStore();

  Future<Map<String, Object?>?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException catch (e) {
      debugPrint('Corrupt JSON in ${file.path}: $e');
      return null;
    }
  }

  Future<void> write(File file, Object json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }
}
