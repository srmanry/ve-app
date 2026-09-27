import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the `app/device_storage` platform channel implemented in
/// `android/.../DeviceStoragePlugin.kt` and `ios/Runner/DeviceStoragePlugin.swift`.
///
/// Kept deliberately tiny so the Android and iOS sides can evolve separately.
class DeviceStorage {
  const DeviceStorage();

  static const _channel = MethodChannel('app/device_storage');

  /// Total device RAM in bytes, or null if unknown.
  Future<int?> totalMemory() async {
    try {
      final value = await _channel.invokeMethod<Object?>('getTotalMemory');
      return value is num ? value.toInt() : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// True on phones with less than 6 GB of RAM, where 4K recording and
  /// heavy parallel decoding make the system kill the app.
  Future<bool> isLowMemoryDevice() async {
    final total = await totalMemory();
    return total != null && total < 6 * 1024 * 1024 * 1024 * 0.93;
  }

  /// Free bytes available to the app on the volume holding app data, or null
  /// if the platform could not report it.
  Future<int?> freeBytes() async {
    try {
      final value = await _channel.invokeMethod<Object?>('getFreeBytes');
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    } on PlatformException catch (e) {
      debugPrint('DeviceStorage.freeBytes failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
