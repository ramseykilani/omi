import 'dart:convert';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/fork_diagnostics_log.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/utils/logger.dart';

/// Confirms an OTA by the version the device reports after it reboots, instead
/// of trusting the DFU library's "success" (which only means the upload and
/// reset commands were acknowledged; MCUboot can still reject the image).
class FirmwareUpdateVerification {
  static const _prefsKey = 'forkPendingFirmwareVerification';

  /// A pending check older than this is reported as unverified, not compared.
  static const maxAge = Duration(hours: 6);

  /// Called when the DFU library reports success.
  static Future<void> markPending({
    required String deviceId,
    required String fromVersion,
    required String targetVersion,
  }) async {
    ForkDiagnosticsLog.instance.record('ota_pending_verification', {
      'device': deviceId,
      'from': fromVersion,
      'target': targetVersion,
    });
    await SharedPreferencesUtil().saveString(
      _prefsKey,
      jsonEncode({
        'device': deviceId,
        'from': fromVersion,
        'target': targetVersion,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  /// Called on every device connect with the firmware revision the device
  /// reports over the Device Information Service.
  static Future<void> verifyAfterReconnect({required String deviceId, required String firmware}) async {
    try {
      final raw = SharedPreferencesUtil().getString(_prefsKey);
      if (raw.isEmpty) return;
      final pending = jsonDecode(raw) as Map<String, dynamic>;
      if ((pending['device'] as String?)?.toUpperCase() != deviceId.toUpperCase()) return;
      await SharedPreferencesUtil().remove(_prefsKey);

      final target = pending['target']?.toString() ?? '';
      final from = pending['from']?.toString() ?? '';
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((pending['ts'] as num?)?.toInt() ?? 0));
      final outcome = age > maxAge
          ? 'expired'
          : _sameVersion(firmware, target)
              ? 'verified'
              : _sameVersion(firmware, from)
                  ? 'not_applied'
                  : 'unexpected_version';
      ForkDiagnosticsLog.instance.record('ota_verification', {
        'device': deviceId,
        'from': from,
        'target': target,
        'reported': firmware,
        'outcome': outcome,
        'age_s': age.inSeconds,
      });
      Logger.debug('[FirmwareUpdateVerification] $outcome: from=$from target=$target reported=$firmware');

      if (outcome == 'verified') {
        await NotificationService.instance.createNotification(
          title: 'Firmware update confirmed',
          body: 'Your Omi now reports firmware $firmware.',
        );
      } else if (outcome != 'expired') {
        await NotificationService.instance.createNotification(
          title: 'Firmware update did not take',
          body: 'Your Omi still reports firmware ${firmware.isEmpty ? 'unknown' : firmware} '
              '(expected $target). Keep it charged and near the phone, then try the update again.',
        );
      }
    } catch (e) {
      Logger.debug('[FirmwareUpdateVerification] verify failed: $e');
    }
  }

  static bool _sameVersion(String a, String b) {
    String norm(String v) => v.trim().toLowerCase().replaceFirst(RegExp(r'^v'), '');
    return a.isNotEmpty && b.isNotEmpty && norm(a) == norm(b);
  }
}
