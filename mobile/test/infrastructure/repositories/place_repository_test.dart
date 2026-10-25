import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext context;
  late RemoteAssetRepository repository;

  setUp(() {
    context = MediumRepositoryContext();
    repository = RemoteAssetRepository(context.db);
  });

  tearDown(() => context.dispose());

  test('place metadata and preview come from the same newest eligible photo', () async {
    final owner = await context.newUser();
    final old = await context.newRemoteAsset(ownerId: owner.id, createdAt: DateTime(2025));
    final recent = await context.newRemoteAsset(ownerId: owner.id, createdAt: DateTime(2026));
    for (final asset in [old, recent]) {
      await context.db
          .into(context.db.remoteExifEntity)
          .insert(
            RemoteExifEntityCompanion.insert(
              assetId: asset.id,
              city: const Value('Moscow'),
              country: const Value('Russia'),
              latitude: Value(asset == recent ? 55.75 : 55.8),
              longitude: const Value(37.62),
            ),
          );
    }
    final places = await repository.getPlaceDetails(owner.id);
    expect(places, hasLength(1));
    expect(places.single.name, 'Moscow');
    expect(places.single.assetId, recent.id);
    expect(places.single.latitude, 55.75);
    expect(places.single.country, 'Russia');
    expect(await repository.getPlaces(owner.id), [('Moscow', recent.id)]);
    final exif = await repository.getExif(recent.id);
    expect(exif!.city, 'Moscow');
    expect(exif.latitude, 55.75);
  });

  test('places retain manual city without GPS and exclude trashed hidden or other-owner photos', () async {
    final owner = await context.newUser();
    final otherOwner = await context.newUser();
    final manual = await context.newRemoteAsset(ownerId: owner.id);
    final noCity = await context.newRemoteAsset(ownerId: owner.id);
    final deleted = await context.newRemoteAsset(ownerId: owner.id, deletedAt: DateTime(2026));
    final hidden = await context.newRemoteAsset(ownerId: owner.id, visibility: AssetVisibility.hidden);
    final theirs = await context.newRemoteAsset(ownerId: otherOwner.id);
    for (final asset in [manual, noCity, deleted, hidden, theirs]) {
      await context.db
          .into(context.db.remoteExifEntity)
          .insert(
            RemoteExifEntityCompanion.insert(
              assetId: asset.id,
              city: Value(
                asset == manual
                    ? 'Немчиновка'
                    : asset == noCity
                    ? null
                    : 'Moscow',
              ),
            ),
          );
    }
    final places = await repository.getPlaceDetails(owner.id);
    expect(places, hasLength(1));
    expect(places.single.name, 'Немчиновка');
    expect(places.single.hasCoordinates, isFalse);
    expect(places.single.assetId, manual.id);
  });
}
