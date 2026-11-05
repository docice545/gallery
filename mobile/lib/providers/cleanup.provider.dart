import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';

part 'cleanup.provider.freezed.dart';

@freezed
abstract class CleanupState with _$CleanupState {
  const factory CleanupState({
    DateTime? selectedDate,
    @Default([]) List<LocalAsset> assetsToDelete,
    @Default(0) int totalBytes,
    @Default(false) bool isScanning,
    @Default(false) bool isDeleting,
    @Default(AssetKeepType.none) AssetKeepType keepMediaType,
    @Default(true) bool keepFavorites,
    @Default({}) Set<String> keepAlbumIds,
  }) = _CleanupState;
}

final cleanupProvider = StateNotifierProvider<CleanupNotifier, CleanupState>((ref) {
  final userId = ref.watch(currentUserProvider)?.id;
  final store = ref.watch(storeServiceProvider);
  final endpoint = store.tryGet(StoreKey.serverEndpoint);
  return CleanupNotifier(
    ref.watch(cleanupServiceProvider),
    userId,
    ref.watch(settingsProvider),
    isCurrent: () => ref.read(currentUserProvider)?.id == userId && store.tryGet(StoreKey.serverEndpoint) == endpoint,
  );
});

class CleanupNotifier extends StateNotifier<CleanupState> {
  final CleanupService _cleanupService;
  final String? _userId;
  final SettingsRepository _settingsRepository;
  final bool Function()? isCurrent;
  int _revision = 0;
  bool _deleting = false;
  Map<String, int> _bytesById = const {};

  CleanupNotifier(this._cleanupService, this._userId, this._settingsRepository, {this.isCurrent})
    : super(const CleanupState()) {
    _loadPersistedSettings();
  }

  void _loadPersistedSettings() {
    final cleanup = _settingsRepository.appConfig.cleanup;
    final keepFavorites = cleanup.keepFavorites;
    final keepMediaType = cleanup.keepMediaType;
    final keepAlbumIds = cleanup.keepAlbumIds.toSet();
    final cutoffDaysAgo = cleanup.cutoffDaysAgo;
    final selectedDate = cutoffDaysAgo >= 0 ? DateTime.now().subtract(Duration(days: cutoffDaysAgo)) : null;

    state = state.copyWith(
      keepFavorites: keepFavorites,
      keepMediaType: keepMediaType,
      keepAlbumIds: keepAlbumIds,
      selectedDate: selectedDate,
    );
  }

  void setSelectedDate(DateTime? date) {
    _revision++;
    state = state.copyWith(selectedDate: date, assetsToDelete: [], totalBytes: 0, isScanning: false);
    if (date != null) {
      final daysAgo = DateTime.now().difference(date).inDays;
      unawaited(_settingsRepository.write(.cleanupCutoffDaysAgo, daysAgo));
    }
  }

  void setKeepMediaType(AssetKeepType keepMediaType) {
    _revision++;
    state = state.copyWith(keepMediaType: keepMediaType, assetsToDelete: [], totalBytes: 0, isScanning: false);
    unawaited(_settingsRepository.write(.cleanupKeepMediaType, keepMediaType));
  }

  void setKeepFavorites(bool keepFavorites) {
    _revision++;
    state = state.copyWith(keepFavorites: keepFavorites, assetsToDelete: [], totalBytes: 0, isScanning: false);
    unawaited(_settingsRepository.write(.cleanupKeepFavorites, keepFavorites));
  }

  void toggleKeepAlbum(String albumId) {
    _revision++;
    final newKeepAlbumIds = Set<String>.from(state.keepAlbumIds);
    if (newKeepAlbumIds.contains(albumId)) {
      newKeepAlbumIds.remove(albumId);
    } else {
      newKeepAlbumIds.add(albumId);
    }
    state = state.copyWith(keepAlbumIds: newKeepAlbumIds, assetsToDelete: [], totalBytes: 0, isScanning: false);
    _persistExcludedAlbumIds(newKeepAlbumIds);
  }

  void _persistExcludedAlbumIds(Set<String> albumIds) {
    unawaited(_settingsRepository.write(.cleanupKeepAlbumIds, albumIds.toList()));
  }

  void cleanupStaleAlbumIds(Set<String> existingAlbumIds) {
    final staleIds = state.keepAlbumIds.difference(existingAlbumIds);
    if (staleIds.isNotEmpty) {
      _revision++;
      final cleanedIds = state.keepAlbumIds.intersection(existingAlbumIds);
      state = state.copyWith(keepAlbumIds: cleanedIds, assetsToDelete: [], totalBytes: 0, isScanning: false);
      _persistExcludedAlbumIds(cleanedIds);
    }
  }

  void applyDefaultAlbumSelections(List<(String id, String name)> albums) {
    final isInitialized = _settingsRepository.appConfig.cleanup.defaultsInitialized;
    if (isInitialized) {
      return;
    }

    final toKeep = _cleanupService.getDefaultKeepAlbumIds(albums);

    if (toKeep.isNotEmpty) {
      _revision++;
      final keepAlbumIds = {...state.keepAlbumIds, ...toKeep};
      state = state.copyWith(keepAlbumIds: keepAlbumIds, assetsToDelete: [], totalBytes: 0, isScanning: false);
      _persistExcludedAlbumIds(keepAlbumIds);
    }

    unawaited(_settingsRepository.write(.cleanupDefaultsInitialized, true));
  }

  Future<void> scanAssets() async {
    if (_userId == null || state.selectedDate == null) {
      return;
    }

    if (_deleting || !(isCurrent?.call() ?? true)) {
      return;
    }
    final revision = ++_revision;
    state = state.copyWith(isScanning: true);
    try {
      final result = await _cleanupService.getRemovalCandidates(
        _userId,
        state.selectedDate!,
        keepMediaType: state.keepMediaType,
        keepFavorites: state.keepFavorites,
        keepAlbumIds: state.keepAlbumIds,
      );

      if (!mounted || revision != _revision || !(isCurrent?.call() ?? true)) {
        return;
      }
      _bytesById = result.bytesByAssetId;
      state = state.copyWith(assetsToDelete: result.assets, totalBytes: result.totalBytes, isScanning: false);
    } catch (e) {
      if (mounted && revision == _revision) {
        state = state.copyWith(isScanning: false);
      }
      rethrow;
    }
  }

  Future<int> deleteAssets({CleanupState? expected}) async {
    if (_userId == null ||
        state.selectedDate == null ||
        _deleting ||
        state.isScanning ||
        state.assetsToDelete.isEmpty ||
        (expected != null && expected != state)) {
      return 0;
    }

    final snapshot = state;
    final revision = _revision;
    _deleting = true;
    state = state.copyWith(isDeleting: true);
    try {
      final result = await _cleanupService.deleteVerifiedBackups(
        snapshot.assetsToDelete,
        _userId,
        snapshot.selectedDate!,
        keepMediaType: snapshot.keepMediaType,
        keepFavorites: snapshot.keepFavorites,
        keepAlbumIds: snapshot.keepAlbumIds,
        canContinue: () => mounted && revision == _revision && (isCurrent?.call() ?? true),
      );
      if (mounted && revision == _revision) {
        final remaining = snapshot.assetsToDelete.where((a) => result.remainingIds.contains(a.id)).toList();
        state = state.copyWith(
          assetsToDelete: remaining,
          isDeleting: false,
          totalBytes: remaining.fold(0, (sum, asset) => sum + (_bytesById[asset.id] ?? 0)),
        );
      }
      return result.deletedIds.length;
    } catch (e) {
      if (mounted) {
        state = state.copyWith(isDeleting: false);
      }
      rethrow;
    } finally {
      _deleting = false;
      if (mounted && state.isDeleting) {
        state = state.copyWith(isDeleting: false);
      }
    }
  }

  void reset() {
    _revision++;
    // Only reset transient state, keep the persisted filter settings
    state = state.copyWith(
      selectedDate: null,
      assetsToDelete: [],
      totalBytes: 0,
      isScanning: false,
      isDeleting: _deleting,
    );
  }
}
