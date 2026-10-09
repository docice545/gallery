import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/models/folder/root_folder.model.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/services/folder.service.dart';
import 'package:logging/logging.dart';

class FolderStructureNotifier extends StateNotifier<AsyncValue<RootFolder>> {
  final FolderService _folderService;
  final Logger _log = Logger("FolderStructureNotifier");
  SortOrder? _lastOrder;

  FolderStructureNotifier(this._folderService) : super(const AsyncLoading());

  Future<void> fetchFolders(SortOrder order) async {
    _lastOrder = order;
    try {
      final folders = await _folderService.getFolderStructure(order);
      state = AsyncData(folders);
    } catch (e, stack) {
      _log.severe("Failed to build folder structure", e, stack);
      state = AsyncError(e, stack);
    }
  }

  Future<void> refresh() async {
    final order = _lastOrder;
    if (order == null) {
      return;
    }
    await fetchFolders(order);
  }
}

final folderStructureProvider = StateNotifierProvider<FolderStructureNotifier, AsyncValue<RootFolder>>((ref) {
  final notifier = FolderStructureNotifier(ref.watch(folderServiceProvider));
  ref.listen<int>(syncStatusProvider.select((state) => state.remoteContentChangedCount), (previous, next) {
    if (previous != null && next != previous) {
      unawaited(notifier.refresh());
    }
  });
  return notifier;
});

class FolderRenderListNotifier extends StateNotifier<AsyncValue<List<RemoteAssetExif>>> {
  final FolderService _folderService;
  final RootFolder _folder;
  final Logger _log = Logger("FolderAssetsNotifier");
  SortOrder? _lastOrder;
  final _countController = StreamController<int>.broadcast();
  StreamSubscription<Set<String>>? _trashSubscription;
  List<RemoteAssetExif> _fetched = const [];
  Set<String> _trashedIds = const {};
  bool _trashReady;
  bool _hasFetched = false;
  int _fetchRevision = 0;

  FolderRenderListNotifier(this._folderService, this._folder, {Stream<Set<String>>? trashedIds})
    : _trashReady = trashedIds == null,
      super(const AsyncLoading()) {
    _trashSubscription = trashedIds?.listen((ids) {
      if (!mounted) {
        return;
      }
      _trashedIds = ids;
      _trashReady = true;
      if (_hasFetched) {
        _publishAssets();
      }
    });
  }

  Stream<int> get count => _countController.stream;

  List<RemoteAssetExif> getAssets() => List.unmodifiable(
    _trashReady ? _fetched.where((asset) => !_trashedIds.contains(asset.id)) : const <RemoteAssetExif>[],
  );

  void _publishAssets() {
    final assets = getAssets();
    state = AsyncData(assets);
    _countController.add(assets.length);
  }

  Future<void> fetchAssets(SortOrder order) async {
    _lastOrder = order;
    final revision = ++_fetchRevision;
    try {
      final assets = await _folderService.getFolderAssets(_folder, order);
      if (!mounted || revision != _fetchRevision) {
        return;
      }
      // Server snapshots can arrive after optimistic Trash. Apply the current
      // durable markers rather than putting the old tile back into the folder.
      _fetched = assets;
      _hasFetched = true;
      _publishAssets();
    } catch (e, stack) {
      if (!mounted || revision != _fetchRevision) {
        return;
      }
      _log.severe("Failed to fetch folder assets", e, stack);
      state = AsyncError(e, stack);
    }
  }

  Future<void> refresh() async {
    final order = _lastOrder;
    if (order == null) {
      return;
    }
    await fetchAssets(order);
  }

  @override
  void dispose() {
    unawaited(_trashSubscription?.cancel());
    unawaited(_countController.close());
    super.dispose();
  }
}

final folderRenderListProvider =
    StateNotifierProvider.family<FolderRenderListNotifier, AsyncValue<List<RemoteAssetExif>>, RootFolder>((
      ref,
      folder,
    ) {
      final notifier = FolderRenderListNotifier(
        ref.watch(folderServiceProvider),
        folder,
        trashedIds: ref.watch(driftProvider).syncStreamRepository.watchTrashedAssetIds(),
      );
      ref.listen<int>(syncStatusProvider.select((state) => state.remoteContentChangedCount), (previous, next) {
        if (previous != null && next != previous) {
          unawaited(notifier.refresh());
        }
      });
      return notifier;
    });
