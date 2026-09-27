/// Formatting helpers for durations, sizes and dates shown in the UI.
abstract final class Formatters {
  /// `75.4s` -> `01:15`, `3725s` -> `1:02:05`. With [showMillis], appends
  /// tenths of a second (`01:15.4`), which is useful on the timeline.
  static String duration(Duration d, {bool showTenths = false}) {
    if (d.isNegative) d = Duration.zero;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final base = hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
    if (!showTenths) return base;
    final tenths = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$base.$tenths';
  }

  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  static String resolution(int width, int height) => '$width×$height';

  static String speed(double speed) {
    final s = speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed.toString();
    return '${s}x';
  }

  /// "Just now", "5 min ago", "Yesterday", or a date.
  static String relativeTime(DateTime time, {DateTime? now}) {
    now ??= DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24 && now.day == time.day) return '${diff.inHours} h ago';
    if (diff.inDays < 2 && now.day - time.day == 1) return 'Yesterday';
    return date(time);
  }

  static String date(DateTime time) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[time.month - 1]} ${time.day}, ${time.year}';
  }
}
