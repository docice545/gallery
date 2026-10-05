import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/table/people/asset_face.drift.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';

import '../../medium/repository_context.dart';

class _NoHttp extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Face framing must use the synchronized local database');
  }
}

void main() {
  late MediumRepositoryContext ctx;
  late ProviderContainer container;
  late _NoHttp http;
  late HttpOverrides? previousHttp;
  late String assetId;

  setUp(() async {
    previousHttp = HttpOverrides.current;
    http = _NoHttp();
    HttpOverrides.global = http;
    ctx = MediumRepositoryContext();
    final user = await ctx.newUser();
    assetId = (await ctx.newRemoteAsset(ownerId: user.id)).id;
    container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(ctx.db),
        apiServiceProvider.overrideWith((_) => throw StateError('Face framing must not resolve an API service')),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await ctx.dispose();
    HttpOverrides.global = previousHttp;
    expect(http.attempts, 0);
  });

  Future<void> insertFace(
    String id, {
    String? onAsset,
    int imageWidth = 1000,
    int imageHeight = 2000,
    bool visible = true,
    DateTime? deletedAt,
  }) => ctx.db
      .into(ctx.db.assetFaceEntity)
      .insert(
        AssetFaceEntityCompanion.insert(
          id: id,
          assetId: onAsset ?? assetId,
          personId: const Value(null),
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          boundingBoxX1: 200,
          boundingBoxY1: 100,
          boundingBoxX2: 500,
          boundingBoxY2: 600,
          sourceType: 'machine-learning',
          isVisible: Value(visible),
          deletedAt: Value(deletedAt),
        ),
      )
      .then((_) {});

  test('normalizes unassigned visible faces using their source dimensions and isolates the requested asset', () async {
    final user = await ctx.newUser();
    final otherAsset = await ctx.newRemoteAsset(ownerId: user.id);
    await insertFace('unassigned');
    await insertFace('other-asset', onAsset: otherAsset.id);
    await insertFace('invisible', visible: false);
    await insertFace('deleted', deletedAt: DateTime(2026, 10, 5));
    await insertFace('invalid-width', imageWidth: 0);
    await insertFace('invalid-height', imageHeight: -1);
    final provider = thumbnailFaceBoundsProvider(assetId);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    expect(await container.read(provider.future), const [Rect.fromLTRB(0.2, 0.05, 0.5, 0.3)]);
    expect(container.exists(apiServiceProvider), isFalse);
    expect(http.attempts, 0);
  });

  test('bounding boxes, visibility and deletion re-emit through the real Drift stream without invalidation', () async {
    await insertFace('reactive');
    final provider = thumbnailFaceBoundsProvider(assetId);
    final values = <List<Rect>>[];
    final subscription = container.listen(provider, (_, next) {
      final faces = next.valueOrNull;
      if (faces != null) {
        values.add(faces);
      }
    });
    addTearDown(subscription.close);
    expect(await container.read(provider.future), const [Rect.fromLTRB(0.2, 0.05, 0.5, 0.3)]);

    Future<void> update(AssetFaceEntityCompanion change) async {
      await (ctx.db.update(ctx.db.assetFaceEntity)..where((row) => row.id.equals('reactive'))).write(change);
      await pumpEventQueue();
    }

    await update(const AssetFaceEntityCompanion(boundingBoxY1: Value(1200), boundingBoxY2: Value(1800)));
    expect(values.last, const [Rect.fromLTRB(0.2, 0.6, 0.5, 0.9)]);
    await update(const AssetFaceEntityCompanion(isVisible: Value(false)));
    expect(values.last, isEmpty);
    await update(const AssetFaceEntityCompanion(isVisible: Value(true)));
    expect(values.last, const [Rect.fromLTRB(0.2, 0.6, 0.5, 0.9)]);
    await update(AssetFaceEntityCompanion(deletedAt: Value(DateTime(2026, 10, 5))));
    expect(values.last, isEmpty);
    await update(const AssetFaceEntityCompanion(deletedAt: Value(null)));
    expect(values.last, const [Rect.fromLTRB(0.2, 0.6, 0.5, 0.9)]);
    await (ctx.db.delete(ctx.db.assetFaceEntity)..where((row) => row.id.equals('reactive'))).go();
    await pumpEventQueue();
    expect(values.last, isEmpty);
    expect(container.exists(apiServiceProvider), isFalse);
  });

  test('closing the visible tile subscription disposes the provider and a later tile reads fresh local data', () async {
    await insertFace('released');
    final provider = thumbnailFaceBoundsProvider(assetId);
    final subscription = container.listen(provider, (_, _) {});
    await container.read(provider.future);
    expect(container.exists(provider), isTrue);
    subscription.close();
    await pumpEventQueue();
    expect(container.exists(provider), isFalse);

    await (ctx.db.update(ctx.db.assetFaceEntity)..where((row) => row.id.equals('released'))).write(
      const AssetFaceEntityCompanion(boundingBoxX1: Value(400), boundingBoxX2: Value(700)),
    );
    final remounted = container.listen(provider, (_, _) {});
    addTearDown(remounted.close);
    expect(await container.read(provider.future), const [Rect.fromLTRB(0.4, 0.05, 0.7, 0.3)]);
  });
}
