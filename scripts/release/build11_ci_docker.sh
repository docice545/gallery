#!/usr/bin/env bash
# Disposable GitHub Actions VM only; never sourced by production release tools.
# Docker v28.4.0's official unit permits three starts per 60 seconds. The
# deliberate classic/containerd store transitions must reset that counter,
# rather than change the unit or disable its protection globally.
readonly BUILD11_CI_VALKEY_REFERENCE='docker.io/valkey/valkey:9@sha256:67878c70fc179bb928b1a9b510860aff1c475ff245e91d98d4b2133326bf8e3e'

build11_require_disposable_docker() {
  if [[ ${GITHUB_ACTIONS:-} != true || ${GALLERY_ISOLATED_CI:-} != 1 || ${RUNNER_OS:-} != Linux ]]; then
    echo '::error::EXPLICIT_DISPOSABLE_DOCKER_CI_REQUIRED'
    return 1
  fi
  local option containers
  for option in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION; do
    if [[ -n ${!option:-} ]]; then
      echo '::error::DISPOSABLE_DOCKER_REMOTE_OPTIONS_FORBIDDEN'
      return 1
    fi
  done
  if ! containers=$(docker --host=unix:///var/run/docker.sock ps -aq 2>/dev/null); then
    echo '::error::DISPOSABLE_DOCKER_LOCAL_INSPECTION_FAILED'
    return 1
  fi
  if [[ -n $containers ]]; then
    echo '::error::EMPTY_DISPOSABLE_DOCKER_DAEMON_REQUIRED'
    return 1
  fi
}

build11_restart_disposable_docker() {
  build11_require_disposable_docker || return 1
  if ! sudo -n systemctl reset-failed docker.service >/dev/null 2>&1; then
    echo '::error::DISPOSABLE_DOCKER_COUNTER_RESET_FAILED'
    return 1
  fi
  if ! sudo -n systemctl restart docker.service >/dev/null 2>&1; then
    local result
    result=$(sudo -n systemctl show docker.service --property=Result --value 2>/dev/null) || result=unknown
    case "$result" in
      start-limit-hit) echo '::error::DISPOSABLE_DOCKER_RESTART_START_LIMIT_HIT' ;;
      exit-code) echo '::error::DISPOSABLE_DOCKER_RESTART_EXIT_CODE' ;;
      timeout) echo '::error::DISPOSABLE_DOCKER_RESTART_TIMEOUT' ;;
      signal) echo '::error::DISPOSABLE_DOCKER_RESTART_SIGNAL' ;;
      oom-kill) echo '::error::DISPOSABLE_DOCKER_RESTART_OOM' ;;
      *) echo '::error::DISPOSABLE_DOCKER_RESTART_FAILED_PRIVATE_DETAILS_OMITTED' ;;
    esac
    return 1
  fi
}

build11_require_absent_valkey_probe_image() {
  build11_require_disposable_docker || return 1
  local output status
  if output=$(docker --host=unix:///var/run/docker.sock image inspect "$BUILD11_CI_VALKEY_REFERENCE" --format '{{.Id}}' 2>&1); then
    echo '::error::DISPOSABLE_VALKEY_PROBE_REQUIRES_ABSENT_REFERENCE'
    return 1
  else
    status=$?
  fi
  if [[ $status != 1 || $output != *'No such image:'* ]]; then
    echo '::error::DISPOSABLE_VALKEY_ABSENCE_NOT_VERIFIED'
    return 1
  fi
}

build11_remove_valkey_probe_image() {
  build11_require_disposable_docker || return 1
  # Only the exact immutable reference proven absent before this probe. Never
  # force removal, prune, or delete any other cached dependency/server image.
  if ! docker --host=unix:///var/run/docker.sock image rm "$BUILD11_CI_VALKEY_REFERENCE" >/dev/null 2>&1; then
    echo '::error::DISPOSABLE_VALKEY_PROBE_CLEANUP_FAILED'
    return 1
  fi
  build11_require_absent_valkey_probe_image
}
