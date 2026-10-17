import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final cloudMediaRepositoryProvider = Provider((_) => const CloudMediaRepository());

/// Android-only bridge. Native admission is independent of media/session reads.
class CloudMediaRepository {
  const CloudMediaRepository([this._channel = const MethodChannel('app.alextran.immich/cloudMedia')]);

  final MethodChannel _channel;

  Future<Map<String, Object?>> status() => _operation('status');
  Future<Map<String, Object?>> enable() => _operation('enable');
  Future<Map<String, Object?>> disable() => _operation('disable');
  Future<Map<String, Object?>> diagnose() => _operation('diagnose');
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
  Future<void> openPickerSettings() => _channel.invokeMethod<void>('openPickerSettings');

  Future<Map<String, Object?>> _operation(String method) async {
    final result = await _channel.invokeMapMethod<String, Object?>(method);
    return result ?? const {};
  }
}
