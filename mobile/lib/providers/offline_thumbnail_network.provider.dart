import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';

/// Independent of upload/backup cellular preferences. Defaults to Wi-Fi only
/// until the user explicitly acknowledges possible mobile-data charges.
final offlineThumbnailAnyNetworkProvider = StreamProvider<bool>(
  (_) => Store.watch(StoreKey.offlineThumbnailAnyNetwork).map((enabled) => enabled ?? false),
);
