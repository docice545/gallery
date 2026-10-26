import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:immich_mobile/domain/services/remote_image_reconciliation.service.dart';

const _id = '8dd6007e-f11b-4bf8-bc3a-121794f37303';
const _other = 'a37fcb48-5cf3-47e2-97ea-4b16898756ee';
const _endpoint = 'https://example.test/photos/api';
String _url(String id) => '$_endpoint/assets/$id/thumbnail?size=thumbnail';
RemoteImageHttpException _error(String id, {int status = 400}) => RemoteImageHttpException(
  statusCode: status,
  requestId: 1,
  requestPath: '/photos/api/assets/$id/thumbnail',
  finalPath: '/photos/api/assets/$id/thumbnail',
  stage: 'thumbnail',
);

void main() {
  late bool current;
  late bool complete;
  late int confirmations;
  late int syncs;
  late List<String> retired;
  late DateTime now;
  late RemoteImageReconciliationService service;

  setUp(() {
    current = true;
    complete = false;
    confirmations = 0;
    syncs = 0;
    retired = [];
    now = DateTime.utc(2026, 10, 26);
    service = RemoteImageReconciliationService(
      endpoint: Uri.parse(_endpoint),
      isCurrentSession: () => current,
      isDeletionComplete: (_) async {
        confirmations++;
        return complete;
      },
      retireDeletedAsset: (id) async {
        retired.add(id);
        return true;
      },
      syncIncrementally: () async => syncs++,
      now: () => now,
    );
  });

  test('HTTP400 cannot retire a row without an authoritative complete receipt', () async {
    expect(await service.reconcile(_error(_id), _url(_id)), isFalse);
    expect(retired, isEmpty);
    expect(confirmations, 1);
    expect(syncs, 1);
  });

  for (final status in [400, 404]) {
    test('confirmed HTTP$status deletion retires only the requested remote cache', () async {
      complete = true;
      expect(await service.reconcile(_error(_id, status: status), _url(_id)), isTrue);
      expect(retired, [_id]);
      expect(syncs, 0);
    });
  }

  test('repeated failed tiles coalesce and never create an active retry loop', () async {
    final first = service.reconcile(_error(_id), _url(_id));
    final second = service.reconcile(_error(_id), _url(_id));
    expect(second, same(first));
    await Future.wait([first, second]);
    await service.reconcile(_error(_id), _url(_id));
    await service.reconcile(_error(_other), _url(_other));
    expect(confirmations, 2);
    expect(syncs, 1);
    now = now.add(const Duration(seconds: 31));
    complete = true;
    expect(await service.reconcile(_error(_id), _url(_id)), isTrue);
    expect(confirmations, 3);
    expect(retired, [_id]);
  });

  test('unknown status, external URL, other route and old session do not reconcile', () async {
    for (final status in [401, 403, 429, 500, 503]) {
      expect(await service.reconcile(_error(_id, status: status), _url(_id)), isFalse);
    }
    expect(await service.reconcile(_error(_id), 'https://other.test/photos/api/assets/$_id/thumbnail'), isFalse);
    expect(await service.reconcile(_error(_id), 'https://example.test/other/assets/$_id/thumbnail'), isFalse);
    expect(await service.reconcile(_error(_id), '/photos/api/assets/$_id/thumbnail'), isFalse);
    current = false;
    expect(await service.reconcile(_error(_id), _url(_id)), isFalse);
    expect(confirmations, 0);
    expect(syncs, 0);
  });

  test('account switch while receipt is in flight cannot mutate another account', () async {
    final receipt = Completer<bool>();
    service = RemoteImageReconciliationService(
      endpoint: Uri.parse(_endpoint),
      isCurrentSession: () => current,
      isDeletionComplete: (_) => receipt.future,
      retireDeletedAsset: (id) async {
        retired.add(id);
        return true;
      },
      syncIncrementally: () async => syncs++,
    );
    final work = service.reconcile(_error(_id), _url(_id));
    await Future<void>.delayed(Duration.zero);
    current = false;
    receipt.complete(true);
    expect(await work, isFalse);
    expect(retired, isEmpty);
    expect(syncs, 0);
  });

  test('canonical media URLs reconcile through the captured LAN API route without accepting foreign servers', () async {
    service = RemoteImageReconciliationService(
      endpoint: Uri.parse('http://192.0.2.2:2283/api'),
      mediaEndpoint: Uri.parse(_endpoint),
      isCurrentSession: () => current,
      isDeletionComplete: (_) async => true,
      retireDeletedAsset: (id) async {
        retired.add(id);
        return true;
      },
      syncIncrementally: () async {},
    );
    expect(await service.reconcile(_error(_id), _url(_id)), isTrue);
    expect(
      await service.reconcile(_error(_other), 'https://foreign.test/photos/api/assets/$_other/thumbnail'),
      isFalse,
    );
    expect(retired, [_id]);
  });

  test('a Wi-Fi route change keeps the same library usable and rejects the previous route', () async {
    var route = Uri.parse('http://192.0.2.2:2283/api');
    final receipt = Completer<bool>();
    service = RemoteImageReconciliationService(
      endpoint: route,
      mediaEndpoint: Uri.parse(_endpoint),
      currentEndpoint: () => route,
      isCurrentSession: () => current,
      isDeletionComplete: (_) => receipt.future,
      retireDeletedAsset: (id) async {
        retired.add(id);
        return true;
      },
      syncIncrementally: () async {},
    );
    final pending = service.reconcile(_error(_id), _url(_id));
    await Future<void>.delayed(Duration.zero);
    route = Uri.parse('http://192.0.2.3:2283/api');
    receipt.complete(true);
    expect(await pending, isTrue, reason: 'same account and canonical library remain authoritative');
    const error = RemoteImageHttpException(
      statusCode: 400,
      requestId: 2,
      requestPath: '/api/assets/$_other/thumbnail',
      finalPath: '/api/assets/$_other/thumbnail',
      stage: 'thumbnail',
    );
    expect(await service.reconcile(error, 'http://192.0.2.3:2283/api/assets/$_other/thumbnail'), isTrue);
    expect(await service.reconcile(error, 'http://192.0.2.2:2283/api/assets/$_other/thumbnail'), isFalse);
    expect(retired, [_id, _other]);
  });

  test('receipt/network failure is unresolved and does not poison the next operation', () async {
    var first = true;
    service = RemoteImageReconciliationService(
      endpoint: Uri.parse(_endpoint),
      isCurrentSession: () => current,
      isDeletionComplete: (_) async {
        if (first) {
          first = false;
          throw StateError('database/network unavailable');
        }
        return true;
      },
      retireDeletedAsset: (id) async {
        retired.add(id);
        return true;
      },
      syncIncrementally: () async => syncs++,
    );
    expect(await service.reconcile(_error(_id), _url(_id)), isFalse);
    expect(await service.reconcile(_error(_other), _url(_other)), isTrue);
    expect(retired, [_other]);
  });

  test('pending work and settled cache are bounded while the viewport changes', () async {
    final gate = Completer<bool>();
    confirmations = 0;
    service = RemoteImageReconciliationService(
      endpoint: Uri.parse(_endpoint),
      isCurrentSession: () => current,
      isDeletionComplete: (_) {
        confirmations++;
        return gate.future;
      },
      retireDeletedAsset: (_) async => true,
      syncIncrementally: () async {},
    );
    final work = <Future<bool>>[];
    for (var i = 0; i < 100; i++) {
      final id = '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';
      work.add(service.reconcile(_error(id), _url(id)));
    }
    await Future<void>.delayed(Duration.zero);
    expect(confirmations, 1, reason: 'receipt requests are serial');
    gate.complete(true);
    expect((await Future.wait(work)).where((deleted) => deleted).length, 32);
    expect(confirmations, 32);
  });
}
