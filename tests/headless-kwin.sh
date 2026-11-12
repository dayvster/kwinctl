#!/usr/bin/env bash
# headless-kwin.sh CMD... : run CMD inside a private D-Bus session with a headless KWin (no screen,
# nothing shared with your real desktop). Test windows can be opened with WAYLAND_DISPLAY=$KWINCTL_TEST_SOCKET.
# Usage: dbus-run-session -- tests/headless-kwin.sh zig build run -- list
set -euo pipefail
sock=kwinctl-test-$$
kwin_wayland --virtual --no-lockscreen --socket "$sock" --width 1920 --height 1080 >"${KWINCTL_TEST_LOG:-/dev/null}" 2>&1 &
kwin=$!
cleanup() { kill "$kwin" 2>/dev/null; wait "$kwin" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 50); do
  gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 && break
  sleep 0.1
done
export KWINCTL_TEST_SOCKET=$sock
status=0
"$@" || status=$?
exit "$status"
