import 'dart:convert';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// A durable Android trash intent. This is not evidence that Android trashed a file.
/// [rawValue] is the compare-and-swap token for its current retry/lease state.
class PendingLocalTrash {
  final String key;
  final String rawValue;
  final LocalAsset asset;
  final List<String> albumIds;
  final Map<String, bool> remoteReasons;
  final int attempts;
  final DateTime nextAttemptAt;
  final String? code;
  final String? message;

  const PendingLocalTrash({
    required this.key,
    required this.rawValue,
    required this.asset,
    required this.albumIds,
    required this.remoteReasons,
    required this.attempts,
    required this.nextAttemptAt,
    this.code,
    this.message,
  });

  factory PendingLocalTrash.fromStored(String key, String rawValue) {
    final state = jsonDecode(rawValue) as Map<String, dynamic>;
    if (state['version'] != 1) {
      throw const FormatException('Unsupported pending local trash version');
    }
    final a = state['asset'] as Map<String, dynamic>;
    return PendingLocalTrash(
      key: key,
      rawValue: rawValue,
      asset: LocalAsset(
        id: a['id'] as String,
        name: a['name'] as String,
        checksum: a['checksum'] as String?,
        type: AssetType.values[a['type'] as int],
        createdAt: DateTime.fromMillisecondsSinceEpoch(a['createdAt'] as int, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(a['updatedAt'] as int, isUtc: true),
        width: a['width'] as int?,
        height: a['height'] as int?,
        durationMs: a['durationMs'] as int?,
        isFavorite: a['isFavorite'] as bool,
        orientation: a['orientation'] as int,
        playbackStyle: AssetPlaybackStyle.values[a['playbackStyle'] as int],
        adjustmentTime: a['adjustmentTime'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(a['adjustmentTime'] as int, isUtc: true),
        latitude: (a['latitude'] as num?)?.toDouble(),
        longitude: (a['longitude'] as num?)?.toDouble(),
        isEdited: a['isEdited'] as bool,
      ),
      albumIds: (state['albumIds'] as List).cast<String>(),
      remoteReasons: (state['remoteReasons'] as Map<String, dynamic>).cast<String, bool>(),
      attempts: state['attempts'] as int,
      nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(state['nextAttemptAt'] as int, isUtc: true),
      code: state['code'] as String?,
      message: state['message'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'asset': {
      'id': asset.id,
      'name': asset.name,
      'checksum': asset.checksum,
      'type': asset.type.index,
      'createdAt': asset.createdAt.millisecondsSinceEpoch,
      'updatedAt': asset.updatedAt.millisecondsSinceEpoch,
      'width': asset.width,
      'height': asset.height,
      'durationMs': asset.durationMs,
      'isFavorite': asset.isFavorite,
      'orientation': asset.orientation,
      'playbackStyle': asset.playbackStyle.index,
      'adjustmentTime': asset.adjustmentTime?.millisecondsSinceEpoch,
      'latitude': asset.latitude,
      'longitude': asset.longitude,
      'isEdited': asset.isEdited,
    },
    'albumIds': albumIds,
    'remoteReasons': remoteReasons,
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt.millisecondsSinceEpoch,
    'code': code,
    'message': message,
  };

  PendingLocalTrash updated({
    List<String>? albumIds,
    Map<String, bool>? remoteReasons,
    int? attempts,
    DateTime? nextAttemptAt,
    String? code,
    String? message,
    bool clearMessage = false,
  }) {
    final next = PendingLocalTrash(
      key: key,
      rawValue: '',
      asset: asset,
      albumIds: albumIds ?? this.albumIds,
      remoteReasons: remoteReasons ?? this.remoteReasons,
      attempts: attempts ?? this.attempts,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      code: code ?? this.code,
      message: clearMessage ? null : message ?? this.message,
    );
    return PendingLocalTrash.fromStored(key, jsonEncode(next.toJson()));
  }
}
