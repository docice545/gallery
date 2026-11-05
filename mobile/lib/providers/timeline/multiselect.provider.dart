// ignore_for_file: use-ref-and-state-synchronously

import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

part 'multiselect.provider.freezed.dart';

final multiSelectProvider = NotifierProvider<MultiSelectNotifier, MultiSelectState>(
  MultiSelectNotifier.new,
  dependencies: [timelineServiceProvider],
);

/// Selection identity must survive metadata refresh and late device/server links.
/// Local and remote IDs deliberately occupy different namespaces.
typedef AssetSelectionKey = ({bool isRemote, String id});

AssetSelectionKey assetSelectionKey(BaseAsset asset) => (isRemote: asset is RemoteAsset, id: asset.id);

@freezed
abstract class MultiSelectState with _$MultiSelectState {
  const MultiSelectState._();

  const factory MultiSelectState({
    required Set<BaseAsset> selectedAssets,
    required Set<BaseAsset> lockedSelectionAssets,
    @Default(false) bool forceEnable,
    @Default({}) Set<AssetSelectionKey> selectedIds,
    @Default({}) Set<AssetSelectionKey> lockedIds,
    @Default(0) int revision,
  }) = _MultiSelectState;

  bool get isEnabled => selectedAssets.isNotEmpty;

  bool contains(BaseAsset asset) => selectedIds.contains(assetSelectionKey(asset));

  bool isLocked(BaseAsset asset) => lockedIds.contains(assetSelectionKey(asset));

  /// Cloud only
  bool get hasRemote =>
      selectedAssets.any((asset) => asset.storage == AssetState.remote || asset.storage == AssetState.merged);

  bool get hasMerged => selectedAssets.any((asset) => asset.storage == AssetState.merged);

  bool get onlyLocal => selectedAssets.any((asset) => asset.storage == AssetState.local);

  bool get onlyRemote => selectedAssets.any((asset) => asset.storage == AssetState.remote);
}

class MultiSelectNotifier extends Notifier<MultiSelectState> {
  MultiSelectNotifier([this._defaultState]);
  final MultiSelectState? _defaultState;

  TimelineService get _timelineService => ref.read(timelineServiceProvider);

  int _generation = 0;
  bool _disposed = false;

  @override
  MultiSelectState build() {
    _disposed = false;
    final subscription = EventStream.shared.listen<TimelineReloadEvent>((_) => _generation++);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(subscription.cancel());
    });
    final initial = _defaultState ?? const MultiSelectState(selectedAssets: {}, lockedSelectionAssets: {});
    final assets = {for (final asset in initial.selectedAssets) assetSelectionKey(asset): asset};
    return initial.copyWith(
      selectedAssets: assets.values.toSet(),
      selectedIds: assets.keys.toSet(),
      lockedIds: initial.lockedSelectionAssets.map(assetSelectionKey).toSet(),
    );
  }

  void _setAssets(Map<AssetSelectionKey, BaseAsset> assets) {
    _generation++;
    state = state.copyWith(
      selectedAssets: assets.values.toSet(),
      selectedIds: assets.keys.toSet(),
      revision: state.revision + 1,
    );
  }

  Map<AssetSelectionKey, BaseAsset> get _assetsById => {
    for (final asset in state.selectedAssets) assetSelectionKey(asset): asset,
  };

  void selectAsset(BaseAsset asset) {
    if (state.contains(asset) || state.isLocked(asset)) {
      return;
    }
    _setAssets({..._assetsById, assetSelectionKey(asset): asset});
  }

  void deselectAsset(BaseAsset asset) {
    if (!state.contains(asset) || state.isLocked(asset)) {
      return;
    }
    _setAssets(_assetsById..remove(assetSelectionKey(asset)));
  }

  void toggleAssetSelection(BaseAsset asset) {
    if (state.contains(asset)) {
      deselectAsset(asset);
    } else {
      selectAsset(asset);
    }
  }

  /// A shrinking drag must preserve selections made before the gesture started.
  void updateDragSelection(Set<AssetSelectionKey> baseline, Iterable<BaseAsset> range) {
    final assets = _assetsById..removeWhere((key, _) => !baseline.contains(key) && !state.lockedIds.contains(key));
    for (final asset in range) {
      if (!state.isLocked(asset)) {
        assets[assetSelectionKey(asset)] = asset;
      }
    }
    _setAssets(assets);
  }

  void reset() {
    _generation++;
    state = MultiSelectState(selectedAssets: {}, lockedSelectionAssets: {}, revision: state.revision + 1);
  }

  Future<void> toggleBucketSelection(int offset, int bucketCount) async {
    final generation = ++_generation;
    final timeline = _timelineService;
    final assets = await timeline.loadAssets(offset, bucketCount);
    // A refresh, another selection gesture or a route change invalidates this index range.
    if (_disposed || generation != _generation || !identical(timeline, _timelineService)) {
      return;
    }
    if (assets.length != bucketCount) {
      return;
    }
    toggleBucketSelectionByAssets(assets);
  }

  void toggleBucketSelectionByAssets(List<BaseAsset> bucketAssets) {
    final eligible = {
      for (final asset in bucketAssets.where((asset) => !state.isLocked(asset))) assetSelectionKey(asset): asset,
    };
    if (eligible.isEmpty) {
      return;
    }
    final allSelected = eligible.keys.every(state.selectedIds.contains);
    final assets = _assetsById;
    if (allSelected) {
      assets.removeWhere((key, _) => eligible.containsKey(key));
    } else {
      assets.addAll(eligible);
    }
    _setAssets(assets);
  }
}

final bucketSelectionProvider = Provider.family<bool, List<BaseAsset>>((ref, bucketAssets) {
  final selectedIds = ref.watch(multiSelectProvider.select((s) => s.selectedIds));

  if (bucketAssets.isEmpty) {
    return false;
  }

  // Check if all assets in the bucket are selected
  return bucketAssets.every((asset) => selectedIds.contains(assetSelectionKey(asset)));
}, dependencies: [multiSelectProvider, timelineServiceProvider]);
