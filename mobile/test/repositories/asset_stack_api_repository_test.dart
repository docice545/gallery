import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _ApiService extends Mock implements ApiService {}

class _StacksApi extends Mock implements StacksApi {}

void main() {
  test('member removal uses generated assetId/stackId parameter order and never deletes an asset', () async {
    final service = _ApiService();
    final stacks = _StacksApi();
    when(() => service.stacksApi).thenReturn(stacks);
    when(() => stacks.removeAssetFromStack('asset-id', 'stack-id')).thenAnswer((_) async {});
    final repository = AssetApiRepository(service);
    await repository.removeFromStack('stack-id', 'asset-id');
    verify(() => stacks.removeAssetFromStack('asset-id', 'stack-id')).called(1);
    verifyNever(() => service.assetsApi);
  });
}
