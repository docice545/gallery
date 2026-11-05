import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

Widget toolbarTestApp({required Widget home, ThemeData? theme, Locale locale = const Locale('en')}) => EasyLocalization(
  supportedLocales: const [Locale('en'), Locale('ru')],
  path: 'assets/i18n',
  startLocale: locale,
  saveLocale: false,
  assetLoader: const CodegenLoader(),
  child: Builder(
    builder: (context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      home: home,
    ),
  ),
);
