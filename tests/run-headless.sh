#!/usr/bin/env bash
# run-headless.sh CMD... : run CMD against a throwaway headless KWin on a private D-Bus session.
# The environment is scrubbed first so nothing started inside can reach your real desktop session.
exec env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG="${LANG:-C.UTF-8}" \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 \
  KWINCTL_TEST_LOG="${KWINCTL_TEST_LOG:-/dev/null}" \
  dbus-run-session -- "$(dirname "$0")/headless-kwin.sh" "$@"
