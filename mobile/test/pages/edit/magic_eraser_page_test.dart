import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser.page.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/widgets/common/transparent_image.dart';
import 'package:mocktail/mocktail.dart';

import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _MockMagicEraserRepository extends Mock implements MagicEraserRepository {}

void main() {
  late _MockMagicEraserRepository repository;
  late RemoteAsset asset;
  late Uint8List source;
  late Uint8List result;
  final canvas = find.byKey(const Key('eraser-canvas'));
  final remove = find.byKey(const Key('eraser-remove'));
  final save = find.byKey(const Key('eraser-save'));
  final cancel = find.byKey(const Key('eraser-cancel'));

  setUpAll(() => registerFallbackValue(<MagicEraserStroke>[]));

  setUp(() {
    TestUtils.init();
    repository = _MockMagicEraserRepository();
    asset = TestUtils.createRemoteAsset(id: 'server-only-asset', width: 1, height: 1);
    source = Uint8List.fromList(kTransparentImage);
    result = Uint8List.fromList(kTransparentImage);
    when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => source);
    when(() => repository.cancel(any(), any())).thenAnswer((_) async {});
    when(
      () => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenAnswer((_) async => result);
  });

  Future<void> pumpEditor(WidgetTester tester, {RemoteAsset? photo}) async {
    await tester.runAsync(() async {
      await tester.pumpConsumerWidgetRaw(
        MagicEraserPage(asset: photo ?? asset),
        overrides: [magicEraserRepositoryProvider.overrideWithValue(repository)],
      );
      // Native descriptor/image decoding completes outside the fake timer zone.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  bool canRemove(WidgetTester tester) => tester.widget<FilledButton>(remove).onPressed != null;

  Future<void> selectCenter(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(canvas));
    await tester.pump();
    expect(canRemove(tester), isTrue);
  }

  Future<void> disposeEditor(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> showResult(WidgetTester tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'ready-job', status: MagicEraserStatus.ready));
    await selectCenter(tester);
    await tester.runAsync(() async {
      await tester.tap(remove);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(save, findsOneWidget);
  }

  MemoryImage displayedImage(WidgetTester tester) =>
      tester.widget<Image>(find.descendant(of: canvas, matching: find.byType(Image))).image as MemoryImage;

  testWidgets('an older or disabled server leaves the feature unavailable without requesting an original', (
    tester,
  ) async {
    when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => false);

    await pumpEditor(tester);

    expect(canvas, findsNothing);
    expect(remove, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));
  });

  testWidgets('a server-only source displays without inpainting or importing an asset automatically', (tester) async {
    await pumpEditor(tester);

    expect(canvas, findsOneWidget);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isFalse);
    expect(find.byKey(const Key('eraser-brush-size')), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsOneWidget);
    expect(find.byIcon(Icons.redo), findsOneWidget);
    verifyNever(() => repository.create(any(), any()));
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('a failed source download can be retried without creating a job or changing the asset', (tester) async {
    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenThrow(StateError('Offline'));
    await pumpEditor(tester);
    expect(canvas, findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => source);
    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(canvas, findsOneWidget);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isFalse);
    verifyNever(() => repository.create(any(), any()));
  });

  testWidgets('brush taps, undo, redo and reset maintain a removable selection', (tester) async {
    await pumpEditor(tester);
    await selectCenter(tester);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    await tester.tap(find.byIcon(Icons.redo));
    await tester.pump();
    expect(canRemove(tester), isTrue);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    final redoButton = tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(Icons.redo), matching: find.byType(IconButton)),
    );
    expect(redoButton.onPressed, isNull);
  });

  testWidgets('a continuous brush drag produces a selection after competing tap gestures cancel', (tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'drag-job', status: MagicEraserStatus.ready));
    await pumpEditor(tester);
    final imageRect = tester.getRect(canvas);
    final gesture = await tester.startGesture(Offset(imageRect.left + imageRect.width * 0.25, imageRect.center.dy));
    for (var index = 0; index < 4; index++) {
      await gesture.moveBy(Offset(imageRect.width * 0.1, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(canRemove(tester), isTrue);
    await tester.tap(remove);
    await tester.pump();
    await tester.pump();

    final strokes = verify(() => repository.create(asset.id, captureAny())).captured.single as List<MagicEraserStroke>;
    expect(strokes, hasLength(1));
    expect(strokes.single.points.length, greaterThan(1));
    expect(strokes.single.points.last.dx, greaterThan(strokes.single.points.first.dx));
  });

  testWidgets('brush size and additive/eraser gestures are sent as normalized mask operations', (tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'ready-job', status: MagicEraserStatus.ready));
    await pumpEditor(tester);
    await selectCenter(tester);
    final slider = find.byKey(const Key('eraser-brush-size'));
    final sliderRect = tester.getRect(slider);
    await tester.tapAt(Offset(sliderRect.right - 24, sliderRect.center.dy));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.auto_fix_off));
    await tester.tapAt(tester.getCenter(canvas) + const Offset(20, 0));
    await tester.pump();
    await tester.tap(remove);
    await tester.pump();
    await tester.pump();

    final strokes = verify(() => repository.create(asset.id, captureAny())).captured.single as List<MagicEraserStroke>;
    expect(strokes, hasLength(2));
    expect(strokes.first.erase, isFalse);
    expect(strokes.last.erase, isTrue);
    expect(strokes.last.radius, greaterThan(strokes.first.radius));
    for (final stroke in strokes) {
      expect(stroke.radius, inInclusiveRange(0.001, 0.25));
      for (final point in stroke.points) {
        expect(point.dx, inInclusiveRange(0, 1));
        expect(point.dy, inInclusiveRange(0, 1));
      }
    }
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('zoom mode enables image gestures and does not paint a selection', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byIcon(Icons.zoom_in));
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.panEnabled, isTrue);
    expect(viewer.scaleEnabled, isTrue);
    await tester.drag(canvas, const Offset(40, 20));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    await tester.tap(find.byIcon(Icons.brush));
    await tester.pump();
    expect(tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).scaleEnabled, isFalse);
    await selectCenter(tester);
  });

  testWidgets('processing shows progress, prevents repeated submit and stops the known server job on Cancel', (
    tester,
  ) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'queued-job', status: MagicEraserStatus.queued));
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(canRemove(tester), isFalse);
    expect(tester.widget<Slider>(find.byKey(const Key('eraser-brush-size'))).onChanged, isNull);
    await tester.tap(cancel);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(canRemove(tester), isTrue);
    verify(() => repository.create(asset.id, any())).called(1);
    verify(() => repository.cancel(asset.id, 'queued-job')).called(1);
    verifyNever(() => repository.getJob(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    verifyNever(() => repository.save(any(), any()));
    await disposeEditor(tester);
    verifyNever(() => repository.cancel(asset.id, 'queued-job'));
  });

  testWidgets('Cancel during job creation discards a late result instead of leaving an unknown server job', (
    tester,
  ) async {
    final created = Completer<MagicEraserJob>();
    when(() => repository.create(asset.id, any())).thenAnswer((_) => created.future);
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();
    await tester.tap(cancel);
    await tester.pump();
    created.complete(const MagicEraserJob(id: 'late-job', status: MagicEraserStatus.ready));
    await tester.pump();

    verify(() => repository.cancel(asset.id, 'late-job')).called(1);
    verifyNever(() => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    expect(save, findsNothing);
    expect(canRemove(tester), isTrue);
  });

  testWidgets('Before/After changes only the displayed preview and Save copy remains explicit', (tester) async {
    await pumpEditor(tester);
    await showResult(tester);

    expect(displayedImage(tester).bytes, same(result));
    await tester.tap(find.text('Before'));
    await tester.pump();
    expect(displayedImage(tester).bytes, same(source));
    await tester.tap(find.text('After'));
    await tester.pump();
    expect(displayedImage(tester).bytes, same(result));
    verifyNever(() => repository.save(any(), any()));
    expect(asset.localId, isNull);
    expect(asset.isEdited, isFalse);
    await disposeEditor(tester);
    verify(() => repository.cancel(asset.id, 'ready-job')).called(1);
  });

  testWidgets('Save copy cannot be submitted twice and disposal does not cancel an atomic import', (tester) async {
    final saved = Completer<String>();
    when(() => repository.save(asset.id, 'ready-job')).thenAnswer((_) => saved.future);
    await pumpEditor(tester);
    await showResult(tester);
    await tester.tap(save);
    await tester.pump();

    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cancel, findsNothing);
    await disposeEditor(tester);
    saved.complete('new-copy-id');
    await tester.pump();

    verify(() => repository.save(asset.id, 'ready-job')).called(1);
    verifyNever(() => repository.cancel(asset.id, 'ready-job'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed processing job retains the original and permits retry without a silent save', (tester) async {
    when(() => repository.create(asset.id, any())).thenAnswer(
      (_) async =>
          const MagicEraserJob(id: 'failed-job', status: MagicEraserStatus.failed, errorCode: 'inpainting_failed'),
    );
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isTrue);
    expect(save, findsNothing);
    verifyNever(() => repository.save(any(), any()));
  });

  for (final oversized in [false, true]) {
    testWidgets('rejects an ${oversized ? 'oversized decoded' : 'invalid encoded'} result without offering Save copy', (
      tester,
    ) async {
      Uint8List bytes;
      if (oversized) {
        bytes = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final painting = Canvas(recorder);
          painting.drawRect(const Rect.fromLTWH(0, 0, 1601, 1), Paint()..color = Colors.white);
          final picture = recorder.endRecording();
          final image = await picture.toImage(1601, 1);
          picture.dispose();
          try {
            return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }))!;
      } else {
        bytes = Uint8List.fromList([0, 1, 2, 3]);
      }
      when(
        () => repository.create(asset.id, any()),
      ).thenAnswer((_) async => const MagicEraserJob(id: 'invalid-preview-job', status: MagicEraserStatus.ready));
      when(
        () => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')),
      ).thenAnswer((_) async => bytes);
      await pumpEditor(tester);
      await selectCenter(tester);
      await tester.runAsync(() async {
        await tester.tap(remove);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(save, findsNothing);
      expect(displayedImage(tester).bytes, same(source));
      expect(canRemove(tester), isTrue);
      verifyNever(() => repository.save(any(), any()));
      await disposeEditor(tester);
      verify(() => repository.cancel(asset.id, 'invalid-preview-job')).called(1);
    });
  }

  testWidgets('closing while creating a job cancels its late response and does not update a disposed widget', (
    tester,
  ) async {
    final created = Completer<MagicEraserJob>();
    when(() => repository.create(asset.id, any())).thenAnswer((_) => created.future);
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();
    await disposeEditor(tester);
    created.complete(const MagicEraserJob(id: 'disconnected-job', status: MagicEraserStatus.ready));
    await tester.pump();

    verify(() => repository.cancel(asset.id, 'disconnected-job')).called(1);
    verifyNever(() => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Motion/Live Photo editing identifies the independent still copy without changing its pair', (
    tester,
  ) async {
    final live = asset.copyWith(livePhotoVideoId: 'linked-video', stackId: 'existing-stack');
    await pumpEditor(tester, photo: live);

    expect(canvas, findsOneWidget);
    expect(live.livePhotoVideoId, 'linked-video');
    expect(live.stackId, 'existing-stack');
    expect(live.isEdited, isFalse);
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('Russian mask controls and Before/After/Save fit a 320 dp viewport with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpEditor(tester, photo: asset.copyWith(livePhotoVideoId: 'motion-video'));
    await EasyLocalization.of(tester.element(canvas))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    await showResult(tester);
    await tester.pump();

    expect(save, findsOneWidget);
    expect(tester.getRect(save).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(save).right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
}
