import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/cloud_media.repository.dart';

/// Explicit opt-in pilot; displays verified admission/selection separately.
class CloudMediaSettings extends ConsumerStatefulWidget {
  const CloudMediaSettings({super.key});

  @override
  ConsumerState<CloudMediaSettings> createState() => _CloudMediaSettingsState();
}

class _CloudMediaSettingsState extends ConsumerState<CloudMediaSettings> with WidgetsBindingObserver {
  Map<String, Object?> _status = const {};
  bool _busy = false;
  bool _failed = false;

  late final CloudMediaRepository _repository;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(cloudMediaRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_repository.status));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) {
      unawaited(_run(_repository.status));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The native operation retains its recovery journal if mutation was uncertain.
    if (_busy) {
      unawaited(_repository.cancel());
    }
    super.dispose();
  }

  Future<void> _run(Future<Map<String, Object?>> Function() operation) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final status = await operation();
      if (mounted) {
        setState(() => _status = status);
      }
    } catch (_) {
      final status = await _repository.status().catchError((_) => _status);
      if (mounted) {
        setState(() {
          _status = status;
          _failed = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = _status['enabled'] == true;
    final status = _failed
        ? t.cloud_media_failed
        : _status['supported'] == false
        ? t.cloud_media_unsupported
        : _status['signedIn'] == false
        ? t.cloud_media_signed_out
        : _status['selected'] == true && enabled
        ? t.cloud_media_selected
        : _status['admitted'] == true && enabled
        ? t.cloud_media_admitted
        : enabled
        ? t.cloud_media_enabled
        : t.cloud_media_disabled;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.cloud_media_title, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(t.cloud_media_instructions),
          const SizedBox(height: 8),
          Text(status),
          if (_status['recoveryPending'] == true && !enabled) Text(t.cloud_media_recovery_pending),
          if (_busy) ...[
            const LinearProgressIndicator(),
            TextButton(onPressed: () => unawaited(_repository.cancel()), child: Text(t.cancel)),
          ] else
            Wrap(
              spacing: 8,
              children: [
                if (!enabled)
                  TextButton(
                    onPressed: _status['supported'] == false || _status['signedIn'] == false
                        ? null
                        : () => unawaited(_run(_repository.enable)),
                    child: Text(t.cloud_media_enable),
                  ),
                if (enabled || _status['recoveryPending'] == true)
                  TextButton(onPressed: () => unawaited(_run(_repository.disable)), child: Text(t.cloud_media_disable)),
                TextButton(
                  onPressed: () => unawaited(_run(_repository.diagnose)),
                  child: Text(t.cloud_media_diagnostics),
                ),
                if (enabled)
                  TextButton(
                    onPressed: () async {
                      try {
                        await _repository.openPickerSettings();
                      } catch (_) {
                        if (mounted) {
                          setState(() => _failed = true);
                        }
                      }
                    },
                    child: Text(t.cloud_media_picker_settings),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
