import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/presentation/widgets/map/place_list_tile.widget.dart';

void main() {
  testWidgets('localized and source names wrap beside a compact photo preview at large font size', (tester) async {
    tester.view.physicalSize = const Size(280, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: [
              PlaceListTile(
                name: 'Восточное Дегунино',
                sourceName: 'Vostochnoye Degunino',
                thumbnail: const ColoredBox(key: Key('photo-preview'), color: Colors.blue),
                onTap: () {},
              ),
              PlaceListTile(
                name: 'Новая Купавна',
                sourceName: 'Novaya Kupavna',
                thumbnail: const ColoredBox(color: Colors.green),
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final thumbnail = tester.getRect(find.byKey(const Key('photo-preview')));
    final name = tester.getRect(find.text('Восточное Дегунино'));
    final source = tester.getRect(find.text('Vostochnoye Degunino'));
    final next = tester.getRect(find.text('Новая Купавна'));
    expect(thumbnail.size, const Size(64, 64));
    expect(name.left, greaterThan(thumbnail.right));
    expect(source.top, greaterThanOrEqualTo(name.bottom));
    expect(next.top, greaterThan(source.bottom));
    expect(name.right, lessThanOrEqualTo(280));
  });

  testWidgets('selecting a localized place preserves the source key and photo preview', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceListTile(
            name: 'Гонолулу',
            sourceName: 'Honolulu',
            thumbnail: const Icon(Icons.photo, key: Key('owned-preview')),
            onTap: () => selected = 'Honolulu',
          ),
        ),
      ),
    );
    await tester.tap(find.text('Гонолулу'));
    expect(selected, 'Honolulu');
    expect(find.byKey(const Key('owned-preview')), findsOneWidget);
    expect(find.text('Honolulu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unavailable translation shows a single intact source name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceListTile(name: 'Mũi Né', sourceName: 'Mũi Né', thumbnail: const Icon(Icons.photo), onTap: () {}),
        ),
      ),
    );
    expect(find.text('Mũi Né'), findsOneWidget);
    expect(find.text('Mui Ne'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same localized names retain separate region context and select their own source group', (tester) async {
    const places = [
      Place(name: 'Annino', assetId: 'moscow', state: 'Moscow', country: 'Russia'),
      Place(name: 'Annino', assetId: 'leningrad', state: 'Leningrad Oblast', country: 'Russia'),
    ];
    Place? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final place in places)
                PlaceListTile(
                  key: ValueKey(place.scopeIdentity),
                  name: 'Аннино',
                  sourceName: place.name,
                  regionName: place.sourceRegion,
                  thumbnail: const Icon(Icons.photo),
                  onTap: () => selected = place,
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Аннино'), findsNWidgets(2));
    await tester.tap(find.text('Leningrad Oblast, Russia'));
    expect(selected, places[1]);
    expect(selected!.scopeIdentity, isNot(places[0].scopeIdentity));
    expect(tester.takeException(), isNull);
  });
}
