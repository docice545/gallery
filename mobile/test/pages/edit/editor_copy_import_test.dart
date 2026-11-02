import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/edited_copy.service.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../fixtures/editor_image_stream.dart';
import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _MockFileMediaRepository extends Mock implements FileMediaRepository {}

class _MockEditedCopyService extends Mock implements EditedCopyService {}

class _MockBackgroundSyncManager extends Mock implements BackgroundSyncManager {}

final _activeImporterProvider = StateProvider<EditedCopyService>((_) => throw UnimplementedError());

void main() {
  final savedCopy = AssetEntity(id: 'new-device-copy', typeInt: 1, width: 48, height: 64);
  final save = find.byKey(const Key('editor-save'));
  late _MockFileMediaRepository media;
  late _MockEditedCopyService importer;
  late _MockBackgroundSyncManager background;
  late EditorTestImageProvider imageProvider;
  late Directory directory;
  late ui.Image source;

  setUp(() {
    TestUtils.init();
    media = _MockFileMediaRepository();
    importer = _MockEditedCopyService();
    background = _MockBackgroundSyncManager();
    imageProvider = EditorTestImageProvider();
  });

  Future<ProviderContainer> openEditor(WidgetTester tester) async {
    directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('foto-copy-import-')))!;
    source = (await tester.runAsync(createEditorRaster))!;
    addTearDown(source.dispose);
    addTearDown(() => directory.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    await tester.runAsync(() async {
      await tester.pumpConsumerWidgetRaw(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EditImagePage(
                    image: Image(image: imageProvider),
                    applyEdits: (_) async {},
                  ),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
        overrides: [
          fileMediaRepositoryProvider.overrideWithValue(media),
          _activeImporterProvider.overrideWith((_) => importer),
          editedCopyServiceProvider.overrideWith((ref) => ref.watch(_activeImporterProvider)),
          backgroundSyncProvider.overrideWithValue(background),
          immichThemeProvider.overrideWith(
            (_) => ImmichTheme(
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

  void stubNative(Future<AssetEntity?> Function() answer) {
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: 'DCIM/Noodle Gallery',
        preserveCreatedAssetOnFailure: true,
      ),
    ).thenAnswer((_) => answer());
  }

  void verifySingleFileWrite() {
    verify(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: 'DCIM/Noodle Gallery',
        preserveCreatedAssetOnFailure: true,
      ),
    ).called(1);
    verifyNever(() => background.syncLocal(full: any(named: 'full')));
  }

  Future<void> startSave(WidgetTester tester) async {
    imageProvider.sources.add(EditorTestImageCompleter()..emitImage(ImageInfo(image: source.clone())));
    await tester.tap(save);
    await tester.pump();
  }

  Future<void> advanceUntil(WidgetTester tester, bool Function() condition) async {
    for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(condition(), isTrue);
  }

  Future<void> settleToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('success waits for exact-ID import, without awaiting an unrelated full local sync', (tester) async {
    final pendingImport = Completer<void>();
    var importCalls = 0;
    when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) {
      importCalls++;
      return pendingImport.future;
    });
    // A full device scan may already be running. The save path must not join it.
    final unrelatedScan = Completer<void>();
    when(() => background.syncLocal(full: any(named: 'full'))).thenAnswer((_) => unrelatedScan.future);
    stubNative(() async => savedCopy);
    final container = await openEditor(tester);
    final repeatSave = tester.widget<TextButton>(save).onPressed!;
    await startSave(tester);
    await advanceUntil(tester, () => importCalls == 1);
    repeatSave();
    await tester.pump();
    expect(importCalls, 1);
    expect(find.byType(EditImagePage), findsOneWidget);
    expect(container.read(editorStateProvider).isApplyingEdits, isTrue);
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const Key('editor-header-undo'))).onPressed, isNull);
    expect(find.byKey(const Key('editor-cancel-export')), findsNothing);
    pendingImport.complete();
    await advanceUntil(tester, () => find.byType(EditImagePage).evaluate().isEmpty);
    expect(unrelatedScan.isCompleted, isFalse);
    expect(directory.listSync(), isEmpty);
    verifySingleFileWrite();
    verify(() => importer.importSavedCopy(savedCopy)).called(1);
    expect(tester.takeException(), isNull);
    await settleToasts(tester);
  });

  testWidgets('two failed imports retry the same saved ID without rendering or writing another copy', (tester) async {
    var importCalls = 0;
    when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) async {
      if (++importCalls <= 2) {
        throw StateError('Drift temporarily unavailable');
      }
    });
    stubNative(() async => savedCopy);
    final container = await openEditor(tester);
    await startSave(tester);
    await advanceUntil(tester, () => importCalls == 1 && !container.read(editorStateProvider).isApplyingEdits);
    expect(find.byType(EditImagePage), findsOneWidget);
    expect(find.text('Retry'), findsWidgets);
    expect(container.read(editorStateProvider).rotationAngle, -90);
    expect(tester.widget<IconButton>(find.byKey(const Key('editor-header-undo'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const Key('editor-back'))).onPressed, isNotNull);
    expect(find.textContaining('Could not save a copy.'), findsNothing);
    expect(find.text(tester.element(find.byType(EditImagePage)).t.editor_copy_saved_import_pending), findsOneWidget);
    expect(directory.listSync(), isEmpty);
    await settleToasts(tester);
    // No additional image source is supplied: retry must not re-render the file.
    await tester.tap(save);
    await advanceUntil(tester, () => importCalls == 2 && !container.read(editorStateProvider).isApplyingEdits);
    expect(container.read(editorStateProvider).rotationAngle, -90);
    await settleToasts(tester);
    await tester.tap(save);
    await advanceUntil(tester, () => find.byType(EditImagePage).evaluate().isEmpty);
    verifySingleFileWrite();
    verify(() => importer.importSavedCopy(savedCopy)).called(3);
    expect(directory.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
    await settleToasts(tester);
  });

  testWidgets('metadata failure hands the created ID to the durable importer without a second file', (tester) async {
    stubNative(() async => throw SavedMediaImportException(savedCopy, StateError('MIME write failed')));
    var importCalls = 0;
    when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) async {
      if (++importCalls <= 2) {
        throw StateError('Metadata completion temporarily unavailable');
      }
    });
    final container = await openEditor(tester);
    await startSave(tester);
    await advanceUntil(tester, () => importCalls == 1 && !container.read(editorStateProvider).isApplyingEdits);
    expect(find.textContaining('Could not save a copy.'), findsNothing);
    await settleToasts(tester);
    await tester.tap(save);
    await advanceUntil(tester, () => importCalls == 2 && !container.read(editorStateProvider).isApplyingEdits);
    await settleToasts(tester);
    await tester.tap(save);
    await advanceUntil(tester, () => find.byType(EditImagePage).evaluate().isEmpty);
    verifySingleFileWrite();
    // Metadata completion belongs to the durable importer, after persisting ID.
    verifyNever(() => media.completeImageImport(savedCopy, mimeType: 'image/png'));
    verify(() => importer.importSavedCopy(savedCopy)).called(3);
    expect(directory.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
    await settleToasts(tester);
  });

  testWidgets('retry retains the original account-scoped importer after its provider changes', (tester) async {
    final replacement = _MockEditedCopyService();
    var importCalls = 0;
    stubNative(() async => savedCopy);
    when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) async {
      importCalls++;
      throw StateError('Original account scope cannot import yet');
    });
    final container = await openEditor(tester);
    await startSave(tester);
    await advanceUntil(tester, () => importCalls == 1 && !container.read(editorStateProvider).isApplyingEdits);
    container.read(_activeImporterProvider.notifier).state = replacement;
    await settleToasts(tester);
    await tester.tap(save);
    await advanceUntil(tester, () => importCalls == 2 && !container.read(editorStateProvider).isApplyingEdits);
    verify(() => importer.importSavedCopy(savedCopy)).called(2);
    verifyNever(() => replacement.importSavedCopy(savedCopy));
    verifySingleFileWrite();
    expect(find.byType(EditImagePage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await settleToasts(tester);
  });

  for (final metadataFailure in [false, true]) {
    testWidgets(
      'late native ${metadataFailure ? 'metadata failure' : 'completion'} hands the copy to the importer after unmount',
      (tester) async {
        final nativeSave = Completer<AssetEntity?>();
        var nativeCalls = 0;
        var importCalls = 0;
        stubNative(() {
          nativeCalls++;
          return nativeSave.future;
        });
        when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) async {
          importCalls++;
        });
        await openEditor(tester);
        await startSave(tester);
        await advanceUntil(tester, () => nativeCalls == 1);
        final navigator = Navigator.of(tester.element(find.byType(EditImagePage)));
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.byType(EditImagePage), findsNothing);
        if (metadataFailure) {
          nativeSave.completeError(SavedMediaImportException(savedCopy, StateError('MIME write failed')));
        } else {
          nativeSave.complete(savedCopy);
        }
        await advanceUntil(tester, () => importCalls == 1 && directory.listSync().isEmpty);
        verifySingleFileWrite();
        expect(find.text('Open editor'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('editor disposal during import does not access disposed WidgetRef or duplicate the saved file', (
    tester,
  ) async {
    final pendingImport = Completer<void>();
    var importCalls = 0;
    stubNative(() async => savedCopy);
    when(() => importer.importSavedCopy(savedCopy)).thenAnswer((_) {
      importCalls++;
      return pendingImport.future;
    });
    await openEditor(tester);
    await startSave(tester);
    await advanceUntil(tester, () => importCalls == 1);
    Navigator.of(tester.element(find.byType(EditImagePage))).pop();
    await tester.pumpAndSettle();
    pendingImport.complete();
    await advanceUntil(tester, () => directory.listSync().isEmpty);
    verifySingleFileWrite();
    verify(() => importer.importSavedCopy(savedCopy)).called(1);
    expect(find.text('Open editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
