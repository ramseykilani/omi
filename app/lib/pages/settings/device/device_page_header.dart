import 'dart:async';

import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/ui/ui.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/device_widget.dart';

/// Top of the device page: the device's name, a Connected / Disconnected pill and its picture.
class DevicePageHeader extends StatelessWidget {
  const DevicePageHeader({super.key, required this.pairedDevice, required this.connectedDevice});

  final BtDevice? pairedDevice;
  final BtDevice? connectedDevice;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isConnected = connectedDevice != null;
    final stateColor = isConnected ? OmiColors.success : OmiColors.textSecondary;
    return Column(
      children: [
        Semantics(
          header: true,
          child: Text(
            _displayName(pairedDevice?.name, l10n.omiAppName),
            style: OmiType.title1,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: OmiSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.sm, vertical: 6),
          decoration: BoxDecoration(
            color: isConnected ? OmiColors.successSurface : OmiColors.surface2,
            borderRadius: OmiRadius.pillAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                isConnected ? l10n.connected : l10n.disconnected,
                style: OmiType.footnote.copyWith(color: stateColor, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        const SizedBox(height: OmiSpacing.md),
        // The pulsing background only runs while the device is connected, and never under
        // Reduce Motion; muting the ticker also stops it scheduling frames when it is hidden.
        ExcludeSemantics(
          child: TickerMode(
            enabled: isConnected && !MediaQuery.disableAnimationsOf(context),
            child: DeviceAnimationWidget(
              sizeMultiplier: 0.7,
              deviceType: connectedDevice?.type,
              modelNumber: connectedDevice?.modelNumber,
              isConnected: isConnected,
              deviceName: connectedDevice?.name ?? pairedDevice?.name,
              animatedBackground: isConnected,
            ),
          ),
        ),
      ],
    );
  }
}

/// The battery row: level (or "Charging") with a level-coloured icon.
/// "just now" / "5 min ago" / "3 h ago" / "2 d ago" for freshness labels.
/// Fork-only diagnostic copy; English only.
String formatAgo(DateTime at, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(at);
  if (age.inSeconds < 60) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 48) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// Rebuilds [builder] every [interval] so relative times ("2 min ago") and
/// staleness stay honest even when nothing upstream notifies.
class PeriodicRebuild extends StatefulWidget {
  const PeriodicRebuild({super.key, required this.builder, this.interval = const Duration(seconds: 30)});

  final WidgetBuilder builder;
  final Duration interval;

  @override
  State<PeriodicRebuild> createState() => _PeriodicRebuildState();
}

class _PeriodicRebuildState extends State<PeriodicRebuild> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class DeviceBatteryGroup extends StatelessWidget {
  const DeviceBatteryGroup({
    super.key,
    required this.batteryLevel,
    required this.isCharging,
    this.updatedAt,
    this.isConnected = true,
    this.staleAfter = const Duration(minutes: 2),
  });

  final int batteryLevel;
  final bool isCharging;

  /// When the device last reported [batteryLevel]; null when unknown.
  final DateTime? updatedAt;
  final bool isConnected;
  final Duration staleAfter;

  bool get _isStale => !isConnected || updatedAt == null || DateTime.now().difference(updatedAt!) > staleAfter;

  String? get _subtitle {
    final at = updatedAt;
    if (at == null) return isConnected ? null : 'Last known level';
    if (!isConnected) return 'Last known level, reported ${formatAgo(at)}';
    if (_isStale) return 'No update since ${formatAgo(at)}; reading may be stale';
    return 'Updated ${formatAgo(at)}';
  }

  FaIconData get _icon {
    if (batteryLevel > 75) return FontAwesomeIcons.batteryFull;
    if (batteryLevel > 50) return FontAwesomeIcons.batteryThreeQuarters;
    if (batteryLevel > 25) return FontAwesomeIcons.batteryHalf;
    if (batteryLevel > 10) return FontAwesomeIcons.batteryQuarter;
    return FontAwesomeIcons.batteryEmpty;
  }

  Color get _color {
    if (batteryLevel > 75) return OmiColors.success;
    if (batteryLevel > 20) return OmiColors.warning;
    return OmiColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    return OmiSettingsGroup(
      children: [
        OmiSettingsRow(
          leading: isCharging && isConnected
              ? FaIcon(FontAwesomeIcons.chargingStation, color: OmiColors.success)
              : FaIcon(_icon, color: _isStale ? OmiColors.textTertiary : _color),
          title: isCharging && isConnected ? context.l10n.charging : context.l10n.batteryLevel,
          subtitle: _subtitle,
          value: _isStale ? '~$batteryLevel%' : '$batteryLevel%',
        ),
      ],
    );
  }
}

/// Shown instead of the device controls while the device is not connected.
class DeviceDisconnectedCard extends StatelessWidget {
  const DeviceDisconnectedCard({super.key, this.lastConnectedAt, this.lastDisconnectedAt});

  final DateTime? lastConnectedAt;
  final DateTime? lastDisconnectedAt;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(OmiSpacing.xxl),
      decoration: BoxDecoration(color: OmiColors.surface1, borderRadius: OmiRadius.lgAll),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: OmiColors.surface2, borderRadius: OmiRadius.lgAll),
            child: Center(child: FaIcon(FontAwesomeIcons.linkSlash, color: OmiColors.textTertiary, size: 24)),
          ),
          const SizedBox(height: OmiSpacing.lg),
          Text(context.l10n.deviceNotConnected, style: OmiType.headline, textAlign: TextAlign.center),
          const SizedBox(height: OmiSpacing.xs),
          Text(
            context.l10n.connectDeviceMessage,
            textAlign: TextAlign.center,
            style: OmiType.subhead.copyWith(color: OmiColors.textSecondary, height: 1.4),
          ),
          if (lastDisconnectedAt != null || lastConnectedAt != null) ...[
            const SizedBox(height: OmiSpacing.md),
            Text(
              key: const Key('device_last_seen'),
              lastDisconnectedAt != null
                  ? 'Last seen ${formatAgo(lastDisconnectedAt!)}'
                  : 'Last connected ${formatAgo(lastConnectedAt!)}',
              textAlign: TextAlign.center,
              style: OmiType.caption.copyWith(color: OmiColors.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Live Bluetooth-in / network-out data rates, shown while the device is streaming audio.
class DeviceStreamingMetrics extends StatelessWidget {
  const DeviceStreamingMetrics({super.key, required this.bleReceiveKbps, required this.wsSendKbps});

  final double bleReceiveKbps;
  final double wsSendKbps;

  @override
  Widget build(BuildContext context) {
    final style = OmiType.subhead.copyWith(color: OmiColors.textTertiary);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FaIcon(FontAwesomeIcons.bluetooth, color: OmiColors.textTertiary, size: 14),
        const SizedBox(width: 6),
        Text(context.l10n.dataRateKbps(bleReceiveKbps.toStringAsFixed(1)), style: style),
        const SizedBox(width: OmiSpacing.xl),
        FaIcon(FontAwesomeIcons.signal, color: OmiColors.textTertiary, size: 14),
        const SizedBox(width: 6),
        Text(context.l10n.dataRateKbps(wsSendKbps.toStringAsFixed(1)), style: style),
      ],
    );
  }
}

/// The device's own name, or "Omi" while none is cached (BtDevice reports a missing name as the
/// English word 'Unknown').
String _displayName(String? name, String fallback) =>
    name == null || name.trim().isEmpty || name == 'Unknown' ? fallback : name;
