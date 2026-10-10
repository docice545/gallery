import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _Service extends Mock implements ApiService {}

void main() {
  AssetApiRepository repository(Future<Response> Function(Request) handler) {
    final client = ApiClient(basePath: 'https://fixture.invalid/api')..client = MockClient(handler);
    addTearDown(client.client.close);
    final service = _Service();
    when(() => service.apiClient).thenReturn(client);
    return AssetApiRepository(service);
  }

  test('bulk uses bounded chunks, preserves per-item acknowledgements and deduplicates selection', () async {
    final batches = <List<String>>[];
    final sut = repository((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['confirmed'], isTrue);
      final ids = (body['ids'] as List).cast<String>();
      batches.add(ids);
      return Response(jsonEncode(ids.map((id) => {'id': id, 'state': 'complete'}).toList()), 201);
    });
    final ids = List.generate(401, (index) => 'fixture-$index');
    final results = await sut.permanentlyDelete([...ids, ids.first]);
    expect(batches.map((batch) => batch.length), [200, 200, 1]);
    expect(results.map((result) => result.id), ids);
    expect(results.every((result) => result.complete), isTrue);
  });

  test(
    'timeout in the second batch keeps the first acknowledgements and never claims unsent work reached server',
    () async {
      var batch = 0;
      final sut = repository((request) async {
        final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
        if (batch++ == 1) {
          throw ClientException('fixture network loss');
        }
        return Response(jsonEncode(ids.map((id) => {'id': id, 'state': 'complete'}).toList()), 200);
      });
      final results = await sut.permanentlyDelete(List.generate(401, (index) => 'fixture-$index'));
      expect(results.take(200).every((result) => result.complete), isTrue);
      expect(results.skip(200).take(200).every((result) => result.state == 'uncertain'), isTrue);
      expect(results.last.code, 'REQUEST_NOT_SENT');
      expect(batch, 2);
    },
  );

  test('definite rejection does not pretend a permanent intent exists', () async {
    final sut = repository((_) async => Response('', 403));
    final result = (await sut.permanentlyDelete(['fixture'])).single;
    expect(result.state, 'blocked');
    expect(result.complete, isFalse);
  });

  test('duplicate or malformed response identities remain uncertain', () async {
    final sut = repository((_) async => Response('[{"id":"a","state":"complete"},{"id":"a","state":"complete"}]', 200));
    expect((await sut.permanentlyDelete(['a', 'b'])).every((result) => result.state == 'uncertain'), isTrue);
    await expectLater(sut.completedDeletions(['a', 'b']), throwsStateError);
  });

  test('mixed receipt states never convert failure into completion', () async {
    final sut = repository(
      (_) async =>
          Response('[{"id":"a","state":"complete"},{"id":"b","state":"failed","code":"ORIGINAL_DELETE_FAILED"}]', 200),
    );
    expect(await sut.completedDeletions(['a', 'b']), {'a'});
  });
}
