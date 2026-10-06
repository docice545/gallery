import 'package:flutter/material.dart';

enum LibraryCardAction {
  favorites,
  archive,
  sharedLinks,
  trash,
  spaces,
  people,
  places,
  onDevice,
  albums,
  memories,
  folders,
  lockedFolder,
  partners,
  recentlyAdded,
  videos,
  livePhotos,
}

enum LibraryCardCapability { always, trash, map }

enum LibraryCardPresentation { action, collection }

enum LibraryCardPreviewKind { spaces, people, places, onDevice, albums, memories }

/// One entry point in Library. Visibility is a UI preference, never a feature
/// switch: hiding People does not change face data, recognition or framing.
class LibraryCardDescriptor {
  final String id;
  final String titleKey;
  final IconData icon;
  final LibraryCardAction action;
  final bool defaultVisible;
  final int defaultOrder;
  final LibraryCardCapability capability;
  final LibraryCardPresentation presentation;
  final LibraryCardPreviewKind? previewKind;

  const LibraryCardDescriptor({
    required this.id,
    required this.titleKey,
    required this.icon,
    required this.action,
    required this.defaultOrder,
    this.defaultVisible = true,
    this.capability = LibraryCardCapability.always,
    this.presentation = LibraryCardPresentation.action,
    this.previewKind,
  });

  bool isAvailable({bool trashAvailable = true, bool mapAvailable = true}) => switch (capability) {
    LibraryCardCapability.always => true,
    LibraryCardCapability.trash => trashAvailable,
    LibraryCardCapability.map => mapAvailable,
  };
}

/// Stable IDs are independent of translated labels and navigation class names.
/// Each destination occurs once, including the previous duplicate Albums/Spaces
/// quick-access entries. Existing collections retain their preview sources.
const libraryCardRegistry = <LibraryCardDescriptor>[
  LibraryCardDescriptor(
    id: 'favorites',
    titleKey: 'favorites',
    icon: Icons.favorite_outline_rounded,
    action: LibraryCardAction.favorites,
    defaultOrder: 0,
  ),
  LibraryCardDescriptor(
    id: 'archive',
    titleKey: 'archived',
    icon: Icons.archive_outlined,
    action: LibraryCardAction.archive,
    defaultOrder: 1,
  ),
  LibraryCardDescriptor(
    id: 'sharedLinks',
    titleKey: 'shared_links',
    icon: Icons.link_outlined,
    action: LibraryCardAction.sharedLinks,
    defaultOrder: 2,
  ),
  LibraryCardDescriptor(
    id: 'trash',
    titleKey: 'trash',
    icon: Icons.delete_outline_rounded,
    action: LibraryCardAction.trash,
    defaultOrder: 3,
    capability: LibraryCardCapability.trash,
  ),
  LibraryCardDescriptor(
    id: 'spaces',
    titleKey: 'spaces',
    icon: Icons.workspaces_outlined,
    action: LibraryCardAction.spaces,
    defaultOrder: 4,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.spaces,
  ),
  LibraryCardDescriptor(
    id: 'people',
    titleKey: 'people',
    icon: Icons.face_outlined,
    action: LibraryCardAction.people,
    defaultOrder: 5,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.people,
  ),
  LibraryCardDescriptor(
    id: 'places',
    titleKey: 'places',
    icon: Icons.place_outlined,
    action: LibraryCardAction.places,
    defaultOrder: 6,
    capability: LibraryCardCapability.map,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.places,
  ),
  LibraryCardDescriptor(
    id: 'onDevice',
    titleKey: 'on_this_device',
    icon: Icons.phone_android_outlined,
    action: LibraryCardAction.onDevice,
    defaultOrder: 7,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.onDevice,
  ),
  LibraryCardDescriptor(
    id: 'albums',
    titleKey: 'albums',
    icon: Icons.photo_album_outlined,
    action: LibraryCardAction.albums,
    defaultOrder: 8,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.albums,
  ),
  LibraryCardDescriptor(
    id: 'memories',
    titleKey: 'memories',
    icon: Icons.history_rounded,
    action: LibraryCardAction.memories,
    defaultOrder: 9,
    presentation: LibraryCardPresentation.collection,
    previewKind: LibraryCardPreviewKind.memories,
  ),
  LibraryCardDescriptor(
    id: 'folders',
    titleKey: 'folders',
    icon: Icons.folder_outlined,
    action: LibraryCardAction.folders,
    defaultOrder: 10,
  ),
  LibraryCardDescriptor(
    id: 'lockedFolder',
    titleKey: 'locked_folder',
    icon: Icons.lock_outline_rounded,
    action: LibraryCardAction.lockedFolder,
    defaultOrder: 11,
  ),
  LibraryCardDescriptor(
    id: 'partners',
    titleKey: 'partners',
    icon: Icons.group_outlined,
    action: LibraryCardAction.partners,
    defaultOrder: 12,
  ),
  LibraryCardDescriptor(
    id: 'recentlyAdded',
    titleKey: 'recently_added',
    icon: Icons.schedule_outlined,
    action: LibraryCardAction.recentlyAdded,
    defaultOrder: 13,
  ),
  LibraryCardDescriptor(
    id: 'videos',
    titleKey: 'videos',
    icon: Icons.videocam_outlined,
    action: LibraryCardAction.videos,
    defaultOrder: 14,
  ),
  LibraryCardDescriptor(
    id: 'livePhotos',
    titleKey: 'library_live_photos',
    icon: Icons.motion_photos_on_outlined,
    action: LibraryCardAction.livePhotos,
    defaultOrder: 15,
  ),
];

/// Stores all known IDs in order, including hidden entries. Keeping them in the
/// order distinguishes an explicitly hidden card from a newly added card.
class LibraryLayoutPreferences {
  final List<String> orderedIds;
  final Set<String> visibleIds;

  LibraryLayoutPreferences({required Iterable<String> orderedIds, required Iterable<String> visibleIds})
    : orderedIds = List.unmodifiable(orderedIds),
      visibleIds = Set.unmodifiable(visibleIds);

  factory LibraryLayoutPreferences.defaults([List<LibraryCardDescriptor> registry = libraryCardRegistry]) {
    final ordered = _defaultOrder(registry);
    return LibraryLayoutPreferences(
      orderedIds: ordered.map((card) => card.id),
      visibleIds: ordered.where((card) => card.defaultVisible).map((card) => card.id),
    );
  }

  factory LibraryLayoutPreferences.fromJson(
    Object? value, [
    List<LibraryCardDescriptor> registry = libraryCardRegistry,
  ]) {
    if (value is! Map || value['order'] is! List || value['visible'] is! List) {
      return LibraryLayoutPreferences.defaults(registry);
    }
    final knownIds = registry.map((card) => card.id).toSet();
    final storedOrder = (value['order'] as List).whereType<String>().where(knownIds.contains).toSet();
    final storedVisible = (value['visible'] as List).whereType<String>().where(knownIds.contains).toSet();
    final previouslyKnown = {...storedOrder, ...storedVisible};
    final newlyAdded = _defaultOrder(registry).where((card) => !previouslyKnown.contains(card.id));
    return LibraryLayoutPreferences(
      orderedIds: {...storedOrder, ...storedVisible, ...newlyAdded.map((card) => card.id)},
      visibleIds: {...storedVisible, ...newlyAdded.where((card) => card.defaultVisible).map((card) => card.id)},
    );
  }

  Map<String, Object> toJson() => {'order': orderedIds, 'visible': visibleIds.toList()};

  bool isVisible(String id) => visibleIds.contains(id);

  LibraryLayoutPreferences setVisible(String id, bool visible) {
    if (!orderedIds.contains(id)) {
      return this;
    }
    return LibraryLayoutPreferences(
      orderedIds: orderedIds,
      visibleIds: visible ? {...visibleIds, id} : visibleIds.where((visibleId) => visibleId != id),
    );
  }

  /// Uses ReorderableListView's insertion index contract, including hidden IDs.
  LibraryLayoutPreferences reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= orderedIds.length || newIndex < 0 || newIndex > orderedIds.length) {
      return this;
    }
    final ids = [...orderedIds];
    final id = ids.removeAt(oldIndex);
    ids.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, id);
    return LibraryLayoutPreferences(orderedIds: ids, visibleIds: visibleIds);
  }

  List<LibraryCardDescriptor> orderedCards([List<LibraryCardDescriptor> registry = libraryCardRegistry]) {
    final byId = {for (final card in registry) card.id: card};
    return orderedIds.map((id) => byId[id]).whereType<LibraryCardDescriptor>().toList(growable: false);
  }

  List<LibraryCardDescriptor> visibleCards({
    List<LibraryCardDescriptor> registry = libraryCardRegistry,
    bool trashAvailable = true,
    bool mapAvailable = true,
  }) => orderedCards(registry)
      .where(
        (card) => isVisible(card.id) && card.isAvailable(trashAvailable: trashAvailable, mapAvailable: mapAvailable),
      )
      .toList(growable: false);

  static List<LibraryCardDescriptor> _defaultOrder(List<LibraryCardDescriptor> registry) =>
      [...registry]..sort((a, b) => a.defaultOrder.compareTo(b.defaultOrder));
}
