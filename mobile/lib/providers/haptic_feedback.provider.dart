import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';

final hapticFeedbackProvider = StateNotifierProvider<HapticNotifier, void>((ref) {
  return HapticNotifier(ref);
});

class HapticNotifier extends StateNotifier<void> {
  final Ref _ref;

  HapticNotifier(this._ref) : super(null);

  void selectionClick() {
    _emit(HapticFeedback.selectionClick);
  }

  void mediumImpact() {
    _emit(HapticFeedback.mediumImpact);
  }

  void heavyImpact() {
    _emit(HapticFeedback.heavyImpact);
  }

  void _emit(Future<void> Function() feedback) {
    if (_ref.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableHapticFeedback)) {
      unawaited(_perform(feedback));
    }
  }

  Future<void> _perform(Future<void> Function() feedback) async {
    try {
      // Native system settings remain authoritative. No vibration fallback or
      // repeated call may override a device which declines this feedback.
      await feedback();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
