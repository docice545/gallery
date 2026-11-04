import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/animated_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/one_frame_multi_image_stream_completer.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

class RemoteImageProvider extends CancellableImageProvider<RemoteImageProvider>
    with CancellableImageProviderMixin<RemoteImageProvider> {
  final String url;
  final bool edited;

  /// Physical size to decode, or null for the source size.
  final Size? decodeSize;

  RemoteImageProvider({required this.url, this.edited = true, this.decodeSize});

  RemoteImageProvider.thumbnail({
    required String assetId,
    required String thumbhash,
    this.edited = true,
    this.decodeSize,
    AssetMediaSize remoteMediaSize = AssetMediaSize.thumbnail,
    String? serverEndpoint,
  }) : url = getThumbnailUrlForRemoteId(
         assetId,
         type: remoteMediaSize,
         thumbhash: thumbhash,
         edited: edited,
         serverEndpoint: serverEndpoint,
       );

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteImageProvider key, ImageDecoderCallback decode) {
    final thumbnailUrl = key._thumbnailPlaceholderUrl;
    final size = key.decodeSize;
    final thumbnailSize = size != null && size.shortestSide > 250 ? size * (250 / size.shortestSide) : size;
    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      initialImage: thumbnailUrl == null
          ? null
          : getInitialImage(RemoteImageProvider(url: thumbnailUrl, edited: key.edited, decodeSize: thumbnailSize)),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Request path', RemoteImageHttpException.sanitizedPath(key.url)),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  String? get _thumbnailPlaceholderUrl {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.pathSegments.lastOrNull != 'thumbnail' ||
        uri.queryParameters['size'] != 'preview' ||
        (uri.queryParameters['c']?.isEmpty ?? true)) {
      return null;
    }
    // Preserve endpoint, asset, revision and edit identity. Only the resolution
    // differs; the native cache retains its existing session/server boundaries.
    return uri.replace(queryParameters: {...uri.queryParameters, 'size': 'thumbnail'}).toString();
  }

  Stream<ImageInfo> _codec(RemoteImageProvider key, ImageDecoderCallback decode) {
    final request = this.request = RemoteImageRequest(uri: key.url, decodeSize: key.decodeSize);
    if (key._thumbnailPlaceholderUrl == null) {
      return loadRequest(request, decode, isFinal: true);
    }

    var previewDelivered = false;
    final thumbnailSettled = Completer<void>();
    Stream<ImageInfo> thumbnail() async* {
      try {
        await for (final image in initialImageStream()) {
          if (previewDelivered || isCancelled) {
            image.dispose();
          } else {
            yield image;
          }
        }
      } finally {
        thumbnailSettled.complete();
      }
    }

    Stream<ImageInfo> preview() async* {
      try {
        await for (final image in loadRequest(request, decode, isFinal: true)) {
          previewDelivered = true;
          // Do not let a cache miss in the smaller source delay a ready preview,
          // retain an abandoned request, or replace it later with lower quality.
          unawaited(cachedOperation?.cancel());
          yield image;
        }
      } catch (error, stack) {
        // An offline socket may fail before the durable thumbnail is decoded.
        // Reporting that error immediately makes Thumbnail detach/cancel BOTH
        // streams and lose the available photo until another scroll/rebuild.
        // Deliver the fallback first; keep the original error diagnostic and
        // confirmed-deletion reconciliation after its independent attempt ends.
        await thumbnailSettled.future;
        if (!isCancelled) {
          Error.throwWithStackTrace(error, stack);
        }
      }
    }

    // Native offline fallback used to run only after a preview network error.
    // A black-holed Backend can leave that pending despite a durable thumbnail.
    // Resolve both independently: cached pixels can display before any HTTP
    // response, while a ready preview still wins. No retry timer or warmup change.
    return StreamGroup.merge([thumbnail(), preview()]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteImageProvider) {
      return url == other.url && edited == other.edited && decodeSize == other.decodeSize;
    }
    return false;
  }

  @override
  int get hashCode => url.hashCode ^ edited.hashCode ^ decodeSize.hashCode;
}

class RemoteFullImageProvider extends CancellableImageProvider<RemoteFullImageProvider>
    with CancellableImageProviderMixin<RemoteFullImageProvider> {
  final String assetId;
  final String thumbhash;
  final AssetType assetType;
  final bool isAnimated;
  final bool edited;
  final String serverEndpoint;

  /// Physical size of the thumbnail shown before the preview.
  final Size? thumbnailSize;

  RemoteFullImageProvider({
    required this.assetId,
    required this.thumbhash,
    required this.assetType,
    required this.isAnimated,
    this.edited = true,
    this.thumbnailSize,
    String? serverEndpoint,
  }) : serverEndpoint = serverEndpoint ?? Store.get(StoreKey.serverEndpoint);

  String get previewUrl => getThumbnailUrlForRemoteId(
    assetId,
    type: AssetMediaSize.preview,
    thumbhash: thumbhash,
    edited: edited,
    serverEndpoint: serverEndpoint,
  );

  String get originalUrl =>
      getOriginalUrlForRemoteId(assetId, edited: edited, serverEndpoint: serverEndpoint, cacheKey: thumbhash);

  @override
  Future<RemoteFullImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteFullImageProvider key, ImageDecoderCallback decode) {
    if (key.isAnimated) {
      return AnimatedImageStreamCompleter(
        stream: _animatedCodec(key, decode),
        scale: 1.0,
        initialImage: getInitialImage(
          RemoteImageProvider.thumbnail(
            assetId: key.assetId,
            thumbhash: key.thumbhash,
            edited: key.edited,
            decodeSize: key.thumbnailSize,
            serverEndpoint: key.serverEndpoint,
          ),
        ),
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('Asset Id', key.assetId),
          DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
        ],
        onLastListenerRemoved: cancel,
      );
    }

    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      initialImage: getInitialImage(
        RemoteImageProvider.thumbnail(
          assetId: key.assetId,
          thumbhash: key.thumbhash,
          edited: key.edited,
          decodeSize: key.thumbnailSize,
          serverEndpoint: key.serverEndpoint,
        ),
      ),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Asset Id', key.assetId),
        DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  Stream<ImageInfo> _codec(RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final previewRequest = request = RemoteImageRequest(uri: key.previewUrl);
    final loadOriginal = assetType == AssetType.image && SettingsRepository.instance.appConfig.image.loadOriginal;
    yield* loadRequest(previewRequest, decode, isFinal: !loadOriginal);

    if (!loadOriginal) {
      return;
    }

    if (isCancelled) {
      return;
    }

    final originalRequest = request = RemoteImageRequest(uri: key.originalUrl);
    yield* loadRequest(originalRequest, decode, isFinal: true);
  }

  Stream<Object> _animatedCodec(RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final previewRequest = request = RemoteImageRequest(uri: key.previewUrl);
    yield* loadRequest(previewRequest, decode, isFinal: false);

    if (isCancelled) {
      return;
    }

    // always try original for animated, since previews don't support animation
    final originalRequest = request = RemoteImageRequest(uri: key.originalUrl);
    final codec = await loadCodecRequest(originalRequest, isFinal: true);
    if (codec == null) {
      if (isCancelled) {
        return;
      }
      throw StateError('Failed to load animated codec for asset ${key.assetId}');
    }
    yield codec;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteFullImageProvider) {
      return assetId == other.assetId &&
          thumbhash == other.thumbhash &&
          isAnimated == other.isAnimated &&
          edited == other.edited &&
          assetType == other.assetType &&
          thumbnailSize == other.thumbnailSize &&
          serverEndpoint == other.serverEndpoint;
    }

    return false;
  }

  @override
  int get hashCode => Object.hash(assetId, thumbhash, isAnimated, edited, assetType, thumbnailSize, serverEndpoint);
}
