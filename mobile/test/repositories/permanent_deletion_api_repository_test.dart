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
    when(() => service.assetsApi).thenReturn(AssetsApi(client));
    return AssetApiRepository(service);
  }

  group('instant durable acceptance', () {
    test('returns after irreversible admission and never polls physical deletion', () async {
      final requests = <Request>[];
      final sut = repository((request) async {
        requests.add(request);
        expect(request.method, 'POST');
        expect(request.url.path, '/api/assets/permanent-deletion');
        expect(jsonDecode(request.body), {
          'ids': ['still', 'motion'],
          'confirmed': true,
          'acceptOnly': true,
        });
        return Response(
          jsonEncode([
            {'id': 'still', 'state': 'pending', 'accepted': true, 'batchId': 'durable-batch'},
            {'id': 'motion', 'state': 'failed', 'accepted': true, 'code': 'RETRYABLE_FILE_IO'},
          ]),
          201,
        );
      });
      final results = await sut.acceptPermanentDeletion(['still', 'motion', 'still']);
      expect(requests, hasLength(1));
      expect(results.map((result) => result.id), ['still', 'motion']);
      expect(results.every((result) => result.accepted), isTrue);
      expect(results.every((result) => !result.complete), isTrue);
      expect(results.first.batchId, 'durable-batch');
      expect(results.last.state, 'failed');
    });

    test('legacy queued response without acceptance is not an irreversible receipt', () async {
      var requests = 0;
      final sut = repository((request) async {
        requests++;
        expect(request.url.path, '/api/assets/permanent-deletion');
        return Response('[{"id":"still","state":"pending","batchId":"legacy-queued"}]', 201);
      });
      final result = (await sut.acceptPermanentDeletion(['still'])).single;
      expect(result.accepted, isFalse);
      expect(result.complete, isFalse);
      expect(requests, 1, reason: 'do not poll a legacy physical-deletion batch');
    });

    test('physical completion is sufficient evidence even with an older response contract', () async {
      final sut = repository((_) async => Response('[{"id":"still","state":"complete"}]', 200));
      final result = (await sut.acceptPermanentDeletion(['still'])).single;
      expect(result.accepted, isTrue);
      expect(result.complete, isTrue);
    });

    test('lost response is resolved from durable receipts without waiting for file removal', () async {
      final paths = <String>[];
      final sut = repository((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/permanent-deletion')) {
          throw ClientException('response lost after server commit');
        }
        expect(request.url.path, '/api/assets/deletion-status');
        expect(jsonDecode(request.body)['ids'], ['still']);
        return Response('[{"id":"still","state":"pending","accepted":true}]', 200);
      });
      final result = (await sut.acceptPermanentDeletion(['still'])).single;
      expect(result.accepted, isTrue);
      expect(result.complete, isFalse);
      expect(paths, ['/api/assets/permanent-deletion', '/api/assets/deletion-status']);
    });

    for (final receipt in [
      '[{"id":"still","state":"blocked","code":"NO_DELETION_INTENT"}]',
      '[{"id":"still","state":"pending","batchId":"legacy-queued"}]',
    ]) {
      test('an inconclusive lost-response status remains uncertain: $receipt', () async {
        final sut = repository((request) async {
          if (request.url.path.endsWith('/permanent-deletion')) {
            throw ClientException('network loss');
          }
          return Response(receipt, 200);
        });
        final result = (await sut.acceptPermanentDeletion(['still'])).single;
        expect(result.accepted, isFalse);
        expect(result.state, 'uncertain');
        expect(result.code, 'REQUEST_OUTCOME_UNKNOWN');
      });
    }

    for (final body in [
      '[{"id":"foreign","state":"pending","accepted":true}]',
      '[{"id":"still","state":"pending","accepted":"yes"}]',
      '[{"id":"still","state":"blocked","accepted":true}]',
      '[{"id":"still","state":"pending","accepted":true},{"id":"still","state":"pending","accepted":true}]',
    ]) {
      test('rejects malformed acceptance identities or proof without falsely hiding any asset: $body', () async {
        final sut = repository((_) async => Response(body, 200));
        final result = (await sut.acceptPermanentDeletion(['still'])).single;
        expect(result.accepted, isFalse);
        expect(result.state, 'uncertain');
      });
    }

    test('definite rejection stays ordinary Trash and performs no status polling', () async {
      var requests = 0;
      final sut = repository((request) async {
        requests++;
        expect(request.url.path, '/api/assets/permanent-deletion');
        return Response('', 403);
      });
      final result = (await sut.acceptPermanentDeletion(['still'])).single;
      expect(result.accepted, isFalse);
      expect(result.state, 'blocked');
      expect(result.code, 'REQUEST_REJECTED');
      expect(requests, 1);
    });

    test('read-only offline preflight never admits or sends deletion', () async {
      final paths = <String>[];
      final sut = repository((request) async {
        paths.add(request.url.path);
        throw ClientException('offline');
      }, autoPreflight: false);
      final result = (await sut.acceptPermanentDeletion(['still'])).single;
      expect(result.accepted, isFalse);
      expect(result.code, 'REQUEST_NOT_SENT');
      expect(paths, ['/api/assets/permanent-deletion/preflight']);
    });

    test('empty selection performs no network request', () async {
      var requests = 0;
      final sut = repository((_) async {
        requests++;
        return Response('', 500);
      });
      expect(await sut.acceptPermanentDeletion([]), isEmpty);
      expect(requests, 0);
    });

    test('bounded chunks preserve earlier receipts and leave unsent work untouched after network loss', () async {
      final sizes = <int>[];
      final sut = repository((request) async {
        final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
        if (request.url.path.endsWith('/deletion-status')) {
          throw ClientException('status unavailable');
        }
        sizes.add(ids.length);
        if (sizes.length == 2) {
          throw ClientException('lost next batch');
        }
        return Response(jsonEncode(ids.map((id) => {'id': id, 'state': 'pending', 'accepted': true}).toList()), 201);
      });
      final results = await sut.acceptPermanentDeletion(List.generate(10001, (index) => 'id-$index'));
      expect(sizes, [5000, 5000]);
      expect(results.take(5000).every((result) => result.accepted), isTrue);
      expect(results.skip(5000).take(5000).every((result) => result.state == 'uncertain'), isTrue);
      expect(results.last.accepted, isFalse);
      expect(results.last.code, 'REQUEST_NOT_SENT');
    });

    test('scope revocation after preflight stops all remaining admission requests', () async {
      var posts = 0;
      final sut = repository((request) async {
        posts++;
        final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
        return Response(
          jsonEncode(
            ids
                .map(
                  (id) => {'id': id, 'state': 'blocked', 'accepted': false, 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'},
                )
                .toList(),
          ),
          201,
        );
      });
      final results = await sut.acceptPermanentDeletion(List.generate(5001, (index) => 'id-$index'));
      expect(posts, 1);
      expect(results.every((result) => !result.accepted), isTrue);
      expect(results.last.code, 'REQUEST_NOT_SENT');
    });

    test('per-ID receipt lookup preserves explicit admission separately from physical completion', () async {
      final sut = repository((request) async {
        expect(request.url.path, '/api/assets/still/deletion-status');
        return Response('{"id":"still","state":"failed","accepted":true,"code":"ORIGINAL_DELETE_FAILED"}', 200);
      });
      final result = await sut.deletionStatus('still');
      expect(result.accepted, isTrue);
      expect(result.complete, isFalse);
      expect(result.code, 'ORIGINAL_DELETE_FAILED');
    });
  });

  test('bulk uses bounded chunks, preserves per-item acknowledgements and deduplicates selection', () async {
    final batches = <List<String>>[];
    final sut = repository((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['confirmed'], isTrue);
      final ids = (body['ids'] as List).cast<String>();
      batches.add(ids);
      return Response(jsonEncode(ids.map((id) => {'id': id, 'state': 'complete'}).toList()), 201);
    });
    final ids = List.generate(5001, (index) => 'fixture-$index');
    final results = await sut.permanentlyDelete([...ids, ids.first]);
    expect(batches.map((batch) => batch.length), [5000, 1]);
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
      final results = await sut.permanentlyDelete(List.generate(10001, (index) => 'fixture-$index'));
      expect(results.take(5000).every((result) => result.complete), isTrue);
      expect(results.skip(5000).take(1).every((result) => result.state == 'uncertain'), isTrue);
      expect(results.last.code, 'REQUEST_NOT_SENT');
      expect(batch, 2);
    },
  );

  test('polls a queued batch and reconciles its final per-item statuses', () async {
    var statusPolls = 0;
    final statuses = <String>[];
    final ids = List.generate(5000, (index) => 'fixture-$index');
    final sut = repository((request) async {
      if (request.url.path.endsWith('/permanent-deletion/status')) {
        statusPolls++;
        return Response(
          jsonEncode({
            'id': 'batch-1',
            'state': statusPolls == 1 ? 'active' : 'complete',
            'total': ids.length,
            'processed': statusPolls == 1 ? 0 : ids.length,
            'complete': statusPolls == 1 ? 0 : ids.length,
            'failed': 0,
            'pending': statusPolls == 1 ? ids.length : 0,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/deletion-status')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final requested = (body['ids'] as List).cast<String>();
        return Response(jsonEncode(requested.map((id) => {'id': id, 'state': 'complete'}).toList()), 200);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final requested = (body['ids'] as List).cast<String>();
      return Response(
        jsonEncode(requested.map((id) => {'id': id, 'state': 'pending', 'batchId': 'batch-1'}).toList()),
        201,
      );
    });

    final results = await sut.permanentlyDelete(ids, onBatchStatus: (status) => statuses.add(status.state));

    expect(statusPolls, 2);
    expect(statuses, ['active', 'complete']);
    expect(results.length, ids.length);
    expect(results.every((result) => result.complete), isTrue);
  });

  test('stops unsent batches after a cancelled queued batch', () async {
    var deletionRequests = 0;
    final ids = List.generate(5001, (index) => 'fixture-$index');
    final sut = repository((request) async {
      if (request.url.path.endsWith('/permanent-deletion/status')) {
        return Response(
          jsonEncode({
            'id': 'batch-1',
            'state': 'cancelled',
            'total': 5000,
            'processed': 1,
            'complete': 1,
            'failed': 0,
            'pending': 4999,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/deletion-status')) {
        final requested = (jsonDecode(request.body)['ids'] as List).cast<String>();
        return Response(jsonEncode(requested.map((id) => {'id': id, 'state': 'complete'}).toList()), 200);
      }
      deletionRequests++;
      final requested = (jsonDecode(request.body)['ids'] as List).cast<String>();
      return Response(
        jsonEncode(requested.map((id) => {'id': id, 'state': 'pending', 'batchId': 'batch-1'}).toList()),
        201,
      );
    });

    final results = await sut.permanentlyDelete(ids);

    expect(deletionRequests, 1);
    expect(results.length, ids.length);
    expect(results.take(5000).every((result) => result.complete), isTrue);
    expect(results.last.state, 'blocked');
    expect(results.last.code, 'REQUEST_NOT_SENT');
  });

  test('cancels an explicitly identified batch and preserves server status', () async {
    late Request request;
    final sut = repository((value) async {
      request = value;
      return Response(
        jsonEncode({
          'id': 'batch-1',
          'state': 'active',
          'total': 5000,
          'processed': 200,
          'complete': 199,
          'failed': 1,
          'pending': 4800,
          'cancelRequested': true,
        }),
        200,
      );
    });

    final status = await sut.cancelDeletionBatch('batch-1');

    expect(request.method, 'POST');
    expect(request.url.path, '/api/assets/permanent-deletion/batch-1/cancel');
    expect(status.id, 'batch-1');
    expect(status.state, 'active');
    expect(status.cancelled, isTrue);
    expect(status.processed, 200);
    expect(status.pending, 4800);
  });

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

  test('checks all 401 IDs and deletes only authorized managed assets', () async {
    final deletionBatches = <List<String>>[];
    final batches = <int>[];
    final sut = repository((request) async {
      if (!request.url.path.endsWith('/preflight')) {
        final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
        deletionBatches.add(ids);
        return Response(jsonEncode(ids.map((id) => {'id': id, 'state': 'complete'}).toList()), 200);
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
    expect(deletionBatches.length, 1);
    expect(deletionBatches.single.length, 400);
    expect(deletionBatches.single.contains('fixture-400'), isFalse);
    expect(results.length, 401);
    expect(results.where((r) => r.complete).length, 400);
    final blocked = results.singleWhere((r) => r.id == 'fixture-400');
    expect(blocked.state, 'blocked');
    expect(blocked.scope, 'external');
    expect(blocked.code, 'LIBRARY_DELETION_NOT_AUTHORIZED');
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
    final results = await sut.permanentlyDelete(List.generate(10001, (i) => 'fixture-$i'));
    expect(batch, 2);
    expect(results.take(5000).every((r) => r.complete), isTrue);
    expect(results.skip(5000).take(1).every((r) => r.state == 'blocked'), isTrue);
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

  test('signed recovery preparation sends only the installed evidence digest and roots attestation', () async {
    late Request request;
    final sut = repository((value) async {
      request = value;
      return Response('', 204);
    });
    final digest = List.filled(64, 'a').join();
    await sut.prepareManagedDeletion(digest);
    expect(request.url.path, '/api/assets/managed-deletion-preparation');
    expect(jsonDecode(request.body), {'recoveryProof': digest, 'verifiedExclusiveRoots': true});
  });

  test(
    'external status and owner consent use a separate exact library scope without supplying owner or roots',
    () async {
      final requests = <Request>[];
      const scope = 'a55e67c9-e435-4f04-ab10-d37c8c33800f';
      final sut = repository((request) async {
        requests.add(request);
        return Response(
          request.method == 'GET' ? '{"enabled":false,"prepared":true,"canPrepare":false}' : '',
          request.method == 'GET' ? 200 : 204,
        );
      });
      expect((await sut.libraryDeletionStatus(scope)).prepared, isTrue);
      await sut.setLibraryDeletionConsent(scope, true);
      await sut.setLibraryDeletionConsent(scope, false);
      expect(requests[0].url.path, '/api/assets/library-deletion-policy/$scope');
      for (final request in requests.skip(1)) {
        expect(request.url.path, '/api/assets/library-deletion-consent/$scope');
      }
      expect(jsonDecode(requests[1].body), {'enabled': true, 'confirmed': true});
      expect(jsonDecode(requests[2].body), {'enabled': false, 'confirmed': true});
    },
  );

  test('external preparation sends only the installed scope-bound evidence identifier', () async {
    late Request request;
    final sut = repository((value) async {
      request = value;
      return Response('', 204);
    });
    final digest = List.filled(64, 'b').join();
    await sut.prepareLibraryDeletion('own-library', digest);
    expect(request.url.path, '/api/assets/library-deletion-preparation/own-library');
    expect(jsonDecode(request.body), {'recoveryProof': digest, 'verifiedExclusiveRoots': true});
  });

  test('library list includes empty libraries so owners can revoke without any remaining Trash item', () async {
    final sut = repository((request) async {
      expect(request.url.path, '/api/assets/library-deletion-policy');
      return Response('[{"scope":"own-library","name":"My library","count":0,"authorized":true}]', 200);
    });
    expect(await sut.libraryDeletionScopes(), [
      {'scope': 'own-library', 'name': 'My library', 'count': 0, 'authorized': true},
    ]);
  });

  test('preserves machine-readable signed recovery rejections for localized client feedback', () async {
    const body = '{"message":"DELETION_RECOVERY_EXPIRED","error":"Conflict","statusCode":409}';
    final sut = repository((_) async => Response(body, 409));
    await expectLater(
      sut.prepareManagedDeletion(List.filled(64, 'a').join()),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 409)
            .having((error) => error.message, 'message', body),
      ),
    );
  });

  test('mixed receipt states never convert failure into completion', () async {
    final sut = repository(
      (_) async =>
          Response('[{"id":"a","state":"complete"},{"id":"b","state":"failed","code":"ORIGINAL_DELETE_FAILED"}]', 200),
    );
    expect(await sut.completedDeletions(['a', 'b']), {'a'});
  });
}
