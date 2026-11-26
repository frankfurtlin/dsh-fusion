// The phone's own side of `dsh/runtime`, kept after the on-device engine went
// away (2026-11-26): what 后台保活, 系统权限 and 手机文件 ask the Android/iOS/
// HarmonyOS host — whether the maker blocks background running, the battery
// exemption, whether the storage permission is there, the maker's own settings
// pages. Nothing here starts, installs or tracks a DSH runtime.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_protection.dart';

/// Whether the app can see the phone's shared storage.
class StorageAccess {
  const StorageAccess({
    required this.granted,
    required this.permission,
    required this.legacy,
    this.guestPath = '/sdcard',
  });

  factory StorageAccess.fromMap(Map<Object?, Object?> map) => StorageAccess(
    granted: map['granted'] == true,
    permission: map['permission'] == true,
    legacy: map['legacy'] == true,
    guestPath: map['guestPath'] as String? ?? '/sdcard',
  );

  final bool granted;

  /// The runtime permission is granted (may still need "All files access" when not [legacy]).
  final bool permission;
  final bool legacy;
  final String guestPath;
}

/// See [DeviceBridge.backgroundSettings].
class BackgroundSettingsInfo {
  const BackgroundSettingsInfo({this.vendor, this.label});
  final String? vendor;
  final String? label;
}

class DeviceBridge {
  DeviceBridge({MethodChannel? methods}) : _methods = methods ?? const MethodChannel('dsh/runtime');

  final MethodChannel _methods;

  /// HarmonyOS: whether this build may schedule system reminders: `granted`,
  /// `denied` or `unsupported`.
  Future<String?> reminderAccess() => _methods.invokeMethod<String>('reminderAccess');

  Future<StorageAccess> storageStatus() async =>
      StorageAccess.fromMap(await _methods.invokeMapMethod<Object?, Object?>('storageStatus') ?? const {});

  /// Shows the system storage permission prompt; resolves with the resulting access.
  Future<StorageAccess> requestStorage() async =>
      StorageAccess.fromMap(await _methods.invokeMapMethod<Object?, Object?>('requestStorage') ?? const {});

  /// Opens Android's "All files access" page for this app (fallback when legacy access is off).
  Future<bool> openAllFilesAccess() async => await _methods.invokeMethod<bool>('openAllFilesAccess') ?? false;

  /// Optional native background protection; old hosts expose no switches.
  Future<BackgroundProtection?> backgroundProtection() async {
    try {
      return BackgroundProtection.fromMap(await _methods.invokeMapMethod<Object?, Object?>('backgroundProtection'));
    } on MissingPluginException {
      return null;
    }
  }

  Future<BackgroundProtection?> setBackgroundProtection({
    bool? audioEnabled,
    bool? locationEnabled,
    bool? taskEnabled,
  }) async => BackgroundProtection.fromMap(
    await _methods.invokeMapMethod<Object?, Object?>('setBackgroundProtection', {
      'audioEnabled': ?audioEnabled,
      'locationEnabled': ?locationEnabled,
      'taskEnabled': ?taskEnabled,
    }),
  );

  /// Opens the relevant system settings, without assuming permission was granted.
  Future<bool> openBackgroundProtectionSettings() async {
    try {
      return await _methods.invokeMethod<bool>('openBackgroundProtectionSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Whether Android leaves DSH out of battery optimization; null without the native side.
  Future<bool?> batteryExempt() async {
    try {
      return await _methods.invokeMethod<bool>('batteryExempt');
    } on MissingPluginException {
      return null;
    }
  }

  /// Asks for the exemption (the system dialog, else the closest settings page); false if none opened.
  Future<bool?> requestBatteryExempt() async {
    try {
      return await _methods.invokeMethod<bool>('requestBatteryExempt');
    } on MissingPluginException {
      return null;
    }
  }

  /// The phone maker (`vivo`, `xiaomi`, `huawei`, `honor`, `oppo`, `samsung`, null for the
  /// rest) and the app's name as the system settings list it; null without the native side.
  Future<BackgroundSettingsInfo?> backgroundSettings() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('backgroundSettings');
      if (map == null) return null;
      return BackgroundSettingsInfo(vendor: map['vendor'] as String?, label: map['label'] as String?);
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the maker's background-running page, else the app's system details page:
  /// `vendor`, `details`, or null when nothing opened.
  Future<String?> openBackgroundSettings() async {
    try {
      return await _methods.invokeMethod<String>('openBackgroundSettings');
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the maker's page for one of its own switches ([vendorSwitch]: `background`,
  /// `autostart`, `popup`), else the app's system details page: `vendor`, `details`, or null
  /// when nothing opened (also without the native side).
  Future<String?> openVendorSettings(String vendorSwitch) async {
    try {
      return await _methods.invokeMethod<String>('openVendorSettings', {'switch': vendorSwitch});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Whether the active network is metered (mobile data); null when unknown or without the
  /// native side.
  Future<bool?> networkMetered() async {
    try {
      return await _methods.invokeMethod<bool>('networkMetered');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final deviceBridgeProvider = Provider<DeviceBridge>((ref) => DeviceBridge());

/// [DeviceBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(deviceBridgeProvider).batteryExempt());

/// Re-read after native status changes and when returning from system settings.
/// Native failures must settle the pending update, not wait for automatic retries.
final backgroundProtectionProvider = FutureProvider.autoDispose<BackgroundProtection?>(
  (ref) => ref.watch(deviceBridgeProvider).backgroundProtection(),
  retry: (_, _) => null,
);

/// The phone maker and the app's name in system settings; null without the native side.
final backgroundSettingsProvider = FutureProvider<BackgroundSettingsInfo?>(
  (ref) => ref.watch(deviceBridgeProvider).backgroundSettings(),
);
