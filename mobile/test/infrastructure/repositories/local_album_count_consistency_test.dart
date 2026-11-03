import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;

  setUp(() => ctx = MediumRepositoryContext());
  tearDown(() => ctx.dispose());

  test('orphan album links cannot produce Serv 3 while its actual timeline has zero assets', () async {
    await ctx.newLocalAlbum(id: 'serv', name: 'Serv');
    // Simulate a legacy cache with broken foreign-key links. Do not repair or
    // delete them: counting must agree with the joined Timeline on read alone.
    await ctx.db.customStatement('PRAGMA foreign_keys = OFF');
    for (var index = 1; index <= 3; index++) {
      await ctx.newLocalAlbumAsset(albumId: 'serv', assetId: 'missing-$index');
    }
    await ctx.db.customStatement('PRAGMA foreign_keys = ON');

    final albums = await ctx.db.localAlbumRepository.getAll();
    final timeline = TimelineRepository(ctx.db).localAlbum('serv', GroupAssetsBy.none);

    expect(await timeline.bucketSource().first, isEmpty);
    expect(await timeline.assetSource(0, 20), isEmpty);
    expect(albums.single.assetCount, 0);
    expect(await ctx.db.localAlbumRepository.getAssetIds('serv'), hasLength(3));
    expect(await ctx.db.localAlbumRepository.getThumbnail('serv'), isNull);
  });

  test('actual assets count once and thumbnail ties have a stable asset ID order', () async {
    await ctx.newLocalAlbum(id: 'serv');
    await ctx.newLocalAlbum(id: 'empty');
    for (final id in ['b', 'a']) {
      await ctx.newLocalAsset(id: id, createdAt: DateTime.utc(2026, 11, 3));
      await ctx.newLocalAlbumAsset(albumId: 'serv', assetId: id);
    }

    final albums = {for (final album in await ctx.db.localAlbumRepository.getAll()) album.id: album};

    expect(albums['serv']?.assetCount, 2);
    expect(albums['empty']?.assetCount, 0);
    expect((await ctx.db.localAlbumRepository.getThumbnail('serv'))?.id, 'a');
  });
}
