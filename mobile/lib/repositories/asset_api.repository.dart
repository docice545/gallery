import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart' hide AssetEditAction;
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/repositories/api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:openapi/api.dart' as api show AssetVisibility;
import 'package:openapi/api.dart' hide AssetVisibility;

final assetApiRepositoryProvider = Provider((ref) => AssetApiRepository(ref.watch(apiServiceProvider)));

class AssetApiRepository extends ApiRepository {
  final ApiService _apiService;
  Future<void> _trashRequestTail = Future<void>.value();

  AssetApiRepository(this._apiService);

  AssetsApi get _api => _apiService.assetsApi;
  StacksApi get _stacksApi => _apiService.stacksApi;
  TrashApi get _trashApi => _apiService.trashApi;

  // Order mutation requests independently of optimistic UI updates. Otherwise
  // a delayed Restore can reach the server after a subsequent Trash.
  Future<T> _serializeTrashRequest<T>(Future<T> Function() request) {
    final result = _trashRequestTail.then((_) => request());
    _trashRequestTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static bool isDefiniteTrashRejection(Object error) =>
      error is ApiException &&
      error.innerException == null &&
      const {400, 401, 403, 404, 405, 409, 413, 415, 422, 429}.contains(error.code);

  Future<void> delete(List<String> ids, bool force) =>
      _serializeTrashRequest(() => _api.deleteAssets(AssetBulkDeleteDto(ids: ids, force: Optional.present(force))));

  Future<ManagedDeletionStatus> managedDeletionStatus() async {
    final value = await _managedDeletionRequest('/assets/managed-deletion-policy', 'GET');
    return ManagedDeletionStatus(
      enabled: value['enabled'] as bool,
      prepared: value['prepared'] as bool,
      canPrepare: value['canPrepare'] as bool,
    );
  }

  Future<void> setManagedDeletionConsent(bool enabled) async {
    await _managedDeletionRequest('/assets/managed-deletion-consent', 'PUT', {'enabled': enabled, 'confirmed': true});
  }

  Future<void> prepareManagedDeletion(String recoveryProof) async {
    await _managedDeletionRequest('/assets/managed-deletion-preparation', 'PUT', {
      'recoveryProof': recoveryProof,
      'verifiedExclusiveRoots': true,
    });
  }

  Future<Map<String, dynamic>> _managedDeletionRequest(String path, String method, [Object? body]) async {
    final response = await _apiService.apiClient.invokeAPI(
      path,
      method,
      <QueryParam>[],
      body,
      <String, String>{},
      <String, String>{},
      body == null ? null : 'application/json',
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw ApiException(response.statusCode, 'Managed deletion authorization unavailable');
    }
    return response.statusCode == 204 ? {} : jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<PermanentDeletionResult>> _preflightPermanentDeletion(List<String> ids) async {
    final results = <PermanentDeletionResult>[];
    for (var start = 0; start < ids.length; start += 200) {
      final batch = ids.skip(start).take(200).toSet();
      final response = await _apiService.apiClient.invokeAPI(
        '/assets/permanent-deletion/preflight',
        'POST',
        <QueryParam>[],
        {'ids': batch.toList()},
        <String, String>{},
        <String, String>{},
        'application/json',
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ApiException(response.statusCode, 'Permanent deletion preflight unavailable');
      }
      final values = (jsonDecode(utf8.decode(response.bodyBytes)) as List).cast<Map<String, dynamic>>();
      if (values.length != batch.length ||
          values.map((v) => v['id']).toSet().length != batch.length ||
          values.any((v) => !batch.contains(v['id']) || v['authorized'] is! bool)) {
        throw StateError('Invalid deletion preflight');
      }
      results.addAll(
        values.map(
          (v) => PermanentDeletionResult(
            id: v['id'] as String,
            state: v['authorized'] == true ? 'authorized' : 'blocked',
            scope: v['scope'] as String?,
            code: v['code'] as String?,
          ),
        ),
      );
    }
    return results;
  }

  Future<List<PermanentDeletionResult>> permanentlyDelete(List<String> ids) => _serializeTrashRequest(() async {
    final requested = ids.toSet().toList();
    final acknowledged = <PermanentDeletionResult>[];
    // Check the ENTIRE selection before any mutation, including selections larger than 200.
    // A failed read cannot mean a permanent intent was created.
    List<PermanentDeletionResult> preflight;
    try {
      preflight = await _preflightPermanentDeletion(requested);
    } catch (_) {
      return requested
          .map((id) => PermanentDeletionResult(id: id, state: 'blocked', code: 'REQUEST_NOT_SENT'))
          .toList();
    }
    if (preflight.any((result) => result.state != 'authorized')) {
      return preflight
          .map(
            (result) => PermanentDeletionResult(
              id: result.id,
              state: 'blocked',
              scope: result.scope,
              code: result.code ?? 'DELETION_BATCH_NOT_AUTHORIZED',
            ),
          )
          .toList();
    }
    for (var start = 0; start < requested.length; start += 200) {
      final unique = requested.skip(start).take(200).toSet();
      try {
        final response = await _apiService.apiClient.invokeAPI(
          '/assets/permanent-deletion',
          'POST',
          <QueryParam>[],
          {'ids': unique.toList(), 'confirmed': true},
          <String, String>{},
          <String, String>{},
          'application/json',
        );
        if (response.statusCode != 201 && response.statusCode != 200) {
          throw ApiException(response.statusCode, 'Permanent deletion was not acknowledged');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        final results = decoded.map((item) {
          final value = item as Map<String, dynamic>;
          final id = value['id'] as String;
          final state = value['state'] as String;
          if (!unique.contains(id) || !const {'complete', 'pending', 'failed', 'blocked'}.contains(state)) {
            throw StateError('Invalid deletion acknowledgement');
          }
          return PermanentDeletionResult(
            id: id,
            state: state,
            scope: value['scope'] as String?,
            code: value['code'] as String?,
          );
        }).toList();
        if (results.length != unique.length || results.map((item) => item.id).toSet().length != unique.length) {
          throw StateError('Incomplete deletion acknowledgement');
        }
        acknowledged.addAll(results);
        if (results.any(
          (result) => const {'LIBRARY_DELETION_NOT_AUTHORIZED', 'DELETION_BATCH_NOT_AUTHORIZED'}.contains(result.code),
        )) {
          acknowledged.addAll(
            requested
                .skip(start + 200)
                .map((id) => PermanentDeletionResult(id: id, state: 'blocked', code: 'REQUEST_NOT_SENT')),
          );
          break;
        }
      } catch (error) {
        final definite = isDefiniteTrashRejection(error);
        acknowledged.addAll(
          unique.map(
            (id) => PermanentDeletionResult(
              id: id,
              state: definite ? 'blocked' : 'uncertain',
              code: definite ? 'REQUEST_REJECTED' : 'REQUEST_OUTCOME_UNKNOWN',
            ),
          ),
        );
        acknowledged.addAll(
          requested
              .skip(start + 200)
              .map((id) => PermanentDeletionResult(id: id, state: 'blocked', code: 'REQUEST_NOT_SENT')),
        );
        break;
      }
    }
    return acknowledged;
  });

  Future<Set<String>> completedDeletions(List<String> ids) async {
    final response = await _apiService.apiClient.invokeAPI(
      '/assets/deletion-status',
      'POST',
      <QueryParam>[],
      {'ids': ids},
      <String, String>{},
      <String, String>{},
      'application/json',
    );
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, 'Deletion statuses unavailable');
    }
    final results = (jsonDecode(utf8.decode(response.bodyBytes)) as List).cast<Map<String, dynamic>>();
    if (results.length != ids.toSet().length ||
        results.map((item) => item['id']).toSet().length != ids.toSet().length ||
        results.any(
          (item) =>
              !ids.contains(item['id']) || !const {'complete', 'pending', 'failed', 'blocked'}.contains(item['state']),
        )) {
      throw StateError('Invalid deletion statuses');
    }
    return {
      for (final item in results)
        if (item['state'] == 'complete') item['id'] as String,
    };
  }

  Future<PermanentDeletionResult> deletionStatus(String id, {Future<void>? abortTrigger}) async {
    final response = await _apiService.apiClient.invokeAPI(
      '/assets/$id/deletion-status',
      'GET',
      <QueryParam>[],
      null,
      <String, String>{},
      <String, String>{},
      null,
      abortTrigger: abortTrigger,
    );
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, 'Deletion status unavailable');
    }
    final value = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (value['id'] != id || !const {'complete', 'pending', 'failed', 'blocked'}.contains(value['state'])) {
      throw StateError('Invalid deletion status');
    }
    return PermanentDeletionResult(id: id, state: value['state'] as String, code: value['code'] as String?);
  }

  Future<void> restoreTrash(List<String> ids) => _serializeTrashRequest(() async {
    final response = await _trashApi.restoreAssets(BulkIdsDto(ids: ids));
    if (response == null || response.count != ids.toSet().length) {
      // The response identifies no per-item outcome. Do not acknowledge every
      // optimistic Restore when expiry/permanent deletion raced this batch.
      // The existing durable reconciliation will inspect the individual IDs.
      throw StateError('Restore outcome requires reconciliation');
    }
  });

  Future<int> emptyTrash() async {
    final response = await _trashApi.emptyTrash();
    return response?.count ?? 0;
  }

  Future<int> restoreAllTrash() => _serializeTrashRequest(() async {
    final response = await _trashApi.restoreTrash();
    return response?.count ?? 0;
  });

  Future<StackResponse> stack(List<String> ids) async {
    final responseDto = await checkNull(_stacksApi.createStack(StackCreateDto(assetIds: ids)));

    return responseDto.toStack();
  }

  Future<void> unStack(List<String> ids) async {
    await _stacksApi.deleteStacks(BulkIdsDto(ids: ids));
  }

  Future<List<({StackResponse stack, String name})>> getStacks() async {
    final stacks = await checkNull(_stacksApi.searchStacks());
    return stacks
        .where((stack) => stack.assets.any((asset) => asset.id == stack.primaryAssetId))
        .map(
          (stack) => (
            stack: stack.toStack(),
            name: stack.assets.firstWhere((asset) => asset.id == stack.primaryAssetId).originalFileName,
          ),
        )
        .toList();
  }

  Future<StackResponse> getStack(String id) async => (await checkNull(_stacksApi.getStack(id))).toStack();

  Future<StackResponse> setStackPrimary(String id, String assetId) async => (await checkNull(
    _stacksApi.updateStack(id, StackUpdateDto(primaryAssetId: Optional.present(assetId))),
  )).toStack();

  Future<void> removeFromStack(String id, String assetId) => _stacksApi.removeAssetFromStack(assetId, id);

  api.AssetVisibility _mapVisibility(AssetVisibility visibility) => switch (visibility) {
    AssetVisibility.timeline => api.AssetVisibility.timeline,
    AssetVisibility.hidden => api.AssetVisibility.hidden,
    AssetVisibility.locked => api.AssetVisibility.locked,
    AssetVisibility.archive => api.AssetVisibility.archive,
  };

  Future<String?> getAssetMIMEType(String assetId) async {
    final response = await checkNull(_api.getAssetInfo(assetId));

    // we need to get the MIME of the thumbnail once that gets added to the API
    return response.originalMimeType.orElse(null);
  }

  Future<void> updateDescription(String assetId, String description) {
    return _api.updateAsset(assetId, UpdateAssetDto(description: Optional.present(description)));
  }

  Future<void> updateRating(String assetId, int? rating) {
    return _api.updateAsset(assetId, UpdateAssetDto(rating: Optional.present(rating)));
  }

  Future<AssetEditsResponseDto?> editAsset(String assetId, List<AssetEdit> edits) {
    return _api.editAsset(assetId, AssetEditsCreateDto(edits: edits.map((e) => e.toApi()).toList()));
  }

  Future<void> removeEdits(String assetId) async {
    await _api.removeAssetEdits(assetId);
  }

  Future<void> update(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<String> dateTimeOriginal = const .none(),
    Option<LatLng> location = const .none(),
  }) {
    return _api.updateAssets(
      AssetBulkUpdateDto(
        ids: remoteIds,
        isFavorite: isFavorite.toOptional(),
        visibility: visibility.map(_mapVisibility).toOptional(),
        dateTimeOriginal: dateTimeOriginal.toOptional(),
        latitude: location.map((loc) => loc.latitude).toOptional(),
        longitude: location.map((loc) => loc.longitude).toOptional(),
      ),
    );
  }
}

extension on StackResponseDto {
  StackResponse toStack() {
    return StackResponse(id: id, primaryAssetId: primaryAssetId, assetIds: assets.map((asset) => asset.id).toList());
  }
}

extension on AssetEdit {
  AssetEditActionItemDto toApi() {
    return switch (this) {
      CropEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.crop,
        parameters: parameters.toJson(),
      ),
      RotateEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.rotate,
        parameters: parameters.toJson(),
      ),
      MirrorEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.mirror,
        parameters: parameters.toJson(),
      ),
    };
  }
}
