import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _ApiService extends Mock implements ApiService {}

class _AssetsApi extends Mock implements AssetsApi {}

class _TrashApi extends Mock implements TrashApi {}

void main() {
  late _AssetsApi assets;
  late _TrashApi trash;
  late AssetApiRepository repository;

  setUpAll(() {
    registerFallbackValue(BulkIdsDto(ids: []));
    registerFallbackValue(AssetBulkDeleteDto(ids: []));
  });
  setUp(() {
    final service = _ApiService();
    assets = _AssetsApi();
    trash = _TrashApi();
    when(() => service.assetsApi).thenReturn(assets);
    when(() => service.trashApi).thenReturn(trash);
    repository = AssetApiRepository(service);
  });

  for (final bulk in [false, true]) {
    test('${bulk ? 'bulk' : 'single'} Restore reaches the server before a subsequent Trash', () async {
      final started = Completer<void>();
      final restoreResponse = Completer<TrashResponseDto?>();
      final calls = <String>[];
      if (bulk) {
        when(() => trash.restoreTrash()).thenAnswer((_) {
          calls.add('restore-all');
          started.complete();
          return restoreResponse.future;
        });
      } else {
        when(() => trash.restoreAssets(any())).thenAnswer((_) {
          calls.add('restore');
          started.complete();
          return restoreResponse.future;
        });
      }
      when(() => assets.deleteAssets(any())).thenAnswer((invocation) async {
        final dto = invocation.positionalArguments.single as AssetBulkDeleteDto;
        expect(dto.force.orElse(true), isFalse); // Ordinary Trash stays distinct from permanent Delete.
        calls.add('trash');
      });
      final restoring = bulk ? repository.restoreAllTrash() : repository.restoreTrash(['asset']);
      await started.future;
      final trashing = repository.delete(['asset'], false);
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => assets.deleteAssets(any()));
      restoreResponse.complete(TrashResponseDto(count: 1));
      await restoring;
      await trashing;
      expect(calls, [bulk ? 'restore-all' : 'restore', 'trash']);
    });
  }

  test('a rejected mutation does not poison subsequent Trash requests', () async {
    when(() => trash.restoreAssets(any())).thenThrow(ApiException(403, 'Forbidden'));
    when(() => assets.deleteAssets(any())).thenAnswer((_) async {});
    await expectLater(repository.restoreTrash(['asset']), throwsA(isA<ApiException>()));
    await repository.delete(['asset'], false);
    verify(() => assets.deleteAssets(any())).called(1);
  });

  test('only definite HTTP rejection triggers rollback; transport and server outcomes remain uncertain', () {
    for (final status in [400, 401, 403, 404, 405, 409, 413, 415, 422, 429]) {
      expect(AssetApiRepository.isDefiniteTrashRejection(ApiException(status, 'rejected')), isTrue);
    }
    for (final error in [
      ApiException(0, 'offline'),
      ApiException(408, 'timeout'),
      ApiException(500, 'server error'),
      ApiException.withInner(403, 'transport', Exception('network'), StackTrace.current),
      TimeoutException('timeout'),
    ]) {
      expect(AssetApiRepository.isDefiniteTrashRejection(error), isFalse);
    }
  });
}
