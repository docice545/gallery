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
  AssetApiRepository repository(Future<Response> Function(Request) handler, {bool autoPreflight = true}) {
    final client = ApiClient(basePath: 'https://fixture.invalid/api')
      ..client = MockClient((request) async {
        if (autoPreflight && request.url.path.endsWith('/preflight')) {
          final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
          return Response(
            jsonEncode(ids.map((id) => {'id': id, 'scope': 'managed', 'authorized': true}).toList()),
            200,
          );
        }
        return handler(request);
      });
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

  test('checks all 401 IDs before mutation and blocks every scope on missing external consent', () async {
    var mutations = 0;
    final batches = <int>[];
    final sut = repository((request) async {
      if (!request.url.path.endsWith('/preflight')) {
        mutations++;
        return Response('', 500);
      }
      final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
      batches.add(ids.length);
      return Response(
        jsonEncode(
          ids
              .map(
                (id) => {
                  'id': id,
                  'scope': id == 'fixture-400' ? 'external' : 'managed',
                  'authorized': id != 'fixture-400',
                  if (id == 'fixture-400') 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED',
                },
              )
              .toList(),
        ),
        200,
      );
    }, autoPreflight: false);
    final results = await sut.permanentlyDelete(List.generate(401, (i) => 'fixture-$i'));
    expect(batches, [200, 200, 1]);
    expect(mutations, 0);
    expect(results.every((r) => r.state == 'blocked'), isTrue);
    expect(results.first.code, 'DELETION_BATCH_NOT_AUTHORIZED');
    expect(results.last.scope, 'external');
    expect(results.last.code, 'LIBRARY_DELETION_NOT_AUTHORIZED');
  });

  test('stops unsent batches if a scope is revoked after the read-only preflight', () async {
    var batch = 0;
    final sut = repository((request) async {
      final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
      final first = batch++ == 0;
      return Response(
        jsonEncode(
          ids
              .map(
                (id) => {
                  'id': id,
                  'scope': 'managed',
                  'state': first ? 'complete' : 'blocked',
                  if (!first) 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED',
                },
              )
              .toList(),
        ),
        200,
      );
    });
    final results = await sut.permanentlyDelete(List.generate(401, (i) => 'fixture-$i'));
    expect(batch, 2);
    expect(results.take(200).every((r) => r.complete), isTrue);
    expect(results.skip(200).take(200).every((r) => r.state == 'blocked'), isTrue);
    expect(results.last.code, 'REQUEST_NOT_SENT');
  });

  test('offline preflight cannot create an uncertain permanent intent', () async {
    final sut = repository((request) async => throw ClientException('offline'), autoPreflight: false);
    final result = (await sut.permanentlyDelete(['a'])).single;
    expect(result.state, 'blocked');
    expect(result.code, 'REQUEST_NOT_SENT');
  });

  test('invalid preflight identities fail closed without mutation', () async {
    var mutations = 0;
    final sut = repository((request) async {
      if (!request.url.path.endsWith('/preflight')) {
        mutations++;
      }
      return Response('[{"id":"foreign","authorized":true}]', 200);
    }, autoPreflight: false);
    expect((await sut.permanentlyDelete(['a'])).single.code, 'REQUEST_NOT_SENT');
    expect(mutations, 0);
  });

  test('managed policy calls use existing authenticated contracts without owner, roots or external grant', () async {
    final requests = <Request>[];
    final sut = repository((request) async {
      requests.add(request);
      return request.method == 'GET'
          ? Response('{"enabled":false,"prepared":true,"canPrepare":false}', 200)
          : Response('', 204);
    });
    expect((await sut.managedDeletionStatus()).prepared, isTrue);
    await sut.setManagedDeletionConsent(true);
    await sut.setManagedDeletionConsent(false);
    expect(requests[1].url.path, '/api/assets/managed-deletion-consent');
    expect(jsonDecode(requests[1].body), {'enabled': true, 'confirmed': true});
    expect(jsonDecode(requests[2].body), {'enabled': false, 'confirmed': true});
  });

  test('mixed receipt states never convert failure into completion', () async {
    final sut = repository(
      (_) async =>
          Response('[{"id":"a","state":"complete"},{"id":"b","state":"failed","code":"ORIGINAL_DELETE_FAILED"}]', 200),
    );
    expect(await sut.completedDeletions(['a', 'b']), {'a'});
  });
}
