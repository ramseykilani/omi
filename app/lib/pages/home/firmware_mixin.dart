import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:flutter_archive/flutter_archive.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'package:omi/backend/http/api/device.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/fork_diagnostics_log.dart';
import 'package:omi/utils/firmware_update_verification.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/utils/analytics/firmware_update_telemetry.dart';
import 'package:omi/utils/firmware_update_build_policy.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/manifest/manifest.dart';

/// Why an Omi firmware update stopped, so the page can say what happened and what to do.
enum FirmwareUpdateFailure {
  /// The firmware file could not be downloaded (network).
  download,

  /// The device did not accept the update (connection lost, device rejected it).
  install,
}

/// The lowest battery an Omi firmware update may start at. Enforced in code, not left to a
/// checklist.
const int kFirmwareUpdateMinBattery = 15;

mixin FirmwareMixin<T extends StatefulWidget> on State<T> {
  FirmwareUpdateBuildPolicy get firmwareUpdatePolicy => FirmwareUpdateBuildPolicy.current;

  Map latestFirmwareDetails = {};
  bool isDownloading = false;
  bool isDownloaded = false;
  int downloadProgress = 0;
  bool isInstalling = false;
  bool isInstalled = false;
  int installProgress = 0;
  bool isLegacySecureDFU = true;
  List<String> otaUpdateSteps = [];

  /// Set when the last attempt failed; cleared when a new attempt starts. The page shows a failed
  /// state with the cause, Try Again and Contact Support instead of silently resetting.
  FirmwareUpdateFailure? updateFailure;

  /// The raw error behind [updateFailure], shown as a technical detail line so a
  /// failed OTA can be reported with something more specific than "failed".
  String? updateFailureDetail;

  int _lastLoggedProgressBucket = -1;

  void _otaLog(String step, [Map<String, Object?> data = const {}]) {
    ForkDiagnosticsLog.instance.record('ota', {'step': step, ...data});
  }

  /// DFU "success" only means the device acknowledged the upload and reset; the
  /// version it reports after rebooting is checked on the next connect.
  void _markInstalledPendingVerification(BtDevice btDevice) {
    final target = latestFirmwareDetails['version']?.toString() ?? '';
    _otaLog('reported_success', {'device': btDevice.id, 'from': btDevice.firmwareRevision, 'target': target});
    if (target.isEmpty) return;
    unawaited(FirmwareUpdateVerification.markPending(
      deviceId: btDevice.id,
      fromVersion: btDevice.firmwareRevision,
      targetVersion: target,
    ));
  }

  void _logProgress(int percent) {
    final bucket = percent ~/ 10;
    if (bucket == _lastLoggedProgressBucket) return;
    _lastLoggedProgressBucket = bucket;
    _otaLog('progress', {'percent': percent});
  }

  void _fail(FirmwareUpdateFailure failure, [Object? error]) {
    _otaLog('failed', {'failure': failure.name, 'error': error?.toString()});
    if (!mounted) return;
    setState(() {
      isDownloading = false;
      isInstalling = false;
      updateFailure = failure;
      updateFailureDetail = error?.toString();
    });
    Provider.of<DeviceProvider>(context, listen: false).resetFirmwareUpdateState();
  }

  /// Clears a previous failure before retrying.
  void clearFirmwareFailure() {
    if (updateFailure == null) return;
    setState(() {
      updateFailure = null;
      updateFailureDetail = null;
    });
  }

  late final mcumgr.FirmwareUpdateManagerFactory? managerFactory =
      firmwareUpdatePolicy.allowsOmiFirmwareUpdate ? mcumgr.FirmwareUpdateManagerFactory() : null;
  mcumgr.FirmwareUpdateManager? _mcuUpdateManager;
  FirmwareUpdateTelemetry? _firmwareTelemetry;

  /// Process ZIP file and return firmware image list
  Future<List<mcumgr.Image>> processZipFile(Uint8List zipFileData) async {
    // Create temporary directory
    final prefix = 'firmware_${const Uuid().v4()}';
    final systemTempDir = await getTemporaryDirectory();
    final tempDir = Directory('${systemTempDir.path}/$prefix');
    await tempDir.create();

    try {
      // Write ZIP data to temporary file
      final firmwareFile = File('${tempDir.path}/firmware.zip');
      await firmwareFile.writeAsBytes(zipFileData);

      // Create destination directory for extraction
      final destinationDir = Directory('${tempDir.path}/firmware');
      await destinationDir.create();

      // Extract ZIP file
      await ZipFile.extractToDirectory(zipFile: firmwareFile, destinationDir: destinationDir);

      // Read and parse manifest.json
      final manifestFile = File('${destinationDir.path}/manifest.json');
      final manifestString = await manifestFile.readAsString();
      final manifestJson = json.decode(manifestString);
      final manifest = Manifest.fromJson(manifestJson);

      // Process firmware files
      final List<mcumgr.Image> firmwareImages = [];
      for (final file in manifest.files) {
        final firmwareFile = File('${destinationDir.path}/${file.file}');
        final firmwareFileData = await firmwareFile.readAsBytes();
        final image = mcumgr.Image(image: file.image, data: firmwareFileData);
        firmwareImages.add(image);
      }

      return firmwareImages;
    } catch (e) {
      throw Exception('Failed to process ZIP file: $e');
    } finally {
      // Cleanup: Delete temporary directory
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> startDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    if (!firmwareUpdatePolicy.allowsOmiFirmwareUpdate) {
      Logger.debug('Omi firmware updates are unavailable in the Ray-Ban DAT build');
      return;
    }
    if (isLegacySecureDFU) {
      _firmwareTelemetry = FirmwareUpdateTelemetry.start(device: btDevice, protocol: 'nordic_dfu');
      return startLegacyDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
    }
    return startMCUDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
  }

  Future<void> killMcuUpdateManager() async {
    if (_mcuUpdateManager != null) {
      try {
        await _mcuUpdateManager!.kill();
      } catch (e) {
        Logger.debug('Error killing update manager: $e');
      }
      _mcuUpdateManager = null;
    }
  }

  Future<void> startMCUDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    if (!firmwareUpdatePolicy.allowsOmiFirmwareUpdate) {
      Logger.debug('MCU firmware updates are unavailable in the Ray-Ban DAT build');
      return;
    }
    _firmwareTelemetry = FirmwareUpdateTelemetry.start(device: btDevice, protocol: 'mcumgr');
    _lastLoggedProgressBucket = -1;
    _otaLog('start', {
      'protocol': 'mcumgr',
      'device': btDevice.id,
      'from': btDevice.firmwareRevision,
      'target': latestFirmwareDetails['version']?.toString(),
      'local_file': zipFilePath != null,
    });
    setState(() {
      isInstalling = true;
      updateFailure = null;
      updateFailureDetail = null;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));

    String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
    final file = File(firmwareFile);
    if (!await file.exists()) {
      _firmwareTelemetry?.failed(failureClass: 'firmware_file_missing');
      Logger.debug('Firmware file not found: $firmwareFile');
      _fail(FirmwareUpdateFailure.download, 'firmware file not found');
      return;
    }
    final bytes = await file.readAsBytes();
    const configuration = mcumgr.FirmwareUpgradeConfiguration(
      estimatedSwapTime: Duration(seconds: 0),
      eraseAppSettings: true,
      pipelineDepth: 1,
    );

    await killMcuUpdateManager();
    final mcumgr.FirmwareUpdateManager updateManager;
    final List<mcumgr.Image> images;
    try {
      updateManager = await managerFactory!.getUpdateManager(btDevice.id);
      _mcuUpdateManager = updateManager;
      // A corrupt download (e.g. a captive-portal page saved as the zip) throws here; it must end in
      // the failed state, not an installing spinner with back blocked.
      images = await processZipFile(bytes);
    } catch (e) {
      _firmwareTelemetry?.failed(failureClass: 'native_dfu_error');
      Logger.debug('update preparation failed: $e');
      _fail(FirmwareUpdateFailure.install, e);
      return;
    }

    final updateStream = updateManager.setup();

    // The stream reports every stage (validate, upload, test, reset, confirm) and ends in success;
    // a failure arrives as a stream error, and a cancel closes the stream without success.
    var succeeded = false;
    updateStream.listen(
      (state) {
        Logger.debug('update state: $state');
        _otaLog('state', {'state': state.toString()});
        if (state != mcumgr.FirmwareUpgradeState.success) return;
        succeeded = true;
        _firmwareTelemetry?.completed(toVersion: latestFirmwareDetails['version']?.toString());
        Logger.debug('update success');
        _markInstalledPendingVerification(btDevice);
        killMcuUpdateManager();
        if (!mounted) return;
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      },
      onError: (Object error) {
        _firmwareTelemetry?.failed(failureClass: 'native_dfu_error');
        Logger.debug('update error: $error');
        _fail(FirmwareUpdateFailure.install, error);
      },
      onDone: () {
        if (succeeded || !isInstalling) return;
        _firmwareTelemetry?.failed(failureClass: 'native_dfu_error');
        _fail(FirmwareUpdateFailure.install, 'update stream closed before success (cancelled or link lost)');
      },
    );

    updateManager.progressStream.listen((progress) {
      Logger.debug('progress: $progress');
      if (!mounted) return;
      final percent = (progress.bytesSent / progress.imageSize * 100).round();
      _logProgress(percent);
      setState(() {
        installProgress = percent;
      });
    });

    updateManager.logger.logMessageStream
        .where((log) => log.level.rawValue > 1) // Filter debug messages
        .listen((log) {
      Logger.debug('dfu log: ${log.message}');
      if (log.level.rawValue >= 4) _otaLog('mcumgr_log', {'level': log.level.rawValue, 'message': log.message});
    });

    try {
      await updateManager.update(images, configuration: configuration);
    } catch (e) {
      _firmwareTelemetry?.failed(failureClass: 'native_dfu_error');
      Logger.debug('update start failed: $e');
      _fail(FirmwareUpdateFailure.install, e);
    }
  }

  Future<void> startLegacyDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    if (!firmwareUpdatePolicy.allowsOmiFirmwareUpdate) {
      Logger.debug('Legacy firmware updates are unavailable in the Ray-Ban DAT build');
      return;
    }
    _lastLoggedProgressBucket = -1;
    _otaLog('start', {
      'protocol': 'nordic_dfu',
      'device': btDevice.id,
      'from': btDevice.firmwareRevision,
      'target': latestFirmwareDetails['version']?.toString(),
      'local_file': zipFilePath != null,
    });
    setState(() {
      isInstalling = true;
      updateFailure = null;
      updateFailureDetail = null;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));
    String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
    NordicDfu dfu = NordicDfu();
    await dfu.startDfu(
      btDevice.id,
      firmwareFile,
      fileInAsset: fileInAssets,
      numberOfPackets: 8,
      enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
      iosSpecialParameter: const IosSpecialParameter(
        packetReceiptNotificationParameter: 8,
        forceScanningForNewAddressInLegacyDfu: true,
        connectionTimeout: 60,
      ),
      androidSpecialParameter: const AndroidSpecialParameter(packetReceiptNotificationsEnabled: true, rebootTime: 1000),
      onProgressChanged: (deviceAddress, percent, speed, avgSpeed, currentPart, partsTotal) {
        Logger.debug('deviceAddress: $deviceAddress, percent: $percent');
        _logProgress(percent.toInt());
        if (!mounted) return;
        setState(() {
          installProgress = percent.toInt();
        });
      },
      onError: (deviceAddress, error, errorType, message) {
        _firmwareTelemetry?.failed(failureClass: 'native_dfu_error');
        Logger.debug('deviceAddress: $deviceAddress, error: $error, errorType: $errorType, message: $message');
        _fail(FirmwareUpdateFailure.install, 'error=$error type=$errorType message=$message');
      },
      onDeviceConnecting: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDeviceConnecting'),
      onDeviceConnected: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDeviceConnected'),
      onDfuProcessStarting: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDfuProcessStarting'),
      onDfuProcessStarted: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDfuProcessStarted'),
      onEnablingDfuMode: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onEnablingDfuMode'),
      onFirmwareValidating: (deviceAddress) => Logger.debug('address: $deviceAddress, onFirmwareValidating'),
      onDfuCompleted: (deviceAddress) {
        _firmwareTelemetry?.completed(toVersion: latestFirmwareDetails['version']?.toString());
        Logger.debug('deviceAddress: $deviceAddress, onDfuCompleted');
        _markInstalledPendingVerification(btDevice);
        if (!mounted) return;
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      },
    );
  }

  Future getLatestVersion({
    required String deviceModelNumber,
    required String firmwareRevision,
    required String hardwareRevision,
    required String manufacturerName,
  }) async {
    latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: deviceModelNumber,
      firmwareRevision: firmwareRevision,
      hardwareRevision: hardwareRevision,
      manufacturerName: manufacturerName,
    );
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future getStableVersion({required String deviceModelNumber}) async {
    latestFirmwareDetails = await getStableFirmwareVersion(deviceModelNumber: deviceModelNumber);
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future<(String, bool, String)> shouldUpdateFirmware({required String currentFirmware}) async {
    return DeviceUtils.shouldUpdateFirmware(
      currentFirmware: currentFirmware,
      latestFirmwareDetails: latestFirmwareDetails,
    );
  }

  /// Downloads the firmware. Returns false (and sets [updateFailure]) when it could not.
  Future<bool> downloadFirmware() async {
    final zipUrl = latestFirmwareDetails['zip_url'];
    if (zipUrl == null) {
      Logger.debug('Error: zip_url is null in latestFirmwareDetails');
      _fail(FirmwareUpdateFailure.download, 'zip_url missing from firmware details');
      return false;
    }

    String dir = (await getApplicationDocumentsDirectory()).path;

    setState(() {
      isDownloading = true;
      isDownloaded = false;
      downloadProgress = 0;
      updateFailure = null;
    });

    try {
      _otaLog('download_start', {'url': zipUrl.toString(), 'target': latestFirmwareDetails['version']?.toString()});
      final r = await makeRawApiCall(method: 'GET', url: zipUrl);
      // An error page saved as firmware.zip only fails later as a confusing
      // "install" error; reject it here as the download failure it is.
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw HttpException('firmware download HTTP ${r.statusCode}');
      }
      final completer = Completer<void>();
      final int? totalBytes = r.contentLength;

      List<List<int>> chunks = [];
      int downloaded = 0;

      r.stream.listen(
        (List<int> chunk) {
          chunks.add(chunk);
          downloaded += chunk.length;
          if (totalBytes != null && totalBytes > 0 && mounted) {
            Logger.debug('downloadPercentage: ${downloaded / totalBytes * 100}');
            setState(() {
              downloadProgress = (downloaded / totalBytes * 100).toInt();
            });
          }
        },
        onDone: () async {
          try {
            Logger.debug('downloadPercentage: 100');
            if (totalBytes != null && totalBytes > 0 && downloaded != totalBytes) {
              throw HttpException('firmware download truncated: $downloaded of $totalBytes bytes');
            }
            _otaLog('download_done', {'bytes': downloaded});
            File file = File('$dir/firmware.zip');
            final Uint8List bytes = Uint8List(downloaded);
            int offset = 0;
            for (List<int> chunk in chunks) {
              bytes.setRange(offset, offset + chunk.length, chunk);
              offset += chunk.length;
            }
            await file.writeAsBytes(bytes);
            if (mounted) {
              setState(() {
                isDownloading = false;
                isDownloaded = true;
                downloadProgress = 100;
              });
            }
            completer.complete();
          } catch (e) {
            completer.completeError(e);
          }
        },
        onError: (error) {
          Logger.debug('Download error: $error');
          completer.completeError(error);
        },
      );

      await completer.future;
      return true;
    } catch (e) {
      Logger.debug('Download error: $e');
      _fail(FirmwareUpdateFailure.download, e);
      return false;
    }
  }
}
