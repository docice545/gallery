#!/usr/bin/env bash
# Official codegen operations, deliberately sequential instead of a parallel mise DAG / xargs -P4.
set -euo pipefail
[[ -f pubspec.yaml && -d ../mobile && -d generated/openapi ]] || exit 2
dart run drift_dev make-migrations
dart run build_runner build --low-resources-mode
dart run drift_dev schema generate --data-classes --companions drift_schemas/main/ test/drift/main/generated/
for file in pigeon/*.dart; do
  dart run pigeon --input "$file"
done
dart run easy_localization:generate -S ../i18n
dart run bin/generate_keys.dart
dart format lib/routing/router.gr.dart lib/platform/ lib/generated/codegen_loader.g.dart lib/generated/translations.g.dart
