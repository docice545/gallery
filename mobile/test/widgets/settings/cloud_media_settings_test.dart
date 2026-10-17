import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/widgets/settings/cloud_media_settings.dart';

import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

void main() {
  const channel = MethodChannel('app.alextran.immich/cloudMedia');
  final t = StaticTranslations.instance;
  late Map<String, Object?> status;
  late List<String> calls;
  setUpAll(TestUtils.init);
  setUp(() {
    status = {'supported': true, 'signedIn': true, 'enabled': false, 'recoveryPending': false};
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, isNull, reason: 'Shizuku bridge never receives paths, credentials or generic commands');
      return status;
    });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  testWidgets('opt-in starts disabled and never activates automatically', (tester) async {
    await tester.pumpConsumerWidget(const CloudMediaSettings());
    expect(calls, ['status']);
    expect(find.text(t.cloud_media_disabled), findsOneWidget);
    expect(find.text(t.cloud_media_enable), findsOneWidget);
    expect(find.text(t.cloud_media_picker_settings), findsNothing);
  });
  testWidgets('admission and selection are separate, verified states', (tester) async {
    await tester.pumpConsumerWidget(const CloudMediaSettings());
    status = {...status, 'enabled': true, 'admitted': true, 'selected': false};
    await tester.tap(find.text(t.cloud_media_enable));
    await tester.pumpAndSettle();
    expect(find.text(t.cloud_media_admitted), findsOneWidget);
    expect(find.text(t.cloud_media_selected), findsNothing);
    status = {...status, 'selected': true};
    await tester.tap(find.text(t.cloud_media_diagnostics));
    await tester.pumpAndSettle();
    expect(find.text(t.cloud_media_selected), findsOneWidget);
    expect(calls, containsAllInOrder(['status', 'enable', 'diagnose']));
  });
  testWidgets('unsupported Android or signed-out account cannot enable', (tester) async {
    for (final state in [
      {...status, 'supported': false},
      {...status, 'signedIn': false},
    ]) {
      status = state;
      await tester.pumpConsumerWidget(const CloudMediaSettings());
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, t.cloud_media_enable)).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    }
    expect(calls.where((c) => c == 'enable'), isEmpty);
  });
  testWidgets('failed permission/admission never claims enabled or selected', (tester) async {
    await tester.pumpConsumerWidget(const CloudMediaSettings());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'enable') {
        throw PlatformException(code: 'permissionDenied');
      }
      return status;
    });
    await tester.tap(find.text(t.cloud_media_enable));
    await tester.pumpAndSettle();
    expect(find.text(t.cloud_media_failed), findsOneWidget);
    expect(find.text(t.cloud_media_selected), findsNothing);
    expect(find.text(t.cloud_media_picker_settings), findsNothing);
  });
  testWidgets('local opt-out with Shizuku stopped shows pending recovery rather than success', (tester) async {
    status = {...status, 'enabled': true, 'recoveryPending': true};
    await tester.pumpConsumerWidget(const CloudMediaSettings());
    status = {...status, 'enabled': false, 'shizukuRunning': false};
    await tester.tap(find.text(t.cloud_media_disable));
    await tester.pumpAndSettle();
    expect(find.text(t.cloud_media_disabled), findsOneWidget);
    expect(find.text(t.cloud_media_recovery_pending), findsOneWidget);
    expect(find.text(t.cloud_media_disable), findsOneWidget);
  });
  testWidgets('cancellation is explicit and no system-settings side effect is implied', (tester) async {
    await tester.pumpConsumerWidget(const CloudMediaSettings());
    final enabling = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'enable') {
        return enabling.future;
      }
      if (call.method == 'cancel') {
        enabling.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return status;
    });
    await tester.tap(find.text(t.cloud_media_enable));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(calls, contains('cancel'));
    expect(calls, isNot(contains('openPickerSettings')));
    expect(find.text(t.cloud_media_failed), findsOneWidget);
  });
}
