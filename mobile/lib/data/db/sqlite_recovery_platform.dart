import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';

/// Admission is native and shared by every Flutter engine/isolate. No fallback
/// is permitted on Android if the channel, state file or OS lock fails.
abstract final class SqliteRecoveryPlatform {
  static const channel = MethodChannel('foto/sqlite_recovery');

  static Future<Map<String, String>> acquire() async {
    try {
      for (var attempt = 0; attempt < 600; attempt++) {
        final result = (await channel.invokeMapMethod<String, String>('acquire'))!;
        if (result['wait'] != 'true') {
          return result;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw const SqliteDatabaseUnhealthy('admission', 'startup probe did not finish');
    } on PlatformException {
      throw const SqliteDatabaseUnhealthy('admission', 'recovery required');
    }
  }

  static Future<void> probeComplete(String token) => channel.invokeMethod('probeComplete', {'token': token});

  static Future<void> release(String token) => channel.invokeMethod('release', {'token': token});
  static Future<void> halt() => channel.invokeMethod('halt');
  static Future<File> selected() async => File((await channel.invokeMethod<String>('path'))!);
}
