import 'dart:ui';

import 'package:immich_mobile/generated/codegen_loader.g.dart';

/// Keeps the custom mobile product name separate from upstream/web branding.
///
/// The release branding script merges its own translated prose before generating
/// [CodegenLoader]. Only known mobile product-name strings are adapted here, so
/// normal gallery terminology, technical identifiers and web copy are untouched.
class AppAssetLoader extends CodegenLoader {
  const AppAssetLoader();

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final source = await super.load(path, locale);
    if (source == null) {
      return null;
    }

    final appName = source['app_name'] ?? CodegenLoader.mapLocales['en']!['app_name'];
    return brandTranslations(source, appName: appName as String);
  }

  static final _productName = RegExp(
    r'(?<![a-zA-Z0-9_./:@-])(?:Noodle Gallery|Immich)(?![a-zA-Z0-9_./:@-])',
    caseSensitive: false,
  );
  static final _shortProductName = RegExp(r'(?<![a-zA-Z0-9_./:@-])Gallery(?![a-zA-Z0-9_./:@-])');

  // Explicitly scoped product prose, including keys supplied by release-time
  // overrides. In particular, lowercase "gallery" in the Android integration
  // explanation describes the system role and must remain unchanged.
  static const _productProseKeys = {
    'advanced_settings_proxy_headers_subtitle',
    'asset_offline_description',
    'assets_deleted_permanently_from_server',
    'assets_trashed_from_server',
    'background_location_permission_content',
    'backup_background_blocked_body',
    'backup_background_reminder_body',
    'backup_background_stale_body',
    'backup_background_warning_body',
    'backup_controller_page_background_battery_info_message',
    'cache_settings_subtitle',
    'cleanup_confirm_description',
    'cleanup_step4_summary',
    'control_bottom_app_bar_delete_from_immich',
    'delete_dialog_alert',
    'delete_dialog_alert_local',
    'delete_dialog_alert_local_ios',
    'delete_dialog_alert_local_non_backed_up',
    'delete_dialog_alert_remote',
    'empty_trash_confirmation',
    'ignore_icloud_photos_description',
    'immich_logo',
    'location_permission_content',
    'manage_media_access_subtitle',
    'map_location_service_disabled_content',
    'map_no_location_permission_content',
    'notification_enabled_list_tile_content',
    'ocr_body',
    'open_in_immich_body',
    'open_in_immich_title',
    'permission_onboarding_permission_denied',
    'permission_onboarding_permission_limited',
    'permission_onboarding_request',
    'recently_added_description',
    'reset_sqlite_done',
    'search_type_description',
    'settings_require_restart',
    'sync_upload_album_setting_subtitle',
    'trash_page_empty_trash_dialog_content',
    'upload_to_immich',
    'welcome_to_immich',
    'whats_new_settings_subtitle',
  };

  static Map<String, dynamic> brandTranslations(Map<String, dynamic> source, {required String appName}) => {
    ...source,
    'app_name': appName,
    for (final key in _productProseKeys)
      if (source[key] case final String text)
        key: text.replaceAll(_productName, appName).replaceAll(_shortProductName, appName),
  };
}
