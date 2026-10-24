/// A failed HTTP image request with transport-independent, credential-free
/// diagnostics. A 404 alone does not establish that the asset was deleted.
class RemoteImageHttpException implements Exception {
  final int statusCode;
  final int requestId;
  final String requestPath;
  final String finalPath;
  final String stage;
  final bool? edited;

  const RemoteImageHttpException({
    required this.statusCode,
    required this.requestId,
    required this.requestPath,
    required this.finalPath,
    required this.stage,
    this.edited,
  });

  static String sanitizedPath(String value) {
    final path = Uri.tryParse(value)?.path;
    if (path == null || !path.startsWith('/')) {
      return '<invalid-path>';
    }
    return path.length > 2048 ? path.substring(0, 2048) : path;
  }

  String? get assetId {
    final segments = Uri.tryParse(requestPath)?.pathSegments ?? const <String>[];
    final assets = segments.indexOf('assets');
    return assets >= 0 && assets + 1 < segments.length ? segments[assets + 1] : null;
  }

  @override
  String toString() =>
      'RemoteImageHttpException(HTTP $statusCode, request=$requestId, stage=$stage, edited=$edited, '
      'path=$requestPath, finalPath=$finalPath)';
}
