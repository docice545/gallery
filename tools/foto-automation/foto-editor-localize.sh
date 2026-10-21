#!/bin/bash
set -euo pipefail
dart run easy_localization:generate -S ../i18n
dart bin/generate_keys.dart
