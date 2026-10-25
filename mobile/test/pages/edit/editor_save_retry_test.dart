import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../fixtures/editor_image_stream.dart';
import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _MockFileMediaRepository extends Mock implements FileMediaRepository {}

class _MockAssetEntity extends Mock implements AssetEntity {}

void main() {
  late _MockFileMediaRepository media;
  late EditorTestImageProvider imageProvider;
  var applyEditsCalls = 0;
  final save = find.byKey(const Key('editor-save'));

  // Native raster work and file I/O complete on real time; pump fake frames
  // between completions so the production async continuations can advance.
  Future<void> finishCopy(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100 && find.byType(EditImagePage).evaluate().isNotEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(EditImagePage), findsNothing, reason: 'Copy must finish and close the editor');
    await tester.pumpAndSettle();
  }

  setUp(() {
    TestUtils.init();
    imageProvider = EditorTestImageProvider();
    media = _MockFileMediaRepository();
    applyEditsCalls = 0;
  });

  Future<ProviderContainer> openEditor(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpConsumerWidgetRaw(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EditImagePage(
                    image: Image(image: imageProvider),
                    applyEdits: (_) async => applyEditsCalls++,
                  ),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
        overrides: [
          fileMediaRepositoryProvider.overrideWithValue(media),
          immichThemeProvider.overrideWith(
            (ref) => ImmichTheme(
              light: ColorScheme.fromSeed(seedColor: Colors.purple),
              dark: ColorScheme.fromSeed(seedColor: Colors.purple, brightness: Brightness.dark),
            ),
          ),
        ],
      );
      await tester.tap(find.text('Open editor'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-mode-crop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
  }

  Future<void> chooseCopy(WidgetTester tester, EditorTestImageCompleter pending) async {
    imageProvider.sources.add(pending);
    await tester.tap(save);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('edit-save-mode-dialog')), findsNothing);
    expect(find.byKey(const Key('edit-replace-original')), findsNothing);
    expect(find.byKey(const Key('edit-save-copy')), findsNothing);
  }

  for (final timeout in [true, false]) {
    testWidgets('successfully saves a PNG copy after ${timeout ? 'timeout' : 'decode failure'}', (tester) async {
      final directory = await tester.runAsync(() => Directory.systemTemp.createTemp('gallery-build17-copy-test-'));
      final temporaryDirectory = directory!;
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => temporaryDirectory.path,
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
      );
      final source = (await tester.runAsync(createEditorRaster))!;
      addTearDown(source.dispose);
      final container = await openEditor(tester);
      final pending = EditorTestImageCompleter();
      await chooseCopy(tester, pending);
      if (timeout) {
        await tester.pump(EditedImageExporter.sourceLoadTimeout);
      } else {
        pending.emitError(StateError('Decode failed'));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).isApplyingEdits, isFalse);
      expect(container.read(editorStateProvider).rotationAngle, -90);
      expect(temporaryDirectory.listSync(), isEmpty);
      verifyNever(
        () => media.saveImageWithFile(
          any(),
          title: any(named: 'title'),
          relativePath: any(named: 'relativePath'),
        ),
      );

      List<int>? savedBytes;
      String? savedPath;
      var cleanedUpBeforePop = false;
      final subscription = container.listen(editorStateProvider, (_, state) {
        if (!state.isApplyingEdits && savedPath != null) {
          expect(File(savedPath!).existsSync(), isFalse);
          expect(find.byType(EditImagePage), findsOneWidget);
          cleanedUpBeforePop = true;
        }
      });
      addTearDown(subscription.close);
      when(
        () => media.saveImageWithFile(
          any(),
          title: any(named: 'title'),
          relativePath: any(named: 'relativePath'),
        ),
      ).thenAnswer((invocation) async {
        savedPath = invocation.positionalArguments.single as String;
        savedBytes = await File(savedPath!).readAsBytes();
        expect(container.read(editorStateProvider).isApplyingEdits, isTrue);
        return _MockAssetEntity();
      });
      final retry = EditorTestImageCompleter()..emitImage(ImageInfo(image: source.clone()));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await chooseCopy(tester, retry);
      await finishCopy(tester);

      expect(savedBytes, isNotNull);
      expect(savedBytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(savedBytes!));
        final decoded = (await codec.getNextFrame()).image;
        try {
          expect((decoded.width, decoded.height), (48, 64));
          final expected = rotateEditorTiles(editorRasterColors, 3);
          expect(await sampleEditorTiles(decoded, columns: 3, rows: 4), [
            for (final row in expected) [for (final color in row) color.toARGB32()],
          ]);
          expect(await sampleEditorTiles(source, columns: 4, rows: 3), [
            for (final row in editorRasterColors) [for (final color in row) color.toARGB32()],
          ], reason: 'The source image must remain unchanged');
        } finally {
          decoded.dispose();
          codec.dispose();
        }
      });
      expect(savedPath, startsWith('${temporaryDirectory.path}/gallery-edit-'));
      expect(File(savedPath!).existsSync(), isFalse);
      expect(temporaryDirectory.listSync(), isEmpty);
      expect(cleanedUpBeforePop, isTrue);
      expect(container.read(editorStateProvider).isApplyingEdits, isFalse);
      expect(find.text('Open editor'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      verify(
        () => media.saveImageWithFile(
          any(),
          title: any(named: 'title'),
          relativePath: 'DCIM/Noodle Gallery',
        ),
      ).called(1);
      expect(applyEditsCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets(
      '${timeout ? 'a hanging' : 'a failed'} original load restores direct copy saving without losing edits',
      (tester) async {
        final container = await openEditor(tester);
        final pending = EditorTestImageCompleter();
        await chooseCopy(tester, pending);
        expect(container.read(editorStateProvider).isApplyingEdits, isTrue);
        expect(pending.isObserved, isTrue);
        expect(save, findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        if (timeout) {
          await tester.pump(EditedImageExporter.sourceLoadTimeout);
        } else {
          pending.emitError(StateError('Decode failed'));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(container.read(editorStateProvider).isApplyingEdits, isFalse);
        expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
        expect(container.read(editorStateProvider).rotationAngle, -90);
        expect(pending.isObserved, isFalse);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(save, findsOneWidget);
        expect(
          find.text(
            'Could not save a copy. Check the connection, image format and device photo permissions, then retry.',
          ),
          findsOneWidget,
        );
        verifyNever(
          () => media.saveImageWithFile(
            any(),
            title: any(named: 'title'),
            relativePath: any(named: 'relativePath'),
          ),
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        final retry = EditorTestImageCompleter();
        await chooseCopy(tester, retry);
        expect(container.read(editorStateProvider).isApplyingEdits, isTrue);
        expect(retry.isObserved, isTrue);
        await tester.tap(find.byKey(const Key('editor-cancel-export')));
        await tester.pumpAndSettle();
        expect(container.read(editorStateProvider).isApplyingEdits, isFalse);
        expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
        expect(container.read(editorStateProvider).rotationAngle, -90);
        expect(applyEditsCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets('canceling original load preserves edits, releases source and never imports a partial copy', (
    tester,
  ) async {
    final container = await openEditor(tester);
    final pending = EditorTestImageCompleter();
    await chooseCopy(tester, pending);
    await tester.tap(find.byKey(const Key('editor-cancel-export')));
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider).isApplyingEdits, isFalse);
    expect(container.read(editorStateProvider).rotationAngle, -90);
    expect(pending.isObserved, isFalse);
    expect(find.byType(EditImagePage), findsOneWidget);
    verifyNever(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    );
    expect(applyEditsCalls, 0);
    final retry = EditorTestImageCompleter();
    await chooseCopy(tester, retry);
    expect(retry.isObserved, isTrue);
    await tester.tap(find.byKey(const Key('editor-cancel-export')));
    await tester.pumpAndSettle();
  });
  testWidgets('repeated Save copy activation starts only one export without opening a dialog', (tester) async {
    final container = await openEditor(tester);
    final pending = EditorTestImageCompleter();
    imageProvider.sources.add(pending);
    final onSave = tester.widget<TextButton>(save).onPressed!;
    onSave();
    onSave();
    await tester.pump(const Duration(milliseconds: 350));
    expect(pending.isObserved, isTrue);
    expect(container.read(editorStateProvider).isApplyingEdits, isTrue);
    expect(find.byKey(const Key('edit-save-mode-dialog')), findsNothing);
    expect(find.byKey(const Key('edit-replace-original')), findsNothing);
    expect(find.byKey(const Key('edit-save-copy')), findsNothing);
    await tester.tap(find.byKey(const Key('editor-cancel-export')));
    await tester.pumpAndSettle();
    expect(pending.isObserved, isFalse);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
    verifyNever(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    );
    expect(applyEditsCalls, 0);
  });
  testWidgets('denied native photo save preserves edits and retries as a new copy with no server mutation', (
    tester,
  ) async {
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('foto-editor-permission-')))!;
    addTearDown(() => directory.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final source = (await tester.runAsync(createEditorRaster))!;
    addTearDown(source.dispose);
    var attempts = 0;
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) async => ++attempts == 1 ? null : _MockAssetEntity());
    final container = await openEditor(tester);
    await chooseCopy(tester, EditorTestImageCompleter()..emitImage(ImageInfo(image: source.clone())));
    for (var i = 0; i < 100 && container.read(editorStateProvider).isApplyingEdits; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(attempts, 1);
    expect(container.read(editorStateProvider).hasEdits, isTrue);
    expect(container.read(editorStateProvider).rotationAngle, -90);
    expect(directory.listSync(), isEmpty);
    expect(find.byType(EditImagePage), findsOneWidget);
    expect(applyEditsCalls, 0);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await chooseCopy(tester, EditorTestImageCompleter()..emitImage(ImageInfo(image: source.clone())));
    await finishCopy(tester);
    expect(attempts, 2);
    expect(directory.listSync(), isEmpty);
    expect(applyEditsCalls, 0);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
