#!/usr/bin/env bash
set -euo pipefail

# Xcode Cloud invokes this before its configured build/archive action. It uses
# exactly the same pinned Flutter + complete codegen path as the unsigned lane.
repo_dir="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:?CI_WORKSPACE is required}}"
mobile_dir="$repo_dir/mobile"
cd "$mobile_dir"
export HOMEBREW_NO_AUTO_UPDATE=1
brew install mise
mise trust "$repo_dir/mise.toml"
mise trust "$mobile_dir/mise.toml"
mise install node pnpm java npm:@openapitools/openapi-generator-cli aqua:flutter/flutter

# Gemfile pins CocoaPods to the existing Podfile.lock tool version. Ruby/bundler
# are provided by the selected macOS/Xcode image; do not install a new SDK here.
cd "$mobile_dir/ios"
bundle install
cd "$mobile_dir"
bash scripts/ios_build_only.sh --prepare-only
