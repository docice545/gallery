import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _DelayedImage extends ImageProvider<_DelayedImage> {
  final frame = Completer<ImageInfo>();
  @override
  Future<_DelayedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_DelayedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(frame.future);
}

void main() {
  testWidgets('first decode retains Hero state and contained geometry instead of replacing it', (tester) async {
    final image = _DelayedImage();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 360,
            height: 640,
            child: PhotoView(
              imageProvider: image,
              index: 0,
              heroAttributes: const PhotoViewHeroAttributes(tag: 'cold'),
              loadingChildSize: const Size(400, 200),
              tightMode: true,
              filterQuality: FilterQuality.high,
              loadingBuilder: (_, _, _) => const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    final hero = find.byType(Hero);
    final before = tester.state(hero);
    final rect = tester.getRect(hero);
    expect(rect.size, const Size(360, 180));
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    image.frame.complete(ImageInfo(image: picture.toImageSync(400, 200)));
    picture.dispose();
    await tester.pump();
    expect(tester.state(hero), same(before));
    expect(tester.getRect(hero), rect);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
  });

  for (final hz in [60, 90, 120]) {
    testWidgets('cold grid Hero uses one bounded thumbnail request through push/pop at $hz Hz steps', (tester) async {
      final context = await PresentationContext.create();
      addTearDown(context.dispose);
      final requests = <List<Object?>>[];
      const channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
        LocalImageApi.pigeonChannelCodec,
      );
      const cancel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
        LocalImageApi.pigeonChannelCodec,
      );
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler(channel, (args) async {
        requests.add((args! as List<Object?>).toList());
        return <Object?>[null];
      });
      messenger.setMockDecodedMessageHandler(cancel, (_) async => <Object?>[null]);
      final navigator = GlobalKey<NavigatorState>();
      final asset = LocalAssetStub.image1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: context.overrides,
          child: MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 100, height: 140, child: ThumbnailTile(asset, heroOffset: 0, fillCell: true)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(requests, hasLength(1));
      final firstRequest = requests.single;
      unawaited(
        navigator.currentState!.push(
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            pageBuilder: (_, _, _) => Scaffold(
              body: Center(
                child: Hero(
                  tag: '${asset.heroTag}_0',
                  child: const SizedBox(width: 600, height: 400, child: ColoredBox(color: Colors.blue)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final step = Duration(microseconds: (1000000 / hz).round());
      for (var i = 0; i < hz / 2; i++) {
        await tester.pump(step);
      }
      navigator.currentState!.pop();
      await tester.pump();
      for (var i = 0; i < hz / 2; i++) {
        await tester.pump(step);
      }
      // Changing flight bounds must not create new native sizes/cache keys. A
      // provider may retry an empty image once on remount, but at the same size.
      expect(requests.map((r) => r.sublist(2).toString()).toSet(), {firstRequest.sublist(2).toString()});
      expect(requests.length, lessThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      messenger.setMockDecodedMessageHandler(channel, null);
      messenger.setMockDecodedMessageHandler(cancel, null);
      PaintingBinding.instance.imageCache.clear();
    });
  }
}
