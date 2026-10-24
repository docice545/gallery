part of 'image_request.dart';

class RemoteImageRequest extends ImageRequest {
  static final _log = Logger('RemoteImageRequest');
  final String uri;

  /// Physical size to decode, or null for the source size.
  final ui.Size? decodeSize;

  RemoteImageRequest({required this.uri, this.decodeSize});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final info = await _requestPlatformImage(preferEncoded: false);
    // Android falls back to encoded data if native decoding fails, so check for both shapes of the response.
    final frame = switch (info) {
      {'pointer': final int pointer, 'length': final int length} => await _fromEncodedPlatformImage(
        pointer,
        length,
        decodeSize: decodeSize,
      ),
      {
        'pointer': final int pointer,
        'width': final int width,
        'height': final int height,
        'rowBytes': final int rowBytes,
      } =>
        await _fromDecodedPlatformImage(pointer, width, height, rowBytes),
      _ => null,
    };
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final info = await _requestPlatformImage(preferEncoded: true);
    if (info == null) {
      return null;
    }

    final (codec, _) = await _codecFromEncodedPlatformImage(info['pointer']!, info['length']!) ?? (null, null);
    return codec;
  }

  Future<Map<String, int>?> _requestPlatformImage({required bool preferEncoded}) async {
    try {
      return await remoteImageApi.requestImage(
        uri,
        requestId: requestId,
        preferEncoded: preferEncoded,
        width: preferEncoded ? null : decodeSize?.width.ceil(),
        height: preferEncoded ? null : decodeSize?.height.ceil(),
      );
    } on PlatformException catch (error, stack) {
      // A request deliberately cancelled because its tile disappeared can still
      // race an HTTP response. This is cancellation, not a missing-media success.
      if (_isCancelled) {
        return null;
      }
      final details = error.details;
      if (error.code != 'HTTP_ERROR' || details is! Map) {
        rethrow;
      }
      final status = details['statusCode'];
      if (status is! int || status < 100 || status > 599) {
        rethrow;
      }
      final parsed = Uri.tryParse(uri);
      final kind = parsed?.pathSegments.lastOrNull;
      const sizes = {'thumbnail', 'preview', 'fullsize'};
      final reportedSize = details['mediaSize'];
      final size = reportedSize is String && sizes.contains(reportedSize)
          ? reportedSize
          : parsed?.queryParameters['size'];
      final reportedEdited = details['edited'];
      final stage = kind == 'original'
          ? 'original'
          : kind == 'thumbnail' && sizes.contains(size)
          ? size!
          : kind == 'thumbnail'
          ? 'thumbnail'
          : 'other';
      final exception = RemoteImageHttpException(
        statusCode: status,
        requestId: requestId,
        requestPath: RemoteImageHttpException.sanitizedPath(
          details['requestPath'] is String ? details['requestPath'] as String : uri,
        ),
        finalPath: RemoteImageHttpException.sanitizedPath(
          details['finalPath'] is String ? details['finalPath'] as String : uri,
        ),
        stage: stage,
        edited: reportedEdited is bool
            ? reportedEdited
            : switch (parsed?.queryParameters['edited']) {
                'true' => true,
                'false' => false,
                _ => null,
              },
      );
      // Preserve unexpected 404s, including active assets with missing derived
      // files. Never infer deletion from a status or a missing local cache row.
      _log.warning('Remote image HTTP request failed: $exception', exception, stack);
      Error.throwWithStackTrace(exception, stack);
    }
  }

  @override
  Future<void> _onCancelled() {
    return remoteImageApi.cancelRequest(requestId);
  }
}
