import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:openapi/api.dart';

final magicEraserRepositoryProvider = Provider((ref) => MagicEraserRepository(ref.watch(apiServiceProvider)));

final magicEraserEnabledProvider = FutureProvider.family.autoDispose<bool, String>((ref, assetId) async {
  final abort = Completer<void>();
  ref.onDispose(() => abort.complete());
  try {
    return await ref.watch(magicEraserRepositoryProvider).isEnabled(assetId, abortTrigger: abort.future);
  } catch (_) {
    // Optional feature: an offline/older server never disables the crop editor.
    return false;
  }
});

/// Uses the Gallery transport, authentication and local server originals.
/// Only normalized brush instructions go from the phone to the server.
class MagicEraserRepository {
  static const maxPreviewBytes = 8 * 1024 * 1024;
  final ApiService _apiService;

  MagicEraserRepository(this._apiService);

  String _base(String assetId) => '/assets/${Uri.encodeComponent(assetId)}/magic-eraser';
  String _job(String assetId, String jobId) => '${_base(assetId)}/${Uri.encodeComponent(jobId)}';

  Future<http.Response> _request(String path, String method, {Object? body, Future<void>? abortTrigger}) async {
    final abort = _boundedAbort(abortTrigger);
    late final http.Response response;
    try {
      response = await _apiService.apiClient.invokeAPI(
        path,
        method,
        <QueryParam>[],
        body,
        <String, String>{},
        <String, String>{},
        body == null ? null : 'application/json',
        abortTrigger: abort.$1.future,
      );
    } finally {
      abort.$2.cancel();
    }
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, 'Magic eraser request failed');
    }
    return response;
  }

  Future<bool> isEnabled(String assetId, {Future<void>? abortTrigger}) async {
    try {
      final response = await _request('${_base(assetId)}/capabilities', 'GET', abortTrigger: abortTrigger);
      return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['enabled'] == true;
    } on ApiException catch (error) {
      if (error.code == 404) {
        return false;
      }
      rethrow;
    }
  }

  Future<Uint8List> source(String assetId, {Future<void>? abortTrigger}) =>
      _image('${_base(assetId)}/source', abortTrigger: abortTrigger);

  Future<MagicEraserJob> create(String assetId, List<MagicEraserStroke> strokes, {Future<void>? abortTrigger}) async {
    final mask = MagicEraserMask(strokes: strokes);
    if (!mask.hasSelection) {
      throw ArgumentError('Mask has no selection');
    }
    final response = await _request(
      _base(assetId),
      'POST',
      body: {'strokes': strokes.map((stroke) => stroke.toJson()).toList()},
      abortTrigger: abortTrigger,
    );
    return MagicEraserJob.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }

  Future<MagicEraserJob> getJob(String assetId, String jobId, {Future<void>? abortTrigger}) async {
    final response = await _request(_job(assetId, jobId), 'GET', abortTrigger: abortTrigger);
    return MagicEraserJob.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }

  Future<Uint8List> preview(String assetId, String jobId, {Future<void>? abortTrigger}) =>
      _image('${_job(assetId, jobId)}/preview', abortTrigger: abortTrigger);

  Future<void> cancel(String assetId, String jobId) async {
    await _request(_job(assetId, jobId), 'DELETE');
  }

  Future<String> save(String assetId, String jobId) async {
    final response = await _request('${_job(assetId, jobId)}/save', 'POST');
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['id'] as String;
  }

  /// Bound both transfer and decoded preview size. Never fetch the full original.
  Future<Uint8List> _image(String path, {Future<void>? abortTrigger}) async {
    final abort = _boundedAbort(abortTrigger);
    try {
      return await _streamImage(path, abort.$1.future);
    } finally {
      abort.$2.cancel();
    }
  }

  (Completer<void>, Timer) _boundedAbort(Future<void>? external) {
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }

    final timer = Timer(const Duration(seconds: 90), cancel);
    if (external != null) {
      unawaited(external.then((_) => cancel()));
    }
    return (abort, timer);
  }

  Future<Uint8List> _streamImage(String path, Future<void> abortTrigger) async {
    final client = _apiService.apiClient;
    final query = <QueryParam>[];
    final headers = <String, String>{};
    await client.authentication?.applyToParams(query, headers);
    headers.addAll(client.defaultHeaderMap);
    final suffix = query.isEmpty ? '' : '?${query.join('&')}';
    final request = http.AbortableRequest(
      'GET',
      Uri.parse('${client.basePath}$path$suffix'),
      abortTrigger: abortTrigger,
    )..headers.addAll(headers);
    final response = await client.client.send(request);
    if (response.statusCode >= 400) {
      await response.stream.listen((_) {}).cancel();
      throw ApiException(response.statusCode, 'Magic eraser preview failed');
    }
    if (response.contentLength != null && response.contentLength! > maxPreviewBytes) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('Magic eraser preview is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxPreviewBytes) {
        throw const FormatException('Magic eraser preview is too large');
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) {
      throw const FormatException('Empty magic eraser preview');
    }
    return bytes.takeBytes();
  }
}
