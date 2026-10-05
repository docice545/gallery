import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/common/transparent_image.dart';
import 'package:mocktail/mocktail.dart';

import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _MockMagicEraserRepository extends Mock implements MagicEraserRepository {}

void main() {
  late _MockMagicEraserRepository repository;
  late RemoteAsset asset;
  final magicEraser = find.byKey(const Key('magic-eraser-editor-action'));

  setUp(() {
    TestUtils.init();
    repository = _MockMagicEraserRepository();
    asset = TestUtils.createRemoteAsset(id: 'asset-id', width: 1, height: 1);
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => false);
  });

  Future<void> pumpEditor(WidgetTester tester, {RemoteAsset? photo, bool legacyCaller = false}) async {
    await tester.runAsync(() async {
      await tester.pumpConsumerWidgetRaw(
        EditImagePage(
          image: Image.memory(kTransparentImage),
          applyEdits: (_) async {},
          asset: legacyCaller ? null : photo ?? asset,
        ),
        overrides: [
          magicEraserRepositoryProvider.overrideWithValue(repository),
          immichThemeProvider.overrideWith(
            (ref) => ImmichTheme(
              light: ColorScheme.fromSeed(seedColor: Colors.purple),
              dark: ColorScheme.fromSeed(seedColor: Colors.purple, brightness: Brightness.dark),
            ),
          ),
        ],
      );
      // The crop package resolves native image dimensions asynchronously.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets('an older or unconfigured server disables only Magic Eraser while keeping the crop editor usable', (
    tester,
  ) async {
    await pumpEditor(tester);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.byType(CropImage), findsOneWidget);
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    expect(find.byIcon(Icons.rotate_right), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pump();
    final state = ProviderScope.containerOf(tester.element(magicEraser)).read(editorStateProvider);
    expect(state.rotationAngle, -90);
    expect(state.hasUnsavedEdits, isTrue);
  });

  testWidgets('an unavailable optional AI service leaves ordinary transform editing operational', (tester) async {
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenThrow(StateError('Offline'));

    await pumpEditor(tester);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.byType(CropImage), findsOneWidget);
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Live/Motion stills expose AI copies without enabling crop or overwrite controls', (tester) async {
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    final live = asset.copyWith(livePhotoVideoId: 'paired-video-id');

    await pumpEditor(tester, photo: live);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNotNull);
    expect(find.byType(CropImage), findsNothing);
    expect(find.byIcon(Icons.rotate_left), findsNothing);
    expect(find.byIcon(Icons.rotate_right), findsNothing);
    expect(find.byIcon(Icons.done_rounded), findsNothing);
    expect(live.isEditable, isFalse);
    expect(live.livePhotoVideoId, 'paired-video-id');
  });

  testWidgets('existing editor callers without an asset retain their original crop interface', (tester) async {
    await pumpEditor(tester, legacyCaller: true);

    expect(magicEraser, findsNothing);
    expect(find.byType(CropImage), findsOneWidget);
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    verifyNever(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')));
  });
}
