import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/library_card.model.dart';

void main() {
  test('registry has one stable descriptor for every supported action', () {
    expect(libraryCardRegistry, hasLength(16));
    expect(libraryCardRegistry.map((card) => card.id).toSet(), hasLength(16));
    expect(libraryCardRegistry.map((card) => card.action).toSet(), LibraryCardAction.values.toSet());
    expect(libraryCardRegistry.map((card) => card.defaultOrder).toSet(), hasLength(16));
    expect(libraryCardRegistry.every((card) => card.titleKey.isNotEmpty), isTrue);
  });

  test('default preferences expose all current cards in default order', () {
    final defaults = LibraryLayoutPreferences.defaults();
    expect(defaults.orderedIds, libraryCardRegistry.map((card) => card.id));
    expect(defaults.visibleCards(), libraryCardRegistry);
  });

  test('hide/show leaves all entries available to the customization list', () {
    final defaults = LibraryLayoutPreferences.defaults();
    final hidden = defaults.setVisible('people', false);
    expect(hidden.isVisible('people'), isFalse);
    expect(hidden.visibleCards().map((card) => card.id), isNot(contains('people')));
    expect(hidden.orderedCards(), libraryCardRegistry);
    expect(hidden.setVisible('people', true).visibleCards(), libraryCardRegistry);
    expect(defaults.isVisible('people'), isTrue);
  });

  test('all cards can be hidden without losing their ordered descriptors', () {
    var hidden = LibraryLayoutPreferences.defaults();
    for (final card in libraryCardRegistry) {
      hidden = hidden.setVisible(card.id, false);
    }
    expect(hidden.visibleCards(), isEmpty);
    expect(hidden.orderedCards(), hasLength(16));
    expect(LibraryLayoutPreferences.fromJson(hidden.toJson()).visibleCards(), isEmpty);
  });

  test('reorder uses insertion indices and preserves hidden-card preference', () {
    final prefs = LibraryLayoutPreferences.defaults().setVisible('people', false);
    final moved = prefs.reorder(0, 4);
    expect(moved.orderedIds.take(4), ['archive', 'sharedLinks', 'trash', 'favorites']);
    expect(moved.isVisible('people'), isFalse);
    expect(moved.reorder(3, 0).orderedIds, prefs.orderedIds);
    expect(moved.reorder(0, moved.orderedIds.length).orderedIds.last, 'archive');
  });

  test('malformed reorder and unknown card changes do not change preferences', () {
    final prefs = LibraryLayoutPreferences.defaults();
    expect(prefs.reorder(-1, 0), same(prefs));
    expect(prefs.reorder(0, 100), same(prefs));
    expect(prefs.setVisible('removed-card', true), same(prefs));
  });

  test('unknown/removed IDs and duplicates are ignored on restore', () {
    final restored = LibraryLayoutPreferences.fromJson({
      'order': ['removed', 'people', 'people', 'favorites', 12],
      'visible': ['people', 'removed', false],
    });
    expect(restored.orderedIds.take(2), ['people', 'favorites']);
    expect(restored.orderedIds, hasLength(16));
    expect(restored.visibleIds, isNot(contains('removed')));
    expect(restored.isVisible('favorites'), isFalse);
  });

  test('new cards use current defaults and do not unhide existing cards', () {
    final oldRegistry = libraryCardRegistry.where((card) => card.id != 'livePhotos').toList();
    final oldPrefs = LibraryLayoutPreferences.defaults(oldRegistry).setVisible('people', false);
    final restored = LibraryLayoutPreferences.fromJson(oldPrefs.toJson());
    expect(restored.isVisible('people'), isFalse);
    expect(restored.isVisible('livePhotos'), isTrue);
    expect(restored.orderedIds.last, 'livePhotos');
  });

  test('a newly introduced default-hidden card stays hidden', () {
    const additional = LibraryCardDescriptor(
      id: 'future',
      titleKey: 'future',
      icon: Icons.photo_outlined,
      action: LibraryCardAction.albums,
      defaultOrder: 99,
      defaultVisible: false,
    );
    final registry = [...libraryCardRegistry, additional];
    final restored = LibraryLayoutPreferences.fromJson(LibraryLayoutPreferences.defaults().toJson(), registry);
    expect(restored.orderedIds.last, 'future');
    expect(restored.isVisible('future'), isFalse);
    expect(LibraryLayoutPreferences.defaults(registry).isVisible('future'), isFalse);
  });

  test('corrupt JSON structures fall back to current defaults', () {
    for (final raw in [
      null,
      'bad',
      [],
      {'order': []},
      {'order': [], 'visible': true},
    ]) {
      expect(LibraryLayoutPreferences.fromJson(raw).visibleCards(), libraryCardRegistry);
    }
  });

  test('unavailable capabilities disappear without erasing user preferences', () {
    final prefs = LibraryLayoutPreferences.defaults();
    final available = prefs.visibleCards(trashAvailable: false, mapAvailable: false).map((card) => card.id);
    expect(available, isNot(contains('trash')));
    expect(available, isNot(contains('places')));
    expect(available, contains('people'));
    expect(prefs.isVisible('trash'), isTrue);
    expect(prefs.visibleCards(), libraryCardRegistry);
  });

  test('People is an always-available preview with no ML capability switch', () {
    final people = libraryCardRegistry.singleWhere((card) => card.id == 'people');
    expect(people.capability, LibraryCardCapability.always);
    expect(people.previewKind, LibraryCardPreviewKind.people);
    expect(people.isAvailable(mapAvailable: false, trashAvailable: false), isTrue);
  });
}
