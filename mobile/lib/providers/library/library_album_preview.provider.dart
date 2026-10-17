import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_album.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/library/library_layout.provider.dart';

/// Scoped to the existing authenticated Library session. On logout/switch, the
/// old subscription is cancelled; late events cannot populate another account.
/// Drift observes album, membership, cover and Trash/visibility changes, even
/// when the first album arrives after Library was opened. No polling or API per
/// album is needed: the regular sync remains the authoritative data source.
final libraryAlbumPreviewProvider = StreamProvider.autoDispose<List<LibraryAlbumPreview>>((ref) {
  final scope = ref.watch(libraryLayoutScopeProvider);
  if (scope == null) {
    return const Stream.empty();
  }
  return ref.watch(driftProvider).remoteAlbumRepository.watchLibraryPreview(scope.userId);
});
