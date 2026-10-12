import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/fork_diagnostics_log.dart';
import 'package:omi/ui/ui.dart';

/// Phone-side settings that decide whether Android keeps the wearable link
/// alive in the background, plus the phone-side facts that go into the
/// diagnostics export. Fork-only diagnostic copy; English only.
class ForkPhoneSetup {
  static Future<Map<String, Object?>> snapshot() async {
    final prefs = SharedPreferencesUtil();
    bool? ignoringBatteryOptimizations;
    if (Platform.isAndroid) {
      try {
        ignoringBatteryOptimizations = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      } catch (_) {}
    }
    return {
      'background_mode_enabled': prefs.backgroundModeEnabled,
      'batch_mode_enabled': prefs.batchModeEnabled,
      'ignoring_battery_optimizations': ignoringBatteryOptimizations,
    };
  }
}

class ForkPhoneSetupSection extends StatefulWidget {
  const ForkPhoneSetupSection({super.key});

  @override
  State<ForkPhoneSetupSection> createState() => _ForkPhoneSetupSectionState();
}

class _ForkPhoneSetupSectionState extends State<ForkPhoneSetupSection> {
  Map<String, Object?>? _state;
  int? _logEntries;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final state = await ForkPhoneSetup.snapshot();
    final entries = (await ForkDiagnosticsLog.instance.readAll()).length;
    if (!mounted) return;
    setState(() {
      _state = state;
      _logEntries = entries;
    });
  }

  Future<void> _requestBatteryExemption() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
    await _refresh();
  }

  Future<void> _clearLog() async {
    await ForkDiagnosticsLog.instance.clear();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final background = state?['background_mode_enabled'] == true;
    final batch = state?['batch_mode_enabled'] == true;
    final ignoring = state?['ignoring_battery_optimizations'] as bool?;
    return OmiSettingsGroup(
      header: 'Phone setup',
      children: [
        OmiSettingsRow(
          key: const Key('fork_background_mode_row'),
          leading: const FaIcon(FontAwesomeIcons.layerGroup),
          title: 'Background mode',
          subtitle: background || batch
              ? 'Link survives closing the app'
              : 'Off: swiping the app away ends the link. Turn on under Settings > Recording & Transcription.',
          value: background ? 'On' : (batch ? 'Batch only' : 'Off'),
        ),
        if (Platform.isAndroid)
          OmiSettingsRow(
            key: const Key('fork_battery_optimization_row'),
            leading: const FaIcon(FontAwesomeIcons.batteryHalf),
            title: 'Battery optimization',
            subtitle: ignoring == false ? 'Android may suspend the link in Doze. Tap to exempt Omi.' : null,
            value: ignoring == null ? '--' : (ignoring ? 'Unrestricted' : 'Optimized'),
            onTap: ignoring == false ? _requestBatteryExemption : null,
          ),
        OmiSettingsRow(
          key: const Key('fork_log_row'),
          leading: const FaIcon(FontAwesomeIcons.listUl),
          title: 'Fork event log',
          subtitle: 'Included in Share. Tap to clear.',
          value: _logEntries == null ? '--' : '$_logEntries events',
          onTap: _clearLog,
        ),
      ],
    );
  }
}
