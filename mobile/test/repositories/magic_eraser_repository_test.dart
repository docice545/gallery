import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

class _MockApiService extends Mock implements ApiService {}

/// Preserve the real API client's URL, authentication and JSON serialization;
/// stub only the HTTP transport, including streaming previews.
class _StubClient extends http.BaseClient {
  _StubClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
}

void main() {
  late api.ApiClient apiClient;
  late _MockApiService service;
  late MagicEraserRepository repository;
  late List<http.BaseRequest> requests;

  const assetId = 'server-only-photo';
  const jobId = 'eraser-job';
  const basePath = '/api/assets/$assetId/magic-eraser';
  const jpeg = [0xff, 0xd8, 0xff, 0xd9];

  http.StreamedResponse response(List<int> bytes, {int status = 200, String contentType = 'application/json'}) =>
      http.StreamedResponse(
        Stream.value(bytes),
        status,
        contentLength: bytes.length,
        headers: {'content-type': contentType},
      );

  http.StreamedResponse jsonResponse(Object body, {int status = 200}) =>
      response(utf8.encode(jsonEncode(body)), status: status);

  void stub(FutureOr<http.StreamedResponse> Function(http.BaseRequest request) handler) {
    apiClient.client = _StubClient((request) async {
      requests.add(request);
      return handler(request);
    });
  }

  MagicEraserStroke brush({bool erase = false}) =>
      MagicEraserStroke(points: [const Offset(0.25, 0.5), const Offset(0.75, 0.5)], radius: 0.05, erase: erase);

  Map<String, dynamic> jsonBody(http.BaseRequest request) =>
      jsonDecode((request as http.Request).body) as Map<String, dynamic>;

  setUp(() {
    requests = [];
    apiClient = api.ApiClient(basePath: 'https://gallery.test/api');
    apiClient.addDefaultHeader('Authorization', 'Bearer test-session');
    apiClient.addDefaultHeader('x-custom-header', 'proxy-header');
    service = _MockApiService();
    when(() => service.apiClient).thenReturn(apiClient);
    repository = MagicEraserRepository(service);
  });

  group('capability compatibility', () {
    test('an older server hides the feature without breaking the existing editor', () async {
      stub((_) => jsonResponse({'message': 'Not found'}, status: 404));

      expect(await repository.isEnabled(assetId), isFalse);
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '$basePath/capabilities');
    });

    test('honors a disabled server instead of creating an inpainting job', () async {
      stub((_) => jsonResponse({'enabled': false}));

      expect(await repository.isEnabled(assetId), isFalse);
      expect(requests, hasLength(1));
    });

    test('reads the enabled capability and sends existing session and proxy headers', () async {
      stub((_) => jsonResponse({'enabled': true}));

      expect(await repository.isEnabled(assetId), isTrue);
      expect(requests.single.headers['Authorization'], 'Bearer test-session');
      expect(requests.single.headers['x-custom-header'], 'proxy-header');
      expect(requests.single.url.host, 'gallery.test');
    });

    test('does not disguise an authorization or server error as an old server', () async {
      for (final status in [401, 403, 500]) {
        stub((_) => jsonResponse({'message': 'Request failed'}, status: status));

        await expectLater(
          repository.isEnabled(assetId),
          throwsA(isA<api.ApiException>().having((error) => error.code, 'code', status)),
        );
      }
    });
  });

  group('mask-only processing', () {
    test('does not submit an empty mask or an eraser-only history to the processing queue', () async {
      stub((_) => jsonResponse({'id': jobId, 'status': 'queued'}));

      await expectLater(repository.create(assetId, []), throwsArgumentError);
      await expectLater(repository.create(assetId, [brush(erase: true)]), throwsArgumentError);
      expect(requests, isEmpty);
    });

    test('a server-only asset submits mask instructions without downloading or uploading the original', () async {
      stub((_) => jsonResponse({'id': jobId, 'status': 'queued'}, status: 201));
      final strokes = [brush(), brush(erase: true)];

      final job = await repository.create(assetId, strokes);

      expect(job.id, jobId);
      expect(job.status, MagicEraserStatus.queued);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, basePath);
      expect(request.headers['Content-Type'], contains('application/json'));
      expect(jsonBody(request), {'strokes': strokes.map((stroke) => stroke.toJson()).toList()});
      expect((request as http.Request).bodyBytes.length, lessThan(1024));
      expect(jsonBody(request).keys, ['strokes']);
    });

    test('reads processing, failure and ready status without saving a copy automatically', () async {
      for (final status in ['processing', 'failed', 'ready']) {
        stub(
          (_) =>
              jsonResponse({'id': jobId, 'status': status, if (status == 'failed') 'errorCode': 'inpainting_failed'}),
        );

        final job = await repository.getJob(assetId, jobId);

        expect(job.status.name, status);
        expect(job.assetId, isNull);
        expect(requests.last.method, 'GET');
        expect(requests.last.url.path, '$basePath/$jobId');
        if (status == 'failed') {
          expect(job.errorCode, 'inpainting_failed');
        }
      }
      expect(requests.every((request) => request.method == 'GET'), isTrue);
    });

    test('reports a full processing queue without claiming that the job started', () async {
      stub((_) => jsonResponse({'message': 'Queue is full'}, status: 429));

      await expectLater(repository.create(assetId, [brush()]), throwsA(isA<api.ApiException>()));
      expect(requests, hasLength(1));
    });

    test('network failure propagates and creates no local or second copy', () async {
      stub((_) => throw http.ClientException('Network unavailable'));

      await expectLater(repository.create(assetId, [brush()]), throwsA(isA<api.ApiException>()));
      expect(requests, hasLength(1));
    });

    test('uses the provided abort trigger while submitting a mask', () async {
      final abort = Completer<void>();
      stub((request) async {
        expect(request, isA<http.AbortableRequest>());
        final abortable = request as http.AbortableRequest;
        expect(abortable.abortTrigger, isNotNull);
        await abortable.abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final pending = repository.create(assetId, [brush()], abortTrigger: abort.future);
      final assertion = expectLater(pending, throwsA(anything));
      abort.complete();
      await assertion;
      expect(requests, hasLength(1));
    });
  });

  group('bounded original-aligned source and result previews', () {
    test('streaming image requests preserve API-client authentication, not only static headers', () async {
      final bearer = api.HttpBearerAuth()..accessToken = 'current-authentication-token';
      apiClient = api.ApiClient(basePath: 'https://gallery.test/api', authentication: bearer);
      when(() => service.apiClient).thenReturn(apiClient);
      stub((_) => response(jpeg, contentType: 'image/jpeg'));

      await repository.source(assetId);
      await repository.preview(assetId, jobId);

      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.headers['Authorization'], 'Bearer current-authentication-token');
      }
    });

    test('streaming images preserve query authentication without losing encoded values', () async {
      final key = api.ApiKeyAuth('query', 'access-key')..apiKey = 'key + ampersand&';
      apiClient = api.ApiClient(basePath: 'https://gallery.test/api', authentication: key);
      when(() => service.apiClient).thenReturn(apiClient);
      stub((_) => response(jpeg, contentType: 'image/jpeg'));

      await repository.source(assetId);

      expect(requests.single.url.queryParameters, {'access-key': 'key + ampersand&'});
    });

    test('gets a server-derived source preview without asking the phone to fetch the original', () async {
      stub((_) => response(jpeg, contentType: 'image/jpeg'));

      expect(await repository.source(assetId), Uint8List.fromList(jpeg));

      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '$basePath/source');
      expect(requests.single.headers['Authorization'], 'Bearer test-session');
      expect(requests.single.headers['x-custom-header'], 'proxy-header');
    });

    test('gets a result preview while leaving save as an explicit separate action', () async {
      stub((_) => response(jpeg, contentType: 'image/jpeg'));

      expect(await repository.preview(assetId, jobId), Uint8List.fromList(jpeg));

      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '$basePath/$jobId/preview');
    });

    test('rejects unsuccessful image responses instead of decoding a server error as a photograph', () async {
      stub((_) => jsonResponse({'message': 'Forbidden'}, status: 403));

      await expectLater(repository.source(assetId), throwsA(isA<api.ApiException>()));
      await expectLater(repository.preview(assetId, jobId), throwsA(isA<api.ApiException>()));
    });

    test('rejects an oversized declared source and cancels its response stream immediately', () async {
      var streamWasCancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => streamWasCancelled = true);
      stub(
        (_) => http.StreamedResponse(
          controller.stream,
          200,
          contentLength: 8 * 1024 * 1024 + 1,
          headers: {'content-type': 'image/jpeg'},
        ),
      );

      await expectLater(repository.source(assetId), throwsA(anything));
      expect(streamWasCancelled, isTrue);
      await controller.close();
    });

    test('rejects an empty preview rather than presenting a broken image as a result', () async {
      stub((_) => response(const [], contentType: 'image/jpeg'));

      await expectLater(repository.preview(assetId, jobId), throwsA(isA<FormatException>()));
    });

    test('limits a chunked preview with no content length and stops reading after the bound', () async {
      var chunksRead = 0;
      Stream<List<int>> oversized() async* {
        for (var index = 0; index < 20; index++) {
          chunksRead++;
          yield Uint8List(1024 * 1024);
        }
      }

      stub((_) => http.StreamedResponse(oversized(), 200, headers: {'content-type': 'image/jpeg'}));

      await expectLater(repository.preview(assetId, jobId), throwsA(anything));
      expect(chunksRead, lessThan(20));
      expect(chunksRead, lessThanOrEqualTo(9));
    });

    test('uses abortable transport for source loading', () async {
      final abort = Completer<void>();
      stub((request) async {
        expect(request, isA<http.AbortableRequest>());
        final abortable = request as http.AbortableRequest;
        expect(abortable.abortTrigger, isNotNull);
        await abortable.abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final pending = repository.source(assetId, abortTrigger: abort.future);
      final assertion = expectLater(pending, throwsA(anything));
      abort.complete();
      await assertion;
    });
  });

  group('explicit lifecycle operations', () {
    test('cancels a job through DELETE without deleting or changing the source asset', () async {
      stub((_) => response(const [], status: 204));

      await repository.cancel(assetId, jobId);

      expect(requests, hasLength(1));
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '$basePath/$jobId');
      expect((requests.single as http.Request).body, isEmpty);
    });

    test('saves only an explicit new asset result, never PUTs over the original', () async {
      stub((_) => jsonResponse({'id': 'new-copy-id', 'status': 'success'}, status: 201));

      expect(await repository.save(assetId, jobId), 'new-copy-id');

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '$basePath/$jobId/save');
    });

    test('surfaces ownership and expired job errors for save and cancel', () async {
      stub((_) => jsonResponse({'message': 'Forbidden'}, status: 403));
      await expectLater(repository.save(assetId, jobId), throwsA(isA<api.ApiException>()));
      await expectLater(repository.cancel(assetId, jobId), throwsA(isA<api.ApiException>()));
    });
  });

  group('bounded network operations', () {
    for (final image in [false, true]) {
      test(
        '${image ? 'preview' : 'mask'} transport is cancelled after 90 seconds even without a user cancellation',
        () {
          FakeAsync().run((async) {
            var aborted = false;
            Object? failure;
            stub((request) async {
              await (request as http.AbortableRequest).abortTrigger;
              aborted = true;
              throw http.RequestAbortedException(request.url);
            });
            final pending = image ? repository.source(assetId) : repository.create(assetId, [brush()]);
            unawaited(pending.then<void>((_) {}, onError: (Object error, StackTrace _) => failure = error));
            async.flushMicrotasks();
            async.elapse(const Duration(seconds: 89));
            async.flushMicrotasks();
            expect(aborted, isFalse);
            expect(failure, isNull);
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();

            expect(aborted, isTrue);
            expect(failure, isNotNull);
            expect(async.nonPeriodicTimerCount, 0);
          });
        },
      );
    }
  });
}
