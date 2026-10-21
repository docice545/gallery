import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

import '../fixtures/editor_image_stream.dart';
import '../fixtures/editor_raster.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EditorTestImageProvider provider;
  late EditorTestImageCompleter stream;
  late ui.Image source;

  setUp(() async {
    source = await createEditorRaster();
    stream = EditorTestImageCompleter();
    provider = EditorTestImageProvider()..sources.add(stream);
  });

  tearDown(() => source.dispose());

  for (final synchronous in [false, true]) {
    testWidgets('owns the decoded handle and detaches after a ${synchronous ? 'cached' : 'delayed'} image', (
      tester,
    ) async {
      if (synchronous) {
        stream.emitImage(ImageInfo(image: source.clone()));
      }
      final loaded = EditedImageExporter.loadSource(provider);
      if (!synchronous) {
        expect(stream.isObserved, isTrue);
        stream.emitImage(ImageInfo(image: source.clone()));
      }
      final image = await loaded;
      addTearDown(image.dispose);
      expect(stream.isObserved, isFalse);
      expect((image.width, image.height), (64, 48));
      // The completer has released its handle; the caller's clone remains usable.
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba));
      expect(bytes!.lengthInBytes, 64 * 48 * 4);
    });
  }

  testWidgets('propagates decoding failure and detaches so a new source can be retried', (tester) async {
    final error = StateError('Invalid original');
    final failed = expectLater(EditedImageExporter.loadSource(provider), throwsA(same(error)));
    expect(stream.isObserved, isTrue);
    stream.emitError(error);
    await failed;
    expect(stream.isObserved, isFalse);

    final retry = EditorTestImageCompleter();
    provider.sources.add(retry);
    final loaded = EditedImageExporter.loadSource(provider);
    retry.emitImage(ImageInfo(image: source.clone()));
    final image = await loaded;
    image.dispose();
    expect(retry.isObserved, isFalse);
  });

  testWidgets('times out at the default deadline, detaches, and ignores late images during a retry', (tester) async {
    // Keep the old stream alive to simulate a provider that finishes after timeout.
    final keepAlive = stream.keepAlive();
    addTearDown(keepAlive.dispose);
    final failed = expectLater(EditedImageExporter.loadSource(provider), throwsA(isA<TimeoutException>()));
    await tester.pump(EditedImageExporter.sourceLoadTimeout - const Duration(milliseconds: 1));
    expect(stream.isObserved, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    await failed;
    expect(stream.isObserved, isFalse);

    final retry = EditorTestImageCompleter();
    provider.sources.add(retry);
    final loaded = EditedImageExporter.loadSource(provider);
    // This stale frame must not complete or interfere with the second load.
    stream.emitImage(ImageInfo(image: source.clone()));
    expect(retry.isObserved, isTrue);
    retry.emitImage(ImageInfo(image: source.clone()));
    final image = await loaded;
    expect((image.width, image.height), (64, 48));
    image.dispose();
    expect(retry.isObserved, isFalse);
  });
  testWidgets('cancel detaches a stalled decoder immediately and a late frame cannot affect retry', (tester) async {
    final cancel = Completer<void>();
    final failed = expectLater(
      EditedImageExporter.loadSource(provider, cancel: cancel.future),
      throwsA(isA<ImageExportCancelledException>()),
    );
    expect(stream.isObserved, isTrue);
    cancel.complete();
    await tester.pump();
    await failed;
    expect(stream.isObserved, isFalse);
    final retry = EditorTestImageCompleter()..emitImage(ImageInfo(image: source.clone()));
    provider.sources.add(retry);
    final image = await EditedImageExporter.loadSource(provider);
    expect((image.width, image.height), (64, 48));
    image.dispose();
  });

  test('export dimensions are bounded without allocating an oversized raster', () {
    expect(() => EditedImageExporter.validateDimensions(9000, 9000), throwsA(isA<ImageExportLimitException>()));
    expect(() => EditedImageExporter.validateDimensions(0, 100), throwsA(isA<ImageExportLimitException>()));
    EditedImageExporter.validateDimensions(6000, 4000);
  });
}
