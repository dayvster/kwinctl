#!/usr/bin/env bash
# End-to-end test against a real (headless) KWin. Needs kwin_wayland, konsole and kwrite.
#   zig build && tests/run-headless.sh tests/e2e.sh
set -u
BIN=$(realpath "${KWINCTL:-./zig-out/bin/kwinctl}")
# Every run's stderr is also saved, so leaks reported by the debug allocator are caught at the end.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
leaklog=$work/stderr.log
K=$work/kwinctl
printf '#!/usr/bin/env bash\n"%s" "$@" 2> >(tee -a "%s" >&2)\n' "$BIN" "$leaklog" >"$K"
chmod +x "$K"
export WAYLAND_DISPLAY=$KWINCTL_TEST_SOCKET QT_QPA_PLATFORM=wayland
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
check() { # check NAME EXPECTED ACTUAL
  if [[ $3 == "$2" ]]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
field() { # field ID KEY: one value from `kwinctl --json list`
  "$K" --json list | python3 -c "import json,sys; print(next((w['$2'] for w in json.load(sys.stdin) if w['id'] == '$1'), ''))"
}
waitfor() { # waitfor CMD... : retry for up to 5s (apps resize asynchronously)
  for _ in $(seq 50); do "$@" && return 0; sleep 0.1; done
  return 1
}

konsole --separate >/dev/null 2>&1 &
kwrite >/dev/null 2>&1 &
waitfor bash -c "[ \"\$($K list | wc -l)\" -ge 2 ]" || { echo "test windows never appeared"; exit 1; }
konsole=$("$K" list | grep konsole | cut -f1)
kwrite=$("$K" list | grep kwrite | cut -f1)

echo "listing"
check "list shows both windows" 2 "$("$K" list | wc -l)"
check "ids are braced UUIDs" 2 "$("$K" list | cut -f1 | grep -cE '^\{[0-9a-f-]{36}\}$')"
check "list --json parses" 2 "$("$K" --json list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
check "screens lists the virtual output" 1 "$("$K" screens | wc -l)"
check "active is one of them" 1 "$("$K" active | grep -cE 'konsole|kwrite')"

echo "focus"
"$K" focus "$konsole"
check "focus by braced id" "$konsole" "$("$K" active | cut -f1)"
bare=$(echo "${kwrite:1:36}" | tr a-f A-F)
"$K" focus "$bare"
check "focus by bare upper-case id" "$kwrite" "$("$K" active | cut -f1)"

echo "minimize"
"$K" minimize "$kwrite"
check "minimize" True "$(field "$kwrite" minimized)"
"$K" unminimize "$kwrite"
check "unminimize" False "$(field "$kwrite" minimized)"
"$K" minimize "$kwrite"; "$K" focus "$kwrite"
check "focus un-minimizes" False "$(field "$kwrite" minimized)"

echo "geometry"
"$K" move "$konsole" 120 80 800 500
if waitfor bash -c "[ \"\$($K --json list | python3 -c \"import json,sys; w=[w for w in json.load(sys.stdin) if w['id']=='$konsole'][0]; print(w['x'],w['y'],w['width'],w['height'])\")\" = '120 80 800 500' ]"; then
  ok "move + resize"
else
  bad "move + resize" "konsole is at $("$K" --json list | python3 -c "import json,sys; w=[w for w in json.load(sys.stdin) if w['id']=='$konsole'][0]; print(w['x'],w['y'],w['width'],w['height'])")"
fi
"$K" fullscreen "$konsole" on
waitfor bash -c "[ \"\$($K --json list | python3 -c \"import json,sys; print([w for w in json.load(sys.stdin) if w['id']=='$konsole'][0]['fullscreen'])\")\" = True ]" && ok "fullscreen on" || bad "fullscreen on" "not fullscreen"
"$K" fullscreen "$konsole" off
check "fullscreen off" False "$(field "$konsole" fullscreen)"

echo "scripts"
check "script results in order" $'2\nhi' "$(printf 'output_result(workspace.windowList().filter((w) => w.normalWindow).length);\noutput_result("hi");\n' | "$K" script -)"
out=$(echo 'nosuchfn();' | "$K" script - 2>&1); code=$?
check "script exception exits 1" 1 "$code"
check "script exception is reported" "kwinctl: ReferenceError: nosuchfn is not defined" "$out"
check "a script that never reports still finishes" "" "$(echo 'const x = 1;' | "$K" script -)"

echo "errors"
out=$("$K" focus 'abc"); evil("' 2>&1); code=$?
check "malformed id rejected" 1 "$code"
out=$("$K" focus 11111111-1111-1111-1111-111111111111 2>&1); code=$?
check "unknown id exits 1" 1 "$code"
check "unknown id message" "kwinctl: no window with that id" "$out"
"$K" bogus >/dev/null 2>&1; check "unknown command exits 2" 2 "$?"

echo "close + cleanup"
"$K" close "$kwrite"
waitfor bash -c "! $K list | grep -q kwrite" && ok "close" || bad "close" "kwrite still listed"
check "no scripts left loaded" "(false,)" "$(gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.isScriptLoaded "kwinctl_$$_1")"
check "no script files left" 0 "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'kwinctl-*.js' | wc -l)"

echo "memory"
sleep 0.2 # let the last tee finish
check "no leaks reported by the debug allocator" 0 "$(grep -c 'leaked' "$leaklog")"

echo
echo "$pass passed, $fail failed"
kill %1 %2 2>/dev/null
[ "$fail" -eq 0 ]
