import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery_reason.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery_server.page.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';

/// Deliberately independent of Riverpod, Store, account routing and log DB.
/// A second tap is disabled until completion; no repair runs from initState.
class SqliteRecoveryPage extends StatefulWidget {
  final Future<void> Function() recoverAndOpen;
  final Future<bool> Function() exportBackup;
  final Future<RecoveryServerClient> Function()? openServerPhotos;
  final Future<FreshStartPreparation?> Function()? prepareFreshStart;
  final Future<void> Function(FreshStartPreparation)? startFreshAndOpen;
  const SqliteRecoveryPage({
    super.key,
    required this.recoverAndOpen,
    required this.exportBackup,
    this.openServerPhotos,
    this.prepareFreshStart,
    this.startFreshAndOpen,
  });

  @override
  State<SqliteRecoveryPage> createState() => _SqliteRecoveryPageState();
}

class _SqliteRecoveryPageState extends State<SqliteRecoveryPage> {
  bool _busy = false;
  bool _confirming = false;
  bool _failed = false;
  bool _completed = false;
  bool _exportFailed = false;
  String? _reason;

  Future<void> _recover() async {
    if (_busy || _completed) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
      _reason = null;
    });
    try {
      await widget.recoverAndOpen();
      _completed = true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _reason = recoveryReasonCode(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _server(BuildContext navigatorContext) async {
    if (_busy || _completed) {
      return;
    }
    setState(() {
      _busy = true;
      _reason = null;
    });
    RecoveryServerClient? client;
    try {
      client = await widget.openServerPhotos!();
      if (!navigatorContext.mounted) {
        return;
      }
      await Navigator.of(
        navigatorContext,
      ).push<void>(MaterialPageRoute(builder: (_) => SqliteRecoveryServerPage(client: client!)));
    } catch (error) {
      if (mounted) {
        setState(() => _reason = recoveryReasonCode(error));
      }
    } finally {
      client?.close();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _exportFailed = false;
    });
    try {
      await widget.exportBackup();
    } catch (_) {
      if (mounted) {
        setState(() => _exportFailed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _fresh(BuildContext navigatorContext) async {
    if (_busy || _completed) {
      return;
    }
    setState(() {
      _busy = true;
      _reason = null;
    });
    try {
      final preparation = await widget.prepareFreshStart!();
      if (preparation == null || !navigatorContext.mounted) {
        return;
      }
      var acceptsLoss = false;
      setState(() => _confirming = true);
      final consent = await showDialog<bool>(
        context: navigatorContext,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (_, update) => AlertDialog(
            title: Text('sqlite_fresh_title'.tr()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('sqlite_fresh_warning'.tr()),
                  if (preparation.needsLogin) Text('sqlite_fresh_login'.tr()),
                  CheckboxListTile(
                    value: acceptsLoss,
                    onChanged: (value) => update(() => acceptsLoss = value == true),
                    title: Text('sqlite_fresh_accept_loss'.tr()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('cancel'.tr())),
              FilledButton(
                onPressed: acceptsLoss ? () => Navigator.of(dialogContext).pop(true) : null,
                child: Text('sqlite_fresh_confirm'.tr()),
              ),
            ],
          ),
        ),
      );
      if (mounted) {
        setState(() => _confirming = false);
      }
      if (consent != true) {
        return;
      }
      await widget.startFreshAndOpen!(preparation);
      _completed = true;
    } catch (error) {
      if (mounted) {
        setState(() => _reason = recoveryReasonCode(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: context.localizationDelegates,
    supportedLocales: context.supportedLocales,
    locale: context.locale,
    home: Builder(
      builder: (context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.health_and_safety_outlined, size: 64),
                    const SizedBox(height: 24),
                    if (_reason != null) ...[
                      Text(recoveryReasonKey(_reason!).tr(), textAlign: TextAlign.center),
                      SelectableText('${'sqlite_recovery_code'.tr()}: $_reason'),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'sqlite_recovery_title'.tr(),
                      style: const TextStyle(fontSize: 26),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      (_failed ? 'sqlite_recovery_failed' : 'sqlite_recovery_description').tr(),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (_busy && !_confirming) ...[const CircularProgressIndicator(), const SizedBox(height: 16)],
                    FilledButton(
                      onPressed: _busy || _completed ? null : _recover,
                      child: Text('sqlite_recovery_open'.tr()),
                    ),
                    if (widget.openServerPhotos != null)
                      OutlinedButton(
                        onPressed: _busy || _completed ? null : () => _server(context),
                        child: Text('sqlite_recovery_server_open'.tr()),
                      ),
                    if (widget.prepareFreshStart != null && widget.startFreshAndOpen != null)
                      OutlinedButton(
                        onPressed: _busy || _completed ? null : () => _fresh(context),
                        child: Text('sqlite_fresh_title'.tr(), textAlign: TextAlign.center),
                      ),
                    // Also available after process death/OOM, before another
                    // repair attempt could repeat the same failure.
                    TextButton(
                      onPressed: _busy || _completed ? null : _export,
                      child: Text('sqlite_recovery_export'.tr()),
                    ),
                    if (_exportFailed) Text('sqlite_recovery_export_failed'.tr()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
