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

  test('same-name places retain their own region, country, latest preview and GPS anchor', () async {
    final owner = await context.newUser();
    final records = [
      (state: 'Moscow', country: 'Russia', lat: 55.5, date: DateTime(2024)),
      (state: 'Moscow', country: 'Russia', lat: 55.6, date: DateTime(2027)),
      (state: 'Leningrad Oblast', country: 'Russia', lat: 59.8, date: DateTime(2026)),
      (state: 'Moscow', country: 'Other country', lat: 40.0, date: DateTime(2025)),
    ];
    final ids = <String>[];
    for (final record in records) {
      final asset = await context.newRemoteAsset(ownerId: owner.id, createdAt: record.date);
      ids.add(asset.id);
      await context.db
          .into(context.db.remoteExifEntity)
          .insert(
            RemoteExifEntityCompanion.insert(
              assetId: asset.id,
              city: const Value('Annino'),
              state: Value(record.state),
              country: Value(record.country),
              latitude: Value(record.lat),
              longitude: const Value(37.6),
            ),
          );
    }
    final places = await repository.getPlaceDetails(owner.id);
    expect(places, hasLength(3));
    final moscow = places.singleWhere((place) => place.state == 'Moscow' && place.country == 'Russia');
    expect(moscow.assetId, ids[1]);
    expect(moscow.latitude, 55.6);
    expect(places.singleWhere((place) => place.state == 'Leningrad Oblast').assetId, ids[2]);
    expect(places.singleWhere((place) => place.country == 'Other country').assetId, ids[3]);
    // Old clients still receive one city and its newest photo, not a fabricated
    // geographic ID or a preview selected by alphabetical region order.
    expect(await repository.getPlaces(owner.id), [('Annino', ids[1])]);
    final original = await repository.getExif(ids[1]);
    expect(original!.city, 'Annino');
    expect(original.state, 'Moscow');
    expect(original.country, 'Russia');
    expect(original.latitude, 55.6);
  });

  test('unknown region and country remain distinct from known values without requiring GPS', () async {
    final owner = await context.newUser();
    for (final scope in [(null, null), ('', null), ('Moscow', null), ('Moscow', 'Russia')]) {
      final asset = await context.newRemoteAsset(ownerId: owner.id);
      await context.db
          .into(context.db.remoteExifEntity)
          .insert(
            RemoteExifEntityCompanion.insert(
              assetId: asset.id,
              city: const Value('Annino'),
              state: Value(scope.$1),
              country: Value(scope.$2),
            ),
          );
    }
    final places = await repository.getPlaceDetails(owner.id);
    expect(places, hasLength(4));
    expect(places.map((place) => place.scopeIdentity).toSet(), hasLength(4));
    expect(places.every((place) => !place.hasCoordinates), isTrue);
  });
}
