import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext context;
  late TimelineRepository repository;

  setUpAll(() => initializeDateFormatting('en_US'));
  setUp(() {
    context = MediumRepositoryContext();
    repository = TimelineRepository(context.db);
  });
  tearDown(() => context.dispose());

  test('selected place narrows bucket and assets by exact source country and region', () async {
    final owner = await context.newUser();
    final places = <Place>[];
    for (final scope in [
      ('Moscow', 'Russia'),
      ('Leningrad Oblast', 'Russia'),
      ('Moscow', 'Other country'),
      (null, null),
      ('', null),
    ]) {
      final asset = await context.newRemoteAsset(ownerId: owner.id, createdAt: DateTime(2026, 10, 26));
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
      places.add(Place(name: 'Annino', assetId: asset.id, state: scope.$1, country: scope.$2));
    }
    for (final place in places) {
      final query = repository.place('Annino', [owner.id], owner.id, GroupAssetsBy.day, selectedPlace: place);
      final buckets = await query.bucketSource().first;
      final assets = await query.assetSource(0, 100);
      expect(buckets, hasLength(1));
      expect((buckets.single as TimeBucket).assetCount, 1);
      expect(assets.map((asset) => (asset as RemoteAsset).id), [place.assetId]);
      expect(place.hasCoordinates, isFalse, reason: 'Saved place detail needs no device/GPS permission');
    }
    final legacy = repository.place('Annino', [owner.id], owner.id, GroupAssetsBy.day);
    final buckets = await legacy.bucketSource().first;
    expect((buckets.single as TimeBucket).assetCount, 5);
    expect(await legacy.assetSource(0, 100), hasLength(5));
  });

  test('mismatched selected context fails closed in both queries', () async {
    final owner = await context.newUser();
    final asset = await context.newRemoteAsset(ownerId: owner.id);
    await context.db
        .into(context.db.remoteExifEntity)
        .insert(
          RemoteExifEntityCompanion.insert(
            assetId: asset.id,
            city: const Value('Annino'),
            state: const Value('Moscow'),
            country: const Value('Russia'),
          ),
        );
    final query = repository.place(
      'Belek',
      [owner.id],
      owner.id,
      GroupAssetsBy.day,
      selectedPlace: Place(name: 'Annino', assetId: asset.id, state: 'Moscow', country: 'Russia'),
    );
    expect(await query.bucketSource().first, isEmpty);
    expect(await query.assetSource(0, 100), isEmpty);
  });

  test('source region update invalidates the selected group rather than leaking another place', () async {
    final owner = await context.newUser();
    final asset = await context.newRemoteAsset(ownerId: owner.id);
    await context.db
        .into(context.db.remoteExifEntity)
        .insert(
          RemoteExifEntityCompanion.insert(
            assetId: asset.id,
            city: const Value('Annino'),
            state: const Value('Moscow'),
            country: const Value('Russia'),
          ),
        );
    final query = repository.place(
      'Annino',
      [owner.id],
      owner.id,
      GroupAssetsBy.day,
      selectedPlace: Place(name: 'Annino', assetId: asset.id, state: 'Moscow', country: 'Russia'),
    );
    final emissions = StreamIterator(query.bucketSource());
    addTearDown(emissions.cancel);
    expect(await emissions.moveNext(), isTrue);
    expect(emissions.current, hasLength(1));
    final next = emissions.moveNext().timeout(const Duration(seconds: 2));
    await (context.db.update(context.db.remoteExifEntity)..where((row) => row.assetId.equals(asset.id))).write(
      const RemoteExifEntityCompanion(state: Value('Leningrad Oblast')),
    );
    expect(await next, isTrue);
    expect(emissions.current, isEmpty);
    expect(await query.assetSource(0, 100), isEmpty);
  });
}
