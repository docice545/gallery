import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Deliberately independent of Riverpod, Store, account routing and log DB.
/// A second tap is disabled until completion; no repair runs from initState.
class SqliteRecoveryPage extends StatefulWidget {
  final Future<void> Function() recoverAndOpen;
  final Future<bool> Function() exportBackup;
  const SqliteRecoveryPage({super.key, required this.recoverAndOpen, required this.exportBackup});

  @override
  State<SqliteRecoveryPage> createState() => _SqliteRecoveryPageState();
}

class _SqliteRecoveryPageState extends State<SqliteRecoveryPage> {
  bool _busy = false;
  bool _failed = false;
  bool _exportFailed = false;

  Future<void> _recover() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.recoverAndOpen();
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
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
                    if (_busy) ...[const CircularProgressIndicator(), const SizedBox(height: 16)],
                    FilledButton(onPressed: _busy ? null : _recover, child: Text('sqlite_recovery_open'.tr())),
                    if (_failed)
                      TextButton(onPressed: _busy ? null : _export, child: Text('sqlite_recovery_export'.tr())),
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
