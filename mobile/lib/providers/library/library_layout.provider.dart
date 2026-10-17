import 'dart:async';
import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/library_card.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

/// Endpoint switching does not change the configured primary server URL. User
/// IDs from different servers must never share Library preferences.
class LibraryLayoutScope {
  final String serverId;
  final String userId;

  const LibraryLayoutScope({required this.serverId, required this.userId});

  String get storageId => jsonEncode([serverId, userId]);

  static String? canonicalServer(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/api')) {
      path = path.substring(0, path.length - 4);
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path).toString();
  }
}

abstract class LibraryLayoutPrefs {
  LibraryLayoutPreferences load(LibraryLayoutScope scope);
  Future<void> save(LibraryLayoutScope scope, LibraryLayoutPreferences preferences);
}

/// Uses the existing local Store table, with no migration or server preference
/// API. One serialized read/merge/write queue protects other users' map entries.
class StoreLibraryLayoutPrefs implements LibraryLayoutPrefs {
  final StoreService store;
  Future<void> _writeTail = Future.value();
  final Map<String, LibraryLayoutPreferences> _latest = {};

  StoreLibraryLayoutPrefs(this.store);

  Map<String, Object?> _readAll() {
    Map<String, Object?> persisted;
    try {
      final decoded = jsonDecode(store.get(StoreKey.libraryLayoutPreferences, '{}'));
      persisted = decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } on FormatException {
      persisted = {};
    } on TypeError {
      persisted = {};
    }
    // Store's asynchronous DB watcher can briefly emit an older snapshot after
    // a completed write. Overlay accepted changes before any queued map merge.
    return {...persisted, for (final entry in _latest.entries) entry.key: entry.value.toJson()};
  }

  @override
  LibraryLayoutPreferences load(LibraryLayoutScope scope) =>
      _latest[scope.storageId] ?? LibraryLayoutPreferences.fromJson(_readAll()[scope.storageId]);

  @override
  Future<void> save(LibraryLayoutScope scope, LibraryLayoutPreferences preferences) {
    final scopeId = scope.storageId;
    _latest[scopeId] = preferences;
    final write = _writeTail.then((_) async {
      final all = _readAll();
      all[scopeId] = preferences.toJson();
      await store.put(StoreKey.libraryLayoutPreferences, jsonEncode(all));
    });
    // A failed write is delivered to its caller, without poisoning later writes.
    _writeTail = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}

final libraryLayoutPrefsProvider = Provider<LibraryLayoutPrefs>((ref) => StoreLibraryLayoutPrefs(StoreService.I));

typedef _LibraryAuthStore = ({String? serverUrl, String? token});

final _libraryAuthStoreProvider = StreamProvider<_LibraryAuthStore>((ref) {
  final store = StoreService.I;
  var serverUrl = store.tryGet(StoreKey.serverUrl);
  var token = store.tryGet(StoreKey.accessToken);
  final controller = StreamController<_LibraryAuthStore>();
  void emit() {
    if (!controller.isClosed) {
      controller.add((serverUrl: serverUrl, token: token));
    }
  }

  final serverChanges = store.watch(StoreKey.serverUrl).listen((value) {
    serverUrl = value;
    emit();
  });
  final authChanges = store.watch(StoreKey.accessToken).listen((value) {
    token = value;
    emit();
  });
  ref.onDispose(() {
    unawaited(serverChanges.cancel());
    unawaited(authChanges.cancel());
    unawaited(controller.close());
  });
  emit();
  return controller.stream;
});

final libraryLayoutScopeProvider = Provider<LibraryLayoutScope?>((ref) {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  final store = StoreService.I;
  // Use actual DB stream values, rather than invalidating and rereading Store's
  // asynchronously refreshed cache. A stale currentUser must not survive logout.
  final auth =
      ref.watch(_libraryAuthStoreProvider).valueOrNull ??
      (serverUrl: store.tryGet(StoreKey.serverUrl), token: store.tryGet(StoreKey.accessToken));
  final serverId = LibraryLayoutScope.canonicalServer(auth.serverUrl);
  final token = auth.token;
  if (userId == null || token == null || token.isEmpty || serverId == null) {
    return null;
  }
  return LibraryLayoutScope(serverId: serverId, userId: userId);
});

final libraryLayoutProvider = NotifierProvider<LibraryLayoutNotifier, LibraryLayoutPreferences>(
  LibraryLayoutNotifier.new,
);

class LibraryLayoutNotifier extends Notifier<LibraryLayoutPreferences> {
  @override
  LibraryLayoutPreferences build() {
    final scope = ref.watch(libraryLayoutScopeProvider);
    final prefs = ref.watch(libraryLayoutPrefsProvider);
    return scope == null ? LibraryLayoutPreferences.defaults() : prefs.load(scope);
  }

  Future<void> setVisible(String id, bool visible) => _save(state.setVisible(id, visible));

  Future<void> reorder(int oldIndex, int newIndex) => _save(state.reorder(oldIndex, newIndex));

  Future<void> resetDefaults() => _save(LibraryLayoutPreferences.defaults());

  Future<void> _save(LibraryLayoutPreferences preferences) {
    final scope = ref.read(libraryLayoutScopeProvider);
    if (scope == null) {
      return Future.value();
    }
    state = preferences;
    // Capture the scope before awaiting. Persistence completion never updates
    // Notifier state, so A's delayed save cannot replace B's current layout.
    return ref.read(libraryLayoutPrefsProvider).save(scope, preferences);
  }
}

final libraryCardsProvider = Provider<List<LibraryCardDescriptor>>((ref) {
  final layout = ref.watch(libraryLayoutProvider);
  final features = ref.watch(serverInfoProvider.select((state) => state.serverFeatures));
  return layout.visibleCards(trashAvailable: features.trash, mapAvailable: features.map);
});
