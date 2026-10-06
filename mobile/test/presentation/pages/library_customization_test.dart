import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/library_card.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/providers/library/library_layout.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';

class _ServerService extends Mock implements ServerInfoService {}

class _Prefs implements LibraryLayoutPrefs {
  LibraryLayoutPreferences value;
  _Prefs(this.value);
  @override
  LibraryLayoutPreferences load(LibraryLayoutScope scope) => value;
  @override
  Future<void> save(LibraryLayoutScope scope, LibraryLayoutPreferences preferences) async => value = preferences;
}

LibraryLayoutPreferences _layout(Set<String> visible) =>
    LibraryLayoutPreferences(orderedIds: LibraryLayoutPreferences.defaults().orderedIds, visibleIds: visible);

Future<void> _pump(WidgetTester tester, Widget child, _Prefs prefs, {VoidCallback? peopleRequested}) async {
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: ProviderScope(
        overrides: [
          libraryLayoutScopeProvider.overrideWithValue(
            const LibraryLayoutScope(serverId: 'https://photos.example', userId: 'owner'),
          ),
          libraryLayoutPrefsProvider.overrideWithValue(prefs),
          serverInfoProvider.overrideWith((ref) => ServerInfoNotifier(_ServerService())),
          getAllPeopleProvider(PeopleSortBy.photoCount).overrideWith((ref) {
            peopleRequested?.call();
            return Stream.value([]);
          }),
        ],
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('all declarative actions retain their production destinations', () {
    final expected = <LibraryCardAction, String>{
      LibraryCardAction.favorites: FavoriteRoute.name,
      LibraryCardAction.archive: ArchiveRoute.name,
      LibraryCardAction.sharedLinks: SharedLinkRoute.name,
      LibraryCardAction.trash: TrashRoute.name,
      LibraryCardAction.spaces: SpacesRoute.name,
      LibraryCardAction.people: PeopleCollectionRoute.name,
      LibraryCardAction.places: PlaceRoute.name,
      LibraryCardAction.onDevice: LocalAlbumsRoute.name,
      LibraryCardAction.albums: AlbumsRoute.name,
      LibraryCardAction.memories: MemoryListRoute.name,
      LibraryCardAction.folders: FolderRoute.name,
      LibraryCardAction.lockedFolder: LockedFolderRoute.name,
      LibraryCardAction.partners: PartnerRoute.name,
      LibraryCardAction.recentlyAdded: RecentlyAddedRoute.name,
      LibraryCardAction.videos: VideoRoute.name,
      LibraryCardAction.livePhotos: LivePhotosRoute.name,
    };
    expect(expected.keys, unorderedEquals(LibraryCardAction.values));
    for (final card in libraryCardRegistry) {
      expect(libraryCardRoute(card.action).routeName, expected[card.action]);
    }
  });

  test('dense rows preserve arbitrary interleaved order and pack hidden entries out', () {
    final layout = LibraryLayoutPreferences.defaults()
        .setVisible('people', false)
        .setVisible('trash', false)
        .reorder(8, 0);
    final cards = layout.visibleCards();
    for (final columns in [2, 4]) {
      final rows = libraryCardRows(cards, columns);
      expect(rows.expand((row) => row), cards);
      expect(rows.every((row) => row.isNotEmpty && row.length <= columns), isTrue);
      expect(rows.every((row) => row.every((card) => card.presentation == row.first.presentation)), isTrue);
    }
  });

  testWidgets('hidden People does not request face data; remaining single card fills width', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      const CustomScrollView(slivers: [LibraryCardsSliver()]),
      _Prefs(_layout({'favorites'})),
      peopleRequested: () => requests++,
    );
    expect(requests, 0);
    expect(find.byKey(const ValueKey('library-card-people')), findsNothing);
    final tile = tester.getRect(find.byKey(const ValueKey('library-card-favorites')));
    expect(tile.left, 16);
    expect(tile.right, tester.view.physicalSize.width / tester.view.devicePixelRatio - 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two action cards fill a phone row and trailing card also fills its row', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      const CustomScrollView(slivers: [LibraryCardsSliver()]),
      _Prefs(_layout({'favorites', 'archive', 'sharedLinks'})),
    );
    final a = tester.getRect(find.byKey(const ValueKey('library-card-favorites')));
    final b = tester.getRect(find.byKey(const ValueKey('library-card-archive')));
    final c = tester.getRect(find.byKey(const ValueKey('library-card-sharedLinks')));
    expect(a.top, b.top);
    expect(b.left - a.right, 8);
    expect(a.width + b.width + 8, 368);
    expect(c.width, 368);
    expect(c.top, greaterThan(a.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet row packs four available actions without holes', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      const CustomScrollView(slivers: [LibraryCardsSliver()]),
      _Prefs(_layout({'favorites', 'archive', 'sharedLinks', 'trash'})),
    );
    final rects = [
      'favorites',
      'archive',
      'sharedLinks',
      'trash',
    ].map((id) => tester.getRect(find.byKey(ValueKey('library-card-$id')))).toList();
    expect(rects.map((rect) => rect.top).toSet(), hasLength(1));
    expect(rects.fold<double>(0, (total, rect) => total + rect.width) + 24, 868);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all hidden cards produce an intentional empty state', (tester) async {
    await _pump(tester, const CustomScrollView(slivers: [LibraryCardsSliver()]), _Prefs(_layout({})));
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Choose cards to show in your library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor restores a hidden card, changes order and resets current defaults', (tester) async {
    final prefs = _Prefs(_layout({}));
    await _pump(tester, const LibraryCustomizationSheet(), prefs);
    final favorite = find.byKey(const ValueKey('library-visible-favorites'));
    expect(tester.widget<Switch>(favorite).value, isFalse);
    await tester.tap(favorite);
    await tester.pumpAndSettle();
    expect(prefs.value.isVisible('favorites'), isTrue);
    final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();
    expect(prefs.value.orderedIds.take(3), ['archive', 'sharedLinks', 'favorites']);
    await tester.tap(find.byKey(const Key('library-reset')));
    await tester.pumpAndSettle();
    expect(prefs.value.visibleIds, LibraryLayoutPreferences.defaults().visibleIds);
    expect(prefs.value.orderedIds, LibraryLayoutPreferences.defaults().orderedIds);
    expect(tester.takeException(), isNull);
  });
}
