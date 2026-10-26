import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext context;
  late MapRepository repository;

  setUp(() {
    context = MediumRepositoryContext();
    repository = MapRepository(context.db);
  });
  tearDown(() => context.dispose());

  Future<String> photo(
    String owner,
    DateTime date, {
    double? lat,
    double? lng,
    DateTime? deletedAt,
    AssetVisibility visibility = AssetVisibility.timeline,
  }) async {
    final asset = await context.newRemoteAsset(
      ownerId: owner,
      createdAt: date,
      deletedAt: deletedAt,
      visibility: visibility,
    );
    await context.db
        .into(context.db.remoteExifEntity)
        .insert(RemoteExifEntityCompanion.insert(assetId: asset.id, latitude: Value(lat), longitude: Value(lng)));
    return asset.id;
  }

  test('first viewport is newest real library photo, independent of city metadata', () async {
    final owner = await context.newUser();
    await photo(owner.id, DateTime(2024), lat: 21.3, lng: -157.8);
    await photo(owner.id, DateTime(2025), lat: 55.75, lng: 37.62);
    expect(await repository.getInitialLocation(owner.id), const LatLng(55.75, 37.62));
    expect((await context.db.remoteExifEntity.select().get()).every((exif) => exif.city == null), isTrue);
  });

  test('other owners, trashed, hidden, archived and invalid/missing GPS cannot select the viewport', () async {
    final owner = await context.newUser();
    final other = await context.newUser();
    await photo(owner.id, DateTime(2025), lat: -33.8, lng: 151.2);
    await photo(other.id, DateTime(2026), lat: 21.3, lng: -157.8);
    await photo(owner.id, DateTime(2026), lat: 21.3, lng: -157.8, deletedAt: DateTime(2026));
    await photo(owner.id, DateTime(2026), lat: 21.3, lng: -157.8, visibility: AssetVisibility.hidden);
    await photo(owner.id, DateTime(2026), lat: 21.3, lng: -157.8, visibility: AssetVisibility.archive);
    await photo(owner.id, DateTime(2026), lat: 91, lng: 37);
    await photo(owner.id, DateTime(2026), lat: 55, lng: 181);
    await photo(owner.id, DateTime(2026), lat: 55);
    await photo(owner.id, DateTime(2026));
    expect(await repository.getInitialLocation(owner.id), const LatLng(-33.8, 151.2));
    final exif = await context.db.remoteExifEntity.select().get();
    expect(exif.any((row) => row.latitude == 91), isTrue);
    expect(exif.any((row) => row.longitude == 181), isTrue);
  });

  test('empty/no-GPS library has no fabricated anchor; valid zero and date-line coordinates are retained', () async {
    final owner = await context.newUser();
    expect(await repository.getInitialLocation(owner.id), isNull);
    await photo(owner.id, DateTime(2024));
    expect(await repository.getInitialLocation(owner.id), isNull);
    await photo(owner.id, DateTime(2025), lat: 0, lng: 0);
    expect(await repository.getInitialLocation(owner.id), const LatLng(0, 0));
    await photo(owner.id, DateTime(2026), lat: -10, lng: 179.99);
    expect(await repository.getInitialLocation(owner.id), const LatLng(-10, 179.99));
  });
}
