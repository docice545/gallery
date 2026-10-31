import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery_reason.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';

/// Emergency viewer: no application providers, local assets, disk cache, edits,
/// downloads or sync. The caller keeps the database admission barrier closed.
class SqliteRecoveryServerPage extends StatefulWidget {
  final RecoveryServerClient client;
  const SqliteRecoveryServerPage({super.key, required this.client});

  @override
  State<SqliteRecoveryServerPage> createState() => _SqliteRecoveryServerPageState();
}

class _SqliteRecoveryServerPageState extends State<SqliteRecoveryServerPage> {
  List<String>? _buckets;
  final _photos = <RecoveryServerPhoto>[];
  final _images = <String, Future<Uint8List>>{};
  int _next = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _buckets ??= await widget.client.buckets();
      if (_next < _buckets!.length) {
        final photos = await widget.client.photos(_buckets![_next]);
        if (!mounted) {
          return;
        }
        final ids = _photos.map((p) => p.id).toSet();
        _photos.addAll(photos.where((p) => ids.add(p.id)));
        _next++;
      }
    } catch (error) {
      if (mounted) {
        _error = recoveryReasonCode(error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<Uint8List> _thumbnail(RecoveryServerPhoto photo) {
    if (_images.length >= 64 && !_images.containsKey(photo.id)) {
      final removed = _images.remove(_images.keys.first);
      unawaited(removed?.then<void>((_) {}, onError: (Object _) {}));
    }
    return _images.putIfAbsent(photo.id, () => widget.client.image(photo));
  }

  Future<void> _preview(RecoveryServerPhoto photo) async {
    final bytes = widget.client.image(photo, preview: true);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('sqlite_recovery_server_title'.tr())),
          body: Center(
            child: FutureBuilder<Uint8List>(
              future: bytes,
              builder: (_, snapshot) {
                if (snapshot.hasError) {
                  return Text(recoveryReasonKey(recoveryReasonCode(snapshot.error!)).tr());
                }
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }
                return InteractiveViewer(
                  child: Image.memory(
                    snapshot.data!,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.client.close();
    _images.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('sqlite_recovery_server_title'.tr())),
    body: Column(
      children: [
        Padding(padding: const EdgeInsets.all(16), child: Text('sqlite_recovery_server_notice'.tr())),
        if (widget.client.accountName.isNotEmpty) Text(widget.client.accountName),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: _photos.length,
            itemBuilder: (_, index) {
              final photo = _photos[index];
              return InkWell(
                key: ValueKey('server-photo-${photo.id}'),
                onTap: () => _preview(photo),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List>(
                      future: _thumbnail(photo),
                      builder: (_, snapshot) {
                        if (snapshot.hasError) {
                          return const Icon(Icons.broken_image_outlined);
                        }
                        if (!snapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        return Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                          cacheWidth: 360,
                          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                        );
                      },
                    ),
                    if (!photo.isImage)
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: Icon(Icons.videocam, color: Colors.white),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (!_busy && _photos.isEmpty && _error == null)
          Padding(padding: const EdgeInsets.all(16), child: Text('sqlite_recovery_server_empty'.tr())),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${recoveryReasonKey(_error!).tr()}\n${'sqlite_recovery_code'.tr()}: $_error'),
          ),
        if (!_busy && (_error != null || _next < (_buckets?.length ?? 0)))
          SafeArea(
            top: false,
            child: TextButton(
              onPressed: _more,
              child: Text((_error != null ? 'sqlite_recovery_retry' : 'sqlite_recovery_server_more').tr()),
            ),
          ),
      ],
    ),
  );
}
