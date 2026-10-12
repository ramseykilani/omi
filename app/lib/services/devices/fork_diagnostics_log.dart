import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:omi/utils/logger.dart';

/// Fork-only append-only event log for field debugging of the wearable link.
///
/// Records what the native disconnect history and battery chart do not keep:
/// every battery level/charging change (with a periodic heartbeat), Dart-side
/// connection transitions with the native disconnect reason, firmware revision
/// on every connect, and each OTA step. Exported as `fork_log` by the device
/// diagnostics page.
///
/// Never throws: logging must not be able to break the connection path.
class ForkDiagnosticsLog {
  ForkDiagnosticsLog._();

  static final ForkDiagnosticsLog instance = ForkDiagnosticsLog._();

  static const fileName = 'fork_diagnostics_log.jsonl';
  static const maxEntries = 20000;
  static const _compactEveryAppends = 500;

  /// Battery samples that repeat the previous level/charging state are only
  /// logged this often, so a 5 s firmware cadence does not flood the file.
  static const batteryHeartbeat = Duration(minutes: 5);

  File? _file;
  Future<void> _queue = Future.value();
  int _appendsSinceCompact = 0;

  int? _lastBatteryLevel;
  bool? _lastBatteryCharging;
  DateTime? _lastBatteryLoggedAt;

  void record(String type, [Map<String, Object?> data = const {}]) {
    final entry = <String, Object?>{'ts': DateTime.now().toUtc().toIso8601String(), 'type': type, ...data};
    _queue = _queue.then((_) => _append(jsonEncode(entry))).catchError((Object e) {
      Logger.debug('[ForkDiagnosticsLog] append failed: $e');
    });
  }

  /// Logs a battery notification when the level or charging state changed, or
  /// as a heartbeat proving the reading is still arriving.
  void recordBattery({required String deviceId, required int level, required bool charging}) {
    final now = DateTime.now();
    final changed = level != _lastBatteryLevel || charging != _lastBatteryCharging;
    final heartbeatDue = _lastBatteryLoggedAt == null || now.difference(_lastBatteryLoggedAt!) >= batteryHeartbeat;
    if (!changed && !heartbeatDue) return;
    _lastBatteryLevel = level;
    _lastBatteryCharging = charging;
    _lastBatteryLoggedAt = now;
    record('battery', {'device': deviceId, 'level': level, 'charging': charging, 'changed': changed});
  }

  Future<List<Map<String, dynamic>>> readAll() async {
    try {
      await _queue;
      final file = await _resolveFile();
      if (!await file.exists()) return [];
      final lines = await file.readAsLines();
      return lines.map(_tryDecode).whereType<Map<String, dynamic>>().toList();
    } catch (e) {
      Logger.debug('[ForkDiagnosticsLog] read failed: $e');
      return [];
    }
  }

  Future<void> clear() async {
    try {
      await _queue;
      final file = await _resolveFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      Logger.debug('[ForkDiagnosticsLog] clear failed: $e');
    }
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _resolveFile() async => _file ??= File('${(await getApplicationDocumentsDirectory()).path}/$fileName');

  Future<void> _append(String line) async {
    final file = await _resolveFile();
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    if (++_appendsSinceCompact >= _compactEveryAppends) {
      _appendsSinceCompact = 0;
      final lines = await file.readAsLines();
      if (lines.length > maxEntries) {
        await file.writeAsString('${lines.sublist(lines.length - maxEntries).join('\n')}\n', flush: true);
      }
    }
  }
}
