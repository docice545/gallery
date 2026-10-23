import 'package:flutter/widgets.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:openapi/api.dart' show ApiException;

/// Same reason at the editor entry point and after opening the AI page.
/// A disabled capability is the backend's AI availability result, not proof
/// that the selected photo is unsupported. Unknown failures stay retryable.
String magicEraserAvailabilityMessage(BuildContext context, Object? error) => switch (error) {
  MagicEraserCapabilityException(reason: MagicEraserCapabilityFailure.unsupportedBackend) =>
    context.t.magic_eraser_backend_unsupported,
  MagicEraserCapabilityException(reason: MagicEraserCapabilityFailure.unavailablePhoto) =>
    context.t.magic_eraser_photo_unavailable,
  ApiException(code: 401) => context.t.magic_eraser_sign_in_required,
  ApiException(code: 403) => context.t.magic_eraser_access_denied,
  ApiException(code: 400) => context.t.magic_eraser_unsupported_photo,
  ApiException(code: 404) => context.t.magic_eraser_photo_unavailable,
  ApiException(code: 503) || null => context.t.magic_eraser_service_unavailable,
  _ => context.t.magic_eraser_check_failed,
};
