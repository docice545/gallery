import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/place.model.dart';

void main() {
  const moscow = Place(name: 'Annino', assetId: 'moscow', state: 'Moscow', country: 'Russia');
  const leningrad = Place(name: 'Annino', assetId: 'leningrad', state: 'Leningrad Oblast', country: 'Russia');
  const foreign = Place(name: 'Annino', assetId: 'foreign', state: 'Moscow', country: 'Other country');

  test('place identity preserves exact source region and country independently of label or preview', () {
    const refreshed = Place(name: 'Annino', assetId: 'new-preview', state: 'Moscow', country: 'Russia', latitude: 55.5);
    expect(moscow.scopeIdentity, refreshed.scopeIdentity);
    expect({moscow.scopeIdentity, leningrad.scopeIdentity, foreign.scopeIdentity}, hasLength(3));
    expect(moscow.sourceRegion, 'Moscow, Russia');
    expect(
      const Place(name: 'Annino', assetId: 'none').scopeIdentity,
      isNot(const Place(name: 'Annino', assetId: 'empty', state: '').scopeIdentity),
    );
  });

  test('detail selection refreshes only the selected group instead of taking the first homonym', () {
    const refreshed = Place(name: 'Annino', assetId: 'new-preview', state: 'Moscow', country: 'Russia');
    expect(Place.resolveSelection('Annino', [leningrad, foreign, refreshed], selectedPlace: moscow), refreshed);
    expect(Place.resolveSelection('Annino', [leningrad], selectedPlace: moscow), moscow);
    expect(Place.resolveSelection('Belek', [moscow], selectedPlace: moscow), isNull);
  });

  test('legacy city-only details localize unambiguous sources and retain raw title for homonyms', () {
    expect(Place.resolveSelection('Annino', [moscow]), moscow);
    expect(Place.resolveSelection('Annino', [moscow, leningrad]), isNull);
    expect(Place.resolveSelection('Belek', [moscow]), isNull);
  });
}
